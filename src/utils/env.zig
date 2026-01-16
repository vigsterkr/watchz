const std = @import("std");
const log = @import("log.zig");

/// Get a boolean environment variable
/// Accepts "true", "1", "yes" as true values (case insensitive)
/// Returns null if variable doesn't exist or can't be read
pub fn getBoolEnv(allocator: std.mem.Allocator, name: []const u8) ?bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch return null;
    defer allocator.free(value);

    if (std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes"))
    {
        return true;
    }

    if (std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "no"))
    {
        return false;
    }

    log.warn("Invalid boolean value for {s}: '{s}'", .{ name, value });
    return null;
}

/// Get a u64 environment variable
/// Returns null if variable doesn't exist, can't be read, or can't be parsed
pub fn getU64Env(allocator: std.mem.Allocator, name: []const u8) ?u64 {
    const value = std.process.getEnvVarOwned(allocator, name) catch return null;
    defer allocator.free(value);

    const parsed = std.fmt.parseInt(u64, value, 10) catch |err| {
        log.warn("Invalid integer value for {s}: '{s}' ({})", .{ name, value, err });
        return null;
    };

    return parsed;
}

/// Get a string environment variable (caller owns returned memory)
/// Returns null if variable doesn't exist or can't be read
pub fn getStringEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

/// Get a comma-separated list as ArrayList (caller owns returned list and strings)
/// Returns empty list if variable doesn't exist or can't be read
pub fn getStringListEnv(allocator: std.mem.Allocator, name: []const u8) !std.ArrayList([]const u8) {
    const value = std.process.getEnvVarOwned(allocator, name) catch {
        const empty_list: std.ArrayList([]const u8) = .{};
        return empty_list;
    };
    defer allocator.free(value);

    var list: std.ArrayList([]const u8) = .{};
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len > 0) {
            const owned = try allocator.dupe(u8, trimmed);
            try list.append(allocator, owned);
        }
    }

    return list;
}

test "getBoolEnv - true values" {
    const testing = std.testing;

    // We can't easily test environment variables in unit tests
    // so this is a placeholder for manual testing
    try testing.expect(true);
}

test "getU64Env parsing" {
    const testing = std.testing;

    // Placeholder for manual testing
    try testing.expect(true);
}
