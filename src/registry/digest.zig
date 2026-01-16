const std = @import("std");
const log = @import("../utils/log.zig");

/// Digest represents a content-addressable hash
pub const Digest = struct {
    algorithm: Algorithm,
    hash: []const u8,
    allocator: std.mem.Allocator,

    pub const Algorithm = enum {
        sha256,
        sha512,

        pub fn fromString(s: []const u8) !Algorithm {
            if (std.mem.eql(u8, s, "sha256")) return .sha256;
            if (std.mem.eql(u8, s, "sha512")) return .sha512;
            return error.UnsupportedAlgorithm;
        }

        pub fn toString(self: Algorithm) []const u8 {
            return switch (self) {
                .sha256 => "sha256",
                .sha512 => "sha512",
            };
        }
    };

    /// Parse a digest string like "sha256:abc123..."
    pub fn parse(allocator: std.mem.Allocator, digest_str: []const u8) !Digest {
        const colon_idx = std.mem.indexOf(u8, digest_str, ":") orelse {
            return error.InvalidDigestFormat;
        };

        const algo_str = digest_str[0..colon_idx];
        const hash_str = digest_str[colon_idx + 1 ..];

        if (hash_str.len == 0) {
            return error.InvalidDigestFormat;
        }

        const algorithm = try Algorithm.fromString(algo_str);

        return .{
            .algorithm = algorithm,
            .hash = try allocator.dupe(u8, hash_str),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Digest) void {
        self.allocator.free(self.hash);
    }

    /// Convert digest back to string format "algorithm:hash"
    pub fn toString(self: *const Digest, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{s}:{s}",
            .{ self.algorithm.toString(), self.hash },
        );
    }

    /// Check if two digests are equal
    pub fn equals(self: *const Digest, other: *const Digest) bool {
        if (self.algorithm != other.algorithm) return false;
        return std.mem.eql(u8, self.hash, other.hash);
    }
};

/// Compare two digest strings for equality
pub fn compareDigests(digest1: []const u8, digest2: []const u8) bool {
    return std.mem.eql(u8, digest1, digest2);
}

/// Validate that a digest string has the correct format
pub fn validateDigest(digest_str: []const u8) bool {
    const colon_idx = std.mem.indexOf(u8, digest_str, ":") orelse return false;

    const algo_str = digest_str[0..colon_idx];
    const hash_str = digest_str[colon_idx + 1 ..];

    // Check algorithm
    const valid_algo = std.mem.eql(u8, algo_str, "sha256") or
        std.mem.eql(u8, algo_str, "sha512");
    if (!valid_algo) return false;

    // Check hash is hex and appropriate length
    if (hash_str.len == 0) return false;

    // SHA256 = 64 hex chars, SHA512 = 128 hex chars
    const expected_len: usize = if (std.mem.eql(u8, algo_str, "sha256")) 64 else 128;
    if (hash_str.len != expected_len) return false;

    // Verify all characters are valid hex
    for (hash_str) |c| {
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

/// Extract the digest from a Docker image reference
/// Handles formats like:
/// - "nginx@sha256:abc123..."
/// - "ghcr.io/owner/repo@sha256:def456..."
pub fn extractDigestFromReference(image_ref: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, image_ref, "@")) |at_idx| {
        const digest = image_ref[at_idx + 1 ..];
        if (validateDigest(digest)) {
            return digest;
        }
    }
    return null;
}

/// Short digest for display (first 12 characters of hash)
pub fn shortDigest(digest_str: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const colon_idx = std.mem.indexOf(u8, digest_str, ":") orelse {
        // If no colon, assume it's just the hash
        if (digest_str.len <= 12) {
            return try allocator.dupe(u8, digest_str);
        }
        return try allocator.dupe(u8, digest_str[0..12]);
    };

    const algo_str = digest_str[0..colon_idx];
    const hash_str = digest_str[colon_idx + 1 ..];

    const short_hash = if (hash_str.len > 12) hash_str[0..12] else hash_str;

    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ algo_str, short_hash });
}

/// Calculate SHA256 digest of data
pub fn calculateSha256(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var hash_bytes: [32]u8 = undefined;
    hasher.final(&hash_bytes);

    return try std.fmt.allocPrint(
        allocator,
        "sha256:{s}",
        .{std.fmt.fmtSliceHexLower(&hash_bytes)},
    );
}

test "Digest parse and toString" {
    const allocator = std.testing.allocator;

    var digest = try Digest.parse(allocator, "sha256:abc123def456");
    defer digest.deinit();

    try std.testing.expectEqual(Digest.Algorithm.sha256, digest.algorithm);
    try std.testing.expectEqualStrings("abc123def456", digest.hash);

    const digest_str = try digest.toString(allocator);
    defer allocator.free(digest_str);

    try std.testing.expectEqualStrings("sha256:abc123def456", digest_str);
}

test "Digest equality" {
    const allocator = std.testing.allocator;

    var digest1 = try Digest.parse(allocator, "sha256:abc123");
    defer digest1.deinit();

    var digest2 = try Digest.parse(allocator, "sha256:abc123");
    defer digest2.deinit();

    var digest3 = try Digest.parse(allocator, "sha256:def456");
    defer digest3.deinit();

    try std.testing.expect(digest1.equals(&digest2));
    try std.testing.expect(!digest1.equals(&digest3));
}

test "validateDigest" {
    const valid = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(validateDigest(valid));

    const invalid_algo = "md5:abc123";
    try std.testing.expect(!validateDigest(invalid_algo));

    const invalid_length = "sha256:abc";
    try std.testing.expect(!validateDigest(invalid_length));

    const invalid_chars = "sha256:xyz123def456xyz789abc012def345abc678def901abc234def567abc890def123";
    try std.testing.expect(!validateDigest(invalid_chars));
}

test "extractDigestFromReference" {
    const ref1 = "nginx@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const digest1 = extractDigestFromReference(ref1);
    try std.testing.expect(digest1 != null);
    try std.testing.expectEqualStrings("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", digest1.?);

    const ref2 = "nginx:latest";
    const digest2 = extractDigestFromReference(ref2);
    try std.testing.expect(digest2 == null);
}

test "shortDigest" {
    const allocator = std.testing.allocator;

    const long = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const short = try shortDigest(long, allocator);
    defer allocator.free(short);

    try std.testing.expectEqualStrings("sha256:0123456789ab", short);
}

test "calculateSha256" {
    const allocator = std.testing.allocator;

    const data = "hello world";
    const digest = try calculateSha256(allocator, data);
    defer allocator.free(digest);

    // SHA256 of "hello world" is b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
    try std.testing.expectEqualStrings("sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", digest);
}
