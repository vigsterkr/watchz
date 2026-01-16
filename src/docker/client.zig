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

    fn decodeChunkedBody(self: *AsyncClient, rt: *zio.Runtime, stream: anytype, initial_data: []const u8) ![]u8 {
        var body: std.ArrayList(u8) = .{};
        errdefer body.deinit(self.allocator);

        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);

        // Start with any data already read after headers
        try buffer.appendSlice(self.allocator, initial_data);

        var read_buffer: [8192]u8 = undefined;
        var parser = std.http.ChunkParser.init;

        while (true) {
            // Feed data to parser
            const consumed = parser.feed(buffer.items);

            switch (parser.state) {
                .data => {
                    const chunk_size = parser.chunk_len;

                    // If chunk size is 0, we're done
                    if (chunk_size == 0) break;

                    // consumed tells us where chunk data starts
                    const chunk_start = consumed;
                    const chunk_end = chunk_start + chunk_size;

                    // Read more data until we have the full chunk
                    while (buffer.items.len < chunk_end) {
                        const n = try stream.read(rt, &read_buffer);
                        if (n == 0) return error.UnexpectedEndOfStream;
                        try buffer.appendSlice(self.allocator, read_buffer[0..n]);
                    }

                    // Extract chunk data
                    try body.appendSlice(self.allocator, buffer.items[chunk_start..chunk_end]);

                    // Remove processed data from buffer
                    const remaining_start = chunk_end;
                    if (buffer.items.len > remaining_start) {
                        const remaining = try self.allocator.dupe(u8, buffer.items[remaining_start..]);
                        buffer.clearRetainingCapacity();
                        try buffer.appendSlice(self.allocator, remaining);
                        self.allocator.free(remaining);
                    } else {
                        buffer.clearRetainingCapacity();
                    }

                    // Reset parser for next chunk
                    parser.state = .data_suffix;
                    parser.chunk_len = 0;
                },
                .invalid => {
                    log.err("Invalid chunk encoding", .{});
                    return error.InvalidChunkEncoding;
                },
                else => {
                    // Parser needs more data
                    const n = try stream.read(rt, &read_buffer);
                    if (n == 0) {
                        if (parser.state == .head_size and parser.chunk_len == 0) {
                            // Possible end of stream
                            break;
                        }
                        return error.UnexpectedEndOfStream;
                    }
                    try buffer.appendSlice(self.allocator, read_buffer[0..n]);
                },
            }
        }

        return try body.toOwnedSlice(self.allocator);
    }

    fn readHttpResponse(self: *AsyncClient, rt: *zio.Runtime, stream: anytype) ![]u8 {
        // Read response with dynamic buffer
        var response: std.ArrayList(u8) = .{};
        errdefer response.deinit(self.allocator);

        var read_buffer: [8192]u8 = undefined;
        var header_end_pos: ?usize = null;
        var content_length: ?usize = null;
        var status_code: u16 = 0;

        // Read until we have headers
        while (header_end_pos == null) {
            const n = try stream.read(rt, &read_buffer);
            if (n == 0) {
                response.deinit(self.allocator);
                return error.InvalidResponse;
            }

            try response.appendSlice(self.allocator, read_buffer[0..n]);

            // Look for header end
            if (std.mem.indexOf(u8, response.items, "\r\n\r\n")) |pos| {
                header_end_pos = pos;
            } else if (std.mem.indexOf(u8, response.items, "\n\n")) |pos| {
                header_end_pos = pos;
            }
        }

        const header_end = header_end_pos.?;
        const headers_data = response.items[0..header_end];
        const body_start = if (std.mem.indexOf(u8, response.items, "\r\n\r\n")) |_| header_end + 4 else header_end + 2;

        // Parse status line and headers
        var lines = std.mem.splitScalar(u8, headers_data, '\n');
        const status_line = lines.next() orelse {
            response.deinit(self.allocator);
            return error.InvalidResponse;
        };

        // Extract status code
        var status_iter = std.mem.splitScalar(u8, status_line, ' ');
        _ = status_iter.next(); // HTTP/1.1
        const status_code_str = status_iter.next() orelse {
            response.deinit(self.allocator);
            return error.InvalidResponse;
        };
        status_code = try std.fmt.parseInt(u16, std.mem.trim(u8, status_code_str, " \r"), 10);

        // Parse headers for Content-Length and Transfer-Encoding
        var is_chunked = false;
        var header_lines = std.mem.splitScalar(u8, headers_data, '\n');
        _ = header_lines.next(); // Skip status line
        while (header_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                const value = std.mem.trim(u8, trimmed[15..], " ");
                content_length = try std.fmt.parseInt(usize, value, 10);
            } else if (std.ascii.startsWithIgnoreCase(trimmed, "transfer-encoding:")) {
                const value = std.mem.trim(u8, trimmed[18..], " ");
                if (std.mem.indexOf(u8, value, "chunked") != null) {
                    is_chunked = true;
                }
            }
        }

        var response_body: []u8 = undefined;

        // Handle chunked encoding
        if (is_chunked) {
            log.debug("Detected chunked transfer encoding", .{});
            const initial_body = response.items[body_start..];
            response_body = try self.decodeChunkedBody(rt, stream, initial_body);
            response.deinit(self.allocator);
        } else if (content_length) |expected_len| {
            // If we have Content-Length, read until we have all the body
            while (true) {
                const current_body_len = response.items.len - body_start;
                if (current_body_len >= expected_len) break;

                const n = try stream.read(rt, &read_buffer);
                if (n == 0) break; // Connection closed

                try response.appendSlice(self.allocator, read_buffer[0..n]);
            }

            // Extract body
            const body_data = response.items[body_start..];
            response_body = try self.allocator.dupe(u8, body_data);
            response.deinit(self.allocator);
        } else {
            // No Content-Length or chunked encoding, use what we have
            const body_data = response.items[body_start..];
            response_body = try self.allocator.dupe(u8, body_data);
            response.deinit(self.allocator);
        }

        if (status_code < 200 or status_code >= 300) {
            log.err("Docker API error: HTTP {d}", .{status_code});
            log.err("Response: {s}", .{response_body});
            self.allocator.free(response_body);
            return error.DockerApiError;
        }

        return response_body;
    }

    fn makeUnversionedRequest(self: *AsyncClient, rt: *zio.Runtime, method: []const u8, endpoint: []const u8, body: []const u8) ![]u8 {
        // Connect to Unix socket
        const addr = try zio.net.UnixAddress.init(self.socket_path);
        const stream = try addr.connect(rt);
        defer stream.close(rt);

        // Build HTTP request (without version prefix)
        const request = try std.fmt.allocPrint(
            self.allocator,
            "{s} {s} HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "User-Agent: WatchZ/0.1.0\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "\r\n" ++
                "{s}",
            .{ method, endpoint, body.len, body },
        );
        defer self.allocator.free(request);

        // Send request using stream directly
        try stream.writeAll(rt, request);

        // Read and parse response using utility function
        return try self.readHttpResponse(rt, stream);
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

        // Read and parse response using utility function
        return try self.readHttpResponse(rt, stream);
    }

    pub fn negotiateApiVersion(self: *AsyncClient, rt: *zio.Runtime) !void {
        log.debug("Negotiating Docker API version", .{});

        // Call /version endpoint without version prefix to get API version info
        const response_body = try self.makeUnversionedRequest(rt, "GET", "/version", "");
        defer self.allocator.free(response_body);

        // Parse response to get ApiVersion
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        // Get the API version from the daemon
        if (obj.get("ApiVersion")) |api_version_val| {
            const negotiated_version = api_version_val.string;

            // Update our client's API version (need to allocate since it's a slice)
            const owned_version = try self.allocator.dupe(u8, negotiated_version);

            // Free the old version if it was allocated
            // (in our case, it comes from config so we don't free it here)

            self.api_version = owned_version;

            log.info("Negotiated Docker API version: {s}", .{self.api_version});
        } else {
            log.warn("Failed to negotiate API version, using default: {s}", .{self.api_version});
        }
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

    pub fn inspectContainer(self: *AsyncClient, rt: *zio.Runtime, id: []const u8) !types.ContainerDetails {
        log.debug("Inspecting container: {s}", .{id});

        const endpoint = try std.fmt.allocPrint(self.allocator, "/containers/{s}/json", .{id});
        defer self.allocator.free(endpoint);

        const response_body = try self.makeRequest(rt, "GET", endpoint, "");
        defer self.allocator.free(response_body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        var details = types.ContainerDetails{
            .id = try self.allocator.dupe(u8, obj.get("Id").?.string),
            .name = blk: {
                const name = obj.get("Name").?.string;
                const clean_name = if (name.len > 0 and name[0] == '/') name[1..] else name;
                break :blk try self.allocator.dupe(u8, clean_name);
            },
            .image = try self.allocator.dupe(u8, obj.get("Image").?.string),
            .config = types.ContainerConfig.init(self.allocator),
            .state = undefined,
            .host_config = types.HostConfig.init(self.allocator),
            .network_settings = types.NetworkSettings.init(self.allocator),
            .allocator = self.allocator,
        };
        errdefer details.deinit();

        // Parse Config
        if (obj.get("Config")) |config_val| {
            const config_obj = config_val.object;

            if (config_obj.get("Hostname")) |v| {
                details.config.hostname = try self.allocator.dupe(u8, v.string);
            }
            if (config_obj.get("User")) |v| {
                if (v != .null and v.string.len > 0) {
                    details.config.user = try self.allocator.dupe(u8, v.string);
                }
            }
            if (config_obj.get("WorkingDir")) |v| {
                if (v != .null and v.string.len > 0) {
                    details.config.working_dir = try self.allocator.dupe(u8, v.string);
                }
            }
            if (config_obj.get("Image")) |v| {
                details.config.image = try self.allocator.dupe(u8, v.string);
            }

            // Parse Env
            if (config_obj.get("Env")) |env_val| {
                if (env_val != .null) {
                    for (env_val.array.items) |env_item| {
                        try details.config.env.append(self.allocator, try self.allocator.dupe(u8, env_item.string));
                    }
                }
            }

            // Parse Cmd
            if (config_obj.get("Cmd")) |cmd_val| {
                if (cmd_val != .null) {
                    for (cmd_val.array.items) |cmd_item| {
                        try details.config.cmd.append(self.allocator, try self.allocator.dupe(u8, cmd_item.string));
                    }
                }
            }

            // Parse Entrypoint
            if (config_obj.get("Entrypoint")) |ep_val| {
                if (ep_val != .null) {
                    for (ep_val.array.items) |ep_item| {
                        try details.config.entrypoint.append(self.allocator, try self.allocator.dupe(u8, ep_item.string));
                    }
                }
            }

            // Parse Labels
            if (config_obj.get("Labels")) |labels_val| {
                if (labels_val != .null) {
                    var iter = labels_val.object.iterator();
                    while (iter.next()) |entry| {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const value = try self.allocator.dupe(u8, entry.value_ptr.string);
                        try details.config.labels.put(key, value);
                    }
                }
            }

            // Parse ExposedPorts
            if (config_obj.get("ExposedPorts")) |ports_val| {
                if (ports_val != .null) {
                    var iter = ports_val.object.iterator();
                    while (iter.next()) |entry| {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        try details.config.exposed_ports.put(key, .{});
                    }
                }
            }

            // Parse Volumes
            if (config_obj.get("Volumes")) |vols_val| {
                if (vols_val != .null) {
                    var iter = vols_val.object.iterator();
                    while (iter.next()) |entry| {
                        const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                        try details.config.volumes.put(key, .{});
                    }
                }
            }
        }

        // Parse State
        if (obj.get("State")) |state_val| {
            const state_obj = state_val.object;
            details.state = types.ContainerState{
                .status = try self.allocator.dupe(u8, state_obj.get("Status").?.string),
                .running = state_obj.get("Running").?.bool,
                .paused = state_obj.get("Paused").?.bool,
                .restarting = state_obj.get("Restarting").?.bool,
                .pid = @intCast(state_obj.get("Pid").?.integer),
                .exit_code = @intCast(state_obj.get("ExitCode").?.integer),
                .started_at = if (state_obj.get("StartedAt")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
                .finished_at = if (state_obj.get("FinishedAt")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
                .allocator = self.allocator,
            };
        }

        // Parse HostConfig
        if (obj.get("HostConfig")) |hc_val| {
            const hc_obj = hc_val.object;

            // Parse Binds
            if (hc_obj.get("Binds")) |binds_val| {
                if (binds_val != .null) {
                    for (binds_val.array.items) |bind_item| {
                        try details.host_config.binds.append(self.allocator, try self.allocator.dupe(u8, bind_item.string));
                    }
                }
            }

            // Parse PortBindings
            if (hc_obj.get("PortBindings")) |pb_val| {
                if (pb_val != .null) {
                    var iter = pb_val.object.iterator();
                    while (iter.next()) |entry| {
                        const port = try self.allocator.dupe(u8, entry.key_ptr.*);
                        var bindings: std.ArrayList(types.PortBinding) = .{};

                        for (entry.value_ptr.array.items) |binding_item| {
                            const binding_obj = binding_item.object;
                            const host_ip = if (binding_obj.get("HostIp")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, "");
                            const host_port = if (binding_obj.get("HostPort")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, "");

                            try bindings.append(self.allocator, types.PortBinding{
                                .host_ip = host_ip,
                                .host_port = host_port,
                            });
                        }

                        try details.host_config.port_bindings.put(port, bindings);
                    }
                }
            }

            // Parse RestartPolicy
            if (hc_obj.get("RestartPolicy")) |rp_val| {
                const rp_obj = rp_val.object;
                if (rp_obj.get("Name")) |name_val| {
                    details.host_config.restart_policy.name = try self.allocator.dupe(u8, name_val.string);
                }
                if (rp_obj.get("MaximumRetryCount")) |count_val| {
                    details.host_config.restart_policy.maximum_retry_count = @intCast(count_val.integer);
                }
            }

            // Parse NetworkMode
            if (hc_obj.get("NetworkMode")) |v| {
                details.host_config.network_mode = try self.allocator.dupe(u8, v.string);
            }

            // Parse Privileged
            if (hc_obj.get("Privileged")) |v| {
                details.host_config.privileged = v.bool;
            }

            // Parse Links
            if (hc_obj.get("Links")) |links_val| {
                if (links_val != .null) {
                    for (links_val.array.items) |link_item| {
                        try details.host_config.links.append(self.allocator, try self.allocator.dupe(u8, link_item.string));
                    }
                }
            }

            // Parse AutoRemove
            if (hc_obj.get("AutoRemove")) |v| {
                details.host_config.auto_remove = v.bool;
            }

            // Parse PublishAllPorts
            if (hc_obj.get("PublishAllPorts")) |v| {
                details.host_config.publish_all_ports = v.bool;
            }

            // Parse CapAdd
            if (hc_obj.get("CapAdd")) |cap_val| {
                if (cap_val != .null) {
                    for (cap_val.array.items) |cap_item| {
                        try details.host_config.cap_add.append(self.allocator, try self.allocator.dupe(u8, cap_item.string));
                    }
                }
            }

            // Parse CapDrop
            if (hc_obj.get("CapDrop")) |cap_val| {
                if (cap_val != .null) {
                    for (cap_val.array.items) |cap_item| {
                        try details.host_config.cap_drop.append(self.allocator, try self.allocator.dupe(u8, cap_item.string));
                    }
                }
            }
        }

        // Parse NetworkSettings
        if (obj.get("NetworkSettings")) |ns_val| {
            const ns_obj = ns_val.object;
            if (ns_obj.get("Networks")) |networks_val| {
                if (networks_val != .null) {
                    var iter = networks_val.object.iterator();
                    while (iter.next()) |entry| {
                        const network_name = try self.allocator.dupe(u8, entry.key_ptr.*);
                        const network_obj = entry.value_ptr.object;

                        var network_endpoint = types.NetworkEndpoint{
                            .network_id = if (network_obj.get("NetworkID")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
                            .ip_address = if (network_obj.get("IPAddress")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
                            .gateway = if (network_obj.get("Gateway")) |v| try self.allocator.dupe(u8, v.string) else try self.allocator.dupe(u8, ""),
                            .ip_prefix_len = if (network_obj.get("IPPrefixLen")) |v| @intCast(v.integer) else 0,
                            .aliases = .{},
                        };

                        // Parse aliases
                        if (network_obj.get("Aliases")) |aliases_val| {
                            if (aliases_val != .null) {
                                for (aliases_val.array.items) |alias_item| {
                                    try network_endpoint.aliases.append(self.allocator, try self.allocator.dupe(u8, alias_item.string));
                                }
                            }
                        }

                        try details.network_settings.networks.put(network_name, network_endpoint);
                    }
                }
            }
        }

        log.debug("Container inspected successfully: {s}", .{details.name});
        return details;
    }

    pub fn inspectImage(self: *AsyncClient, rt: *zio.Runtime, image: []const u8) !types.Image {
        log.debug("Inspecting image: {s}", .{image});

        const endpoint = try std.fmt.allocPrint(self.allocator, "/images/{s}/json", .{image});
        defer self.allocator.free(endpoint);

        const response_body = try self.makeRequest(rt, "GET", endpoint, "");
        defer self.allocator.free(response_body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        var image_info = types.Image{
            .id = try self.allocator.dupe(u8, obj.get("Id").?.string),
            .repo_tags = .{},
            .repo_digests = .{},
            .created = 0,
            .size = 0,
            .allocator = self.allocator,
        };
        errdefer image_info.deinit();

        // Parse RepoTags
        if (obj.get("RepoTags")) |tags_val| {
            if (tags_val != .null) {
                const tags = tags_val.array;
                for (tags.items) |tag| {
                    const tag_str = try self.allocator.dupe(u8, tag.string);
                    try image_info.repo_tags.append(self.allocator, tag_str);
                }
            }
        }

        // Parse RepoDigests - this is what we need!
        if (obj.get("RepoDigests")) |digests_val| {
            if (digests_val != .null) {
                const digests = digests_val.array;
                for (digests.items) |digest| {
                    const digest_str = try self.allocator.dupe(u8, digest.string);
                    try image_info.repo_digests.append(self.allocator, digest_str);
                }
            }
        }

        // Parse Created (Unix timestamp string or integer)
        if (obj.get("Created")) |created_val| {
            image_info.created = switch (created_val) {
                .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
                .integer => |i| i,
                else => 0,
            };
        }

        // Parse Size
        if (obj.get("Size")) |size_val| {
            image_info.size = switch (size_val) {
                .integer => |i| @intCast(i),
                else => 0,
            };
        }

        log.debug("Image inspected: {s}, {d} RepoDigests found", .{ image, image_info.repo_digests.items.len });

        return image_info;
    }

    pub fn connectNetwork(
        self: *AsyncClient,
        rt: *zio.Runtime,
        network_id: []const u8,
        container_id: []const u8,
        endpoint_config: ?[]const u8,
    ) !void {
        log.debug("Connecting container {s} to network {s}", .{ container_id, network_id });

        const endpoint_str = try std.fmt.allocPrint(self.allocator, "/networks/{s}/connect", .{network_id});
        defer self.allocator.free(endpoint_str);

        const body = if (endpoint_config) |config|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"Container\": \"{s}\", \"EndpointConfig\": {s}}}",
                .{ container_id, config },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"Container\": \"{s}\"}}",
                .{container_id},
            );
        defer self.allocator.free(body);

        const response_body = try self.makeRequest(rt, "POST", endpoint_str, body);
        defer self.allocator.free(response_body);

        log.debug("Container connected to network successfully", .{});
    }

    pub fn disconnectNetwork(
        self: *AsyncClient,
        rt: *zio.Runtime,
        network_id: []const u8,
        container_id: []const u8,
        force: bool,
    ) !void {
        log.debug("Disconnecting container {s} from network {s}", .{ container_id, network_id });

        const endpoint_str = try std.fmt.allocPrint(self.allocator, "/networks/{s}/disconnect", .{network_id});
        defer self.allocator.free(endpoint_str);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"Container\": \"{s}\", \"Force\": {s}}}",
            .{ container_id, if (force) "true" else "false" },
        );
        defer self.allocator.free(body);

        const response_body = try self.makeRequest(rt, "POST", endpoint_str, body);
        defer self.allocator.free(response_body);

        log.debug("Container disconnected from network successfully", .{});
    }
};
