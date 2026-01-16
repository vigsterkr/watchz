const std = @import("std");
const log = @import("../utils/log.zig");

/// Represents Docker authentication entry
pub const AuthEntry = struct {
    auth: []const u8, // base64 encoded username:password
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AuthEntry) void {
        self.allocator.free(self.auth);
    }
};

/// Docker config.json structure
pub const DockerConfig = struct {
    auths: std.StringHashMap(AuthEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DockerConfig {
        return .{
            .auths = std.StringHashMap(AuthEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DockerConfig) void {
        var iter = self.auths.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var auth_entry = entry.value_ptr.*;
            auth_entry.deinit();
        }
        self.auths.deinit();
    }

    /// Get authentication for a specific registry
    pub fn getAuth(self: *DockerConfig, registry: []const u8) ?AuthEntry {
        return self.auths.get(registry);
    }

    /// Decode base64 auth string to get username and password
    pub fn decodeAuth(allocator: std.mem.Allocator, auth_base64: []const u8) !struct { username: []u8, password: []u8 } {
        // Decode base64 - use explicit pointer to the decoder instance
        const decoder = &std.base64.standard.Decoder;

        const decoded_len = try decoder.calcSizeForSlice(auth_base64);

        const decoded = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(decoded);

        try decoder.decode(decoded, auth_base64);

        // Split by ':'
        const colon_idx = std.mem.indexOf(u8, decoded, ":") orelse {
            allocator.free(decoded);
            return error.InvalidAuthFormat;
        };

        const username = try allocator.dupe(u8, decoded[0..colon_idx]);
        errdefer allocator.free(username);

        const password = try allocator.dupe(u8, decoded[colon_idx + 1 ..]);
        errdefer allocator.free(password);

        allocator.free(decoded);

        return .{
            .username = username,
            .password = password,
        };
    }
};

/// Load Docker config from ~/.docker/config.json
pub fn loadDockerConfig(allocator: std.mem.Allocator) !DockerConfig {
    var config = DockerConfig.init(allocator);
    errdefer config.deinit();

    // Get home directory
    const home = std.posix.getenv("HOME") orelse {
        log.debug("HOME environment variable not set", .{});
        return config; // Return empty config
    };

    // Build config path
    const config_path = try std.fmt.allocPrint(allocator, "{s}/.docker/config.json", .{home});
    defer allocator.free(config_path);

    // Try to read the file
    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        log.debug("Could not open Docker config at {s}: {}", .{ config_path, err });
        return config; // Return empty config
    };
    defer file.close();

    // Read file contents
    const file_size = try file.getEndPos();
    const contents = try allocator.alloc(u8, file_size);
    defer allocator.free(contents);

    const bytes_read = try file.readAll(contents);

    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents[0..bytes_read], .{}) catch |err| {
        log.warn("Failed to parse Docker config JSON: {}", .{err});
        return config; // Return empty config
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Extract auths
    if (root.get("auths")) |auths_val| {
        if (auths_val == .object) {
            const auths_obj = auths_val.object;
            var iter = auths_obj.iterator();

            while (iter.next()) |entry| {
                const registry = entry.key_ptr.*;
                const auth_obj = entry.value_ptr.*;

                if (auth_obj != .object) continue;

                // Get auth field
                if (auth_obj.object.get("auth")) |auth_val| {
                    if (auth_val == .string) {
                        const registry_copy = try allocator.dupe(u8, registry);
                        errdefer allocator.free(registry_copy);

                        const auth_copy = try allocator.dupe(u8, auth_val.string);
                        errdefer allocator.free(auth_copy);

                        const auth_entry = AuthEntry{
                            .auth = auth_copy,
                            .allocator = allocator,
                        };

                        try config.auths.put(registry_copy, auth_entry);
                        log.debug("Loaded credentials for registry: {s}", .{registry});
                    }
                }
            }
        }
    }

    return config;
}

test "decode auth string" {
    const allocator = std.testing.allocator;

    // "username:password" in base64 is "dXNlcm5hbWU6cGFzc3dvcmQ="
    const auth_base64 = "dXNlcm5hbWU6cGFzc3dvcmQ=";

    const result = try DockerConfig.decodeAuth(allocator, auth_base64);
    defer allocator.free(result.username);
    defer allocator.free(result.password);

    try std.testing.expectEqualStrings("username", result.username);
    try std.testing.expectEqualStrings("password", result.password);
}
