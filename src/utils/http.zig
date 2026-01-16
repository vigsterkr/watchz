const std = @import("std");

/// Reusable HTTP utilities for notification backends
pub const HttpUtils = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpUtils {
        return HttpUtils{ .allocator = allocator };
    }

    /// Send a JSON POST request to a URL
    /// extra_headers: optional StringHashMap for additional headers (e.g., Authorization)
    pub fn postJson(
        self: HttpUtils,
        url: []const u8,
        payload: []const u8,
        extra_headers: ?std.StringHashMap([]const u8),
    ) !void {
        const uri = try std.Uri.parse(url);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Prepare request
        const server_header_buffer_size = 16 * 1024;
        var server_header_buffer: [server_header_buffer_size]u8 = undefined;

        var request = try client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
        });
        defer request.deinit();

        // Add custom headers if any
        if (extra_headers) |headers| {
            var it = headers.iterator();
            while (it.next()) |entry| {
                try request.headers.append(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // Set content length and send
        request.transfer_encoding = .{ .content_length = payload.len };
        try request.send();

        // Write body
        try request.writeAll(payload);
        try request.finish();

        // Wait for response
        try request.wait();

        // Check status
        if (!isSuccessStatus(request.response.status)) {
            std.log.warn("HTTP POST returned non-success status: {}", .{request.response.status});
            return error.HttpPostFailed;
        }

        std.log.debug("HTTP POST successful to {s}", .{url});
    }

    /// Validate HTTP success status codes
    pub fn isSuccessStatus(status: std.http.Status) bool {
        return status == .ok or
            status == .created or
            status == .accepted or
            status == .no_content;
    }
};

test "HttpUtils creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const utils = HttpUtils.init(allocator);
    _ = utils;

    try testing.expect(true);
}

test "isSuccessStatus" {
    const testing = std.testing;

    try testing.expect(HttpUtils.isSuccessStatus(.ok));
    try testing.expect(HttpUtils.isSuccessStatus(.created));
    try testing.expect(HttpUtils.isSuccessStatus(.accepted));
    try testing.expect(HttpUtils.isSuccessStatus(.no_content));
    try testing.expect(!HttpUtils.isSuccessStatus(.bad_request));
    try testing.expect(!HttpUtils.isSuccessStatus(.internal_server_error));
}
