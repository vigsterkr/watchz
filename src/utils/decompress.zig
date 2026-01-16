const std = @import("std");
const log = @import("log.zig");

/// Decompress gzip-encoded HTTP response body using std.compress.flate
/// This handles the full gzip format including headers and footers
pub fn decompressGzip(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    // Create fixed buffer stream from compressed data
    var in_stream: std.Io.Reader = .fixed(compressed);

    // Initialize decompressor with .gzip container type
    // Empty buffer means direct mode (no windowing buffer needed)
    var decompress = std.compress.flate.Decompress.init(&in_stream, .gzip, &.{});

    // Use Allocating writer to collect decompressed output
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // Stream all decompressed data
    _ = decompress.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => {
            // Check if there's a more specific error from the decompressor
            if (decompress.err) |specific_err| {
                return specific_err;
            }
            return error.DecompressionFailed;
        },
        else => |e| return e,
    };

    return aw.toOwnedSlice();
}

/// Decompress deflate-encoded data (raw deflate stream without gzip headers)
/// This is for Content-Encoding: deflate
pub fn decompressDeflate(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in_stream: std.Io.Reader = .fixed(compressed);

    // Use .raw container for raw deflate streams
    var decompress = std.compress.flate.Decompress.init(&in_stream, .raw, &.{});

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    _ = decompress.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => {
            if (decompress.err) |specific_err| {
                return specific_err;
            }
            return error.DecompressionFailed;
        },
        else => |e| return e,
    };

    return aw.toOwnedSlice();
}

test "decompress gzip - Hello World" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // "Hello, World!" gzip compressed
    const compressed = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0xd7,
        0x51, 0x08, 0xcf, 0x2f, 0xca, 0x49, 0x51, 0x04,
        0x00, 0xd0, 0xc3, 0x4a, 0xec, 0x0d, 0x00, 0x00,
        0x00,
    };

    const decompressed = try decompressGzip(allocator, &compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings("Hello, World!", decompressed);
}

test "decompress gzip - JSON data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // {"token":"test123"} gzip compressed
    const compressed = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0xab, 0x56, 0x2a, 0xc9, 0xcf, 0x4e,
        0xcd, 0x53, 0xb2, 0x52, 0x2a, 0x49, 0x2d, 0x2e,
        0x31, 0x34, 0x32, 0x56, 0xaa, 0x05, 0x00, 0x73,
        0x29, 0x53, 0x85, 0x13, 0x00, 0x00, 0x00,
    };

    const decompressed = try decompressGzip(allocator, &compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings("{\"token\":\"test123\"}", decompressed);
}
