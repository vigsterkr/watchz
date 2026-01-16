const std = @import("std");

/// Encode a string to base64 (caller owns returned memory)
pub fn base64Encode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(input.len);
    const buffer = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(buffer, input);
    return buffer;
}

/// Encode username:password for HTTP Basic auth (caller owns returned memory)
pub fn encodeBasicAuth(allocator: std.mem.Allocator, username: []const u8, password: []const u8) ![]const u8 {
    const auth_str = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(auth_str);
    return base64Encode(allocator, auth_str);
}

/// Create a full "Basic <encoded>" header value (caller owns returned memory)
pub fn createBasicAuthHeader(allocator: std.mem.Allocator, username: []const u8, password: []const u8) ![]const u8 {
    const encoded = try encodeBasicAuth(allocator, username, password);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
}

test "base64 encoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "hello:world";
    const encoded = try base64Encode(allocator, input);
    defer allocator.free(encoded);

    try testing.expectEqualStrings("aGVsbG86d29ybGQ=", encoded);
}

test "basic auth encoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = try encodeBasicAuth(allocator, "user", "pass");
    defer allocator.free(encoded);

    try testing.expectEqualStrings("dXNlcjpwYXNz", encoded);
}

test "basic auth header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const header = try createBasicAuthHeader(allocator, "user", "pass");
    defer allocator.free(header);

    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", header);
}
