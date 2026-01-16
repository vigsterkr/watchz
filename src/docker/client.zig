const std = @import("std");
const zio = @import("zio");
const types = @import("types.zig");
const log = @import("../utils/log.zig");

/// Async Docker client using zio for Unix socket communication
pub const AsyncClient = struct {
    socket_path: []const u8,
    api_version: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, api_version: []const u8) AsyncClient {
        return AsyncClient{
            .socket_path = socket_path,
            .api_version = api_version,
            .allocator = allocator,
        };
    }

    fn buildPath(self: *AsyncClient, endpoint: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "/v{s}{s}", .{ self.api_version, endpoint });
    }

    fn makeRequest(self: *AsyncClient, rt: *zio.Runtime, method: []const u8, endpoint: []const u8, body: []const u8) ![]u8 {
        const path = try self.buildPath(endpoint);
        defer self.allocator.free(path);

        // Connect to Unix socket
        const addr = try zio.net.UnixAddress.init(self.socket_path);
        const stream = try addr.connect(rt);
        defer stream.close(rt);

        // Build HTTP request
        const request = try std.fmt.allocPrint(
            self.allocator,
            "{s} {s} HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "User-Agent: WatchZ/0.1.0\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "\r\n" ++
                "{s}",
            .{ method, path, body.len, body },
        );
        defer self.allocator.free(request);

        // Send request using stream directly
        try stream.writeAll(rt, request);

        // Read response using stream directly
        var response_buffer: [16384]u8 = undefined;
        const total_read = try stream.read(rt, &response_buffer);
        const response_data = response_buffer[0..total_read];

        // Find the end of headers (double CRLF)
        const header_end = std.mem.indexOf(u8, response_data, "\r\n\r\n") orelse
            std.mem.indexOf(u8, response_data, "\n\n") orelse
            return error.InvalidResponse;

        const headers_data = response_data[0..header_end];
        const body_start = if (std.mem.indexOf(u8, response_data, "\r\n\r\n")) |_| header_end + 4 else header_end + 2;

        // Parse status line
        var lines = std.mem.splitScalar(u8, headers_data, '\n');
        const status_line = lines.next() orelse return error.InvalidResponse;

        // Extract status code
        var status_iter = std.mem.splitScalar(u8, status_line, ' ');
        _ = status_iter.next(); // HTTP/1.1
        const status_code_str = status_iter.next() orelse return error.InvalidResponse;
        const status_code = try std.fmt.parseInt(u16, std.mem.trim(u8, status_code_str, " \r"), 10);

        // Parse headers for Content-Length
        var content_length: ?usize = null;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                const value = std.mem.trim(u8, trimmed[15..], " ");
                content_length = try std.fmt.parseInt(usize, value, 10);
            }
        }

        // Extract body
        const body_data = response_data[body_start..];
        const response_body = try self.allocator.dupe(u8, if (content_length) |len|
            body_data[0..@min(len, body_data.len)]
        else
            body_data);

        if (status_code < 200 or status_code >= 300) {
            log.err("Docker API error: HTTP {d}", .{status_code});
            log.err("Response: {s}", .{response_body});
            self.allocator.free(response_body);
            return error.DockerApiError;
        }

        return response_body;
    }

    pub fn ping(self: *AsyncClient, rt: *zio.Runtime) !void {
        log.debug("Pinging Docker daemon", .{});

        const response_body = try self.makeRequest(rt, "GET", "/_ping", "");
        defer self.allocator.free(response_body);

        log.debug("Docker daemon ping successful", .{});
    }

    pub fn getVersion(self: *AsyncClient, rt: *zio.Runtime) !types.Version {
        log.debug("Getting Docker version", .{});

        const response_body = try self.makeRequest(rt, "GET", "/version", "");
        defer self.allocator.free(response_body);

        log.trace("Version response: {s}", .{response_body});

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        return types.Version{
            .version = try self.allocator.dupe(u8, obj.get("Version").?.string),
            .api_version = try self.allocator.dupe(u8, obj.get("ApiVersion").?.string),
            .min_api_version = if (obj.get("MinAPIVersion")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
            .git_commit = if (obj.get("GitCommit")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
            .go_version = if (obj.get("GoVersion")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
            .os = try self.allocator.dupe(u8, obj.get("Os").?.string),
            .arch = try self.allocator.dupe(u8, obj.get("Arch").?.string),
            .allocator = self.allocator,
        };
    }

    pub fn listContainers(self: *AsyncClient, rt: *zio.Runtime, all: bool) ![]types.Container {
        log.debug("Listing containers (all={})", .{all});

        const endpoint = if (all) "/containers/json?all=true" else "/containers/json";
        const response_body = try self.makeRequest(rt, "GET", endpoint, "");
        defer self.allocator.free(response_body);

        log.trace("Containers response (first 500 chars): {s}", .{response_body[0..@min(500, response_body.len)]});

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const array = parsed.value.array;
        var containers: std.ArrayList(types.Container) = .{};
        errdefer {
            for (containers.items) |*c| c.deinit();
            containers.deinit(self.allocator);
        }

        for (array.items) |item| {
            const obj = item.object;

            var container = types.Container{
                .id = try self.allocator.dupe(u8, obj.get("Id").?.string),
                .name = blk: {
                    const names = obj.get("Names").?.array;
                    if (names.items.len > 0) {
                        const name = names.items[0].string;
                        const clean_name = if (name.len > 0 and name[0] == '/') name[1..] else name;
                        break :blk try self.allocator.dupe(u8, clean_name);
                    }
                    break :blk try self.allocator.dupe(u8, "");
                },
                .image = try self.allocator.dupe(u8, obj.get("Image").?.string),
                .image_id = try self.allocator.dupe(u8, obj.get("ImageID").?.string),
                .state = try self.allocator.dupe(u8, obj.get("State").?.string),
                .status = try self.allocator.dupe(u8, obj.get("Status").?.string),
                .labels = std.StringHashMap([]const u8).init(self.allocator),
                .created = obj.get("Created").?.integer,
                .allocator = self.allocator,
            };

            // Parse labels
            if (obj.get("Labels")) |labels_val| {
                if (labels_val != .null) {
                    const labels_obj = labels_val.object;
                    var iter = labels_obj.iterator();
                    while (iter.next()) |entry| {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const value = try self.allocator.dupe(u8, entry.value_ptr.string);
                        try container.labels.put(key, value);
                    }
                }
            }

            try containers.append(self.allocator, container);
        }

        return containers.toOwnedSlice(self.allocator);
    }

    pub fn pullImage(self: *AsyncClient, rt: *zio.Runtime, image: []const u8) !void {
        log.info("Pulling image: {s}", .{image});

        const endpoint = try std.fmt.allocPrint(self.allocator, "/images/create?fromImage={s}", .{image});
        defer self.allocator.free(endpoint);

        const response_body = try self.makeRequest(rt, "POST", endpoint, "");
        defer self.allocator.free(response_body);

        log.info("Image pulled successfully: {s}", .{image});
    }

    pub fn stopContainer(self: *AsyncClient, rt: *zio.Runtime, id: []const u8, timeout: u64) !void {
        log.info("Stopping container: {s} (timeout: {d}s)", .{ id, timeout });

        const endpoint = try std.fmt.allocPrint(self.allocator, "/containers/{s}/stop?t={d}", .{ id, timeout });
        defer self.allocator.free(endpoint);

        const response_body = try self.makeRequest(rt, "POST", endpoint, "");
        defer self.allocator.free(response_body);

        log.info("Container stopped: {s}", .{id});
    }

    pub fn removeContainer(self: *AsyncClient, rt: *zio.Runtime, id: []const u8, remove_volumes: bool) !void {
        log.info("Removing container: {s} (remove_volumes: {})", .{ id, remove_volumes });

        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "/containers/{s}?v={s}",
            .{ id, if (remove_volumes) "true" else "false" },
        );
        defer self.allocator.free(endpoint);

        const response_body = try self.makeRequest(rt, "DELETE", endpoint, "");
        defer self.allocator.free(response_body);

        log.info("Container removed: {s}", .{id});
    }

    pub fn createContainer(self: *AsyncClient, rt: *zio.Runtime, name: []const u8, config_json: []const u8) ![]const u8 {
        log.info("Creating container: {s}", .{name});

        const endpoint = if (name.len > 0)
            try std.fmt.allocPrint(self.allocator, "/containers/create?name={s}", .{name})
        else
            try self.allocator.dupe(u8, "/containers/create");
        defer self.allocator.free(endpoint);

        const response_body = try self.makeRequest(rt, "POST", endpoint, config_json);
        defer self.allocator.free(response_body);

        // Parse response to get container ID
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const id = try self.allocator.dupe(u8, obj.get("Id").?.string);

        log.info("Container created: {s} (ID: {s})", .{ name, id });
        return id;
    }

    pub fn startContainer(self: *AsyncClient, rt: *zio.Runtime, id: []const u8) !void {
        log.info("Starting container: {s}", .{id});

        const endpoint = try std.fmt.allocPrint(self.allocator, "/containers/{s}/start", .{id});
        defer self.allocator.free(endpoint);

        const response_body = try self.makeRequest(rt, "POST", endpoint, "");
        defer self.allocator.free(response_body);

        log.info("Container started: {s}", .{id});
    }
};
