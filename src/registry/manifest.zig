const std = @import("std");
const types = @import("types.zig");
const log = @import("../utils/log.zig");

/// Parse a Docker Registry V2 manifest from JSON
pub fn parseManifest(allocator: std.mem.Allocator, json_data: []const u8) !types.Manifest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const schema_version = root.get("schemaVersion") orelse {
        return error.InvalidManifest;
    };

    const media_type = root.get("mediaType") orelse {
        return error.InvalidManifest;
    };

    // Extract config
    const config_obj = root.get("config") orelse {
        return error.InvalidManifest;
    };

    const config = try parseManifestConfig(allocator, config_obj.object);

    // Extract layers
    const layers_array = root.get("layers") orelse {
        return error.InvalidManifest;
    };

    var layers = std.ArrayList(types.ManifestLayer).init(allocator);
    errdefer {
        for (layers.items) |*layer| {
            layer.deinit();
        }
        layers.deinit();
    }

    for (layers_array.array.items) |layer_value| {
        const layer = try parseManifestLayer(allocator, layer_value.object);
        try layers.append(layer);
    }

    // Calculate manifest digest (sha256 of the JSON)
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(json_data);
    var digest_bytes: [32]u8 = undefined;
    hasher.final(&digest_bytes);

    const digest = try std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.fmtSliceHexLower(&digest_bytes)});

    return .{
        .schema_version = @intCast(schema_version.integer),
        .media_type = try allocator.dupe(u8, media_type.string),
        .digest = digest,
        .config = config,
        .layers = layers,
        .allocator = allocator,
    };
}

fn parseManifestConfig(allocator: std.mem.Allocator, config_obj: std.json.ObjectMap) !types.ManifestConfig {
    const media_type = config_obj.get("mediaType") orelse {
        return error.InvalidManifestConfig;
    };

    const size = config_obj.get("size") orelse {
        return error.InvalidManifestConfig;
    };

    const digest = config_obj.get("digest") orelse {
        return error.InvalidManifestConfig;
    };

    return .{
        .media_type = try allocator.dupe(u8, media_type.string),
        .size = @intCast(size.integer),
        .digest = try allocator.dupe(u8, digest.string),
        .allocator = allocator,
    };
}

fn parseManifestLayer(allocator: std.mem.Allocator, layer_obj: std.json.ObjectMap) !types.ManifestLayer {
    const media_type = layer_obj.get("mediaType") orelse {
        return error.InvalidManifestLayer;
    };

    const size = layer_obj.get("size") orelse {
        return error.InvalidManifestLayer;
    };

    const digest = layer_obj.get("digest") orelse {
        return error.InvalidManifestLayer;
    };

    return .{
        .media_type = try allocator.dupe(u8, media_type.string),
        .size = @intCast(size.integer),
        .digest = try allocator.dupe(u8, digest.string),
        .allocator = allocator,
    };
}

/// Extract the digest from a Docker image reference
/// This handles both ID and RepoDigests formats
pub fn extractDigestFromImage(image_id: []const u8, repo_digests: []const []const u8) ?[]const u8 {
    // Prefer RepoDigests over ImageID
    if (repo_digests.len > 0) {
        // RepoDigests format: "nginx@sha256:abc123..."
        const digest_str = repo_digests[0];
        if (std.mem.indexOf(u8, digest_str, "@")) |at_idx| {
            return digest_str[at_idx + 1 ..];
        }
    }

    // Fall back to ImageID
    // ImageID format: "sha256:abc123..." or just the hash
    if (std.mem.startsWith(u8, image_id, "sha256:")) {
        return image_id;
    }

    // If it's just the hash, we can't reliably use it for registry comparison
    return null;
}

/// Compare two digests for equality
pub fn digestsEqual(digest1: []const u8, digest2: []const u8) bool {
    return std.mem.eql(u8, digest1, digest2);
}

/// Normalize a digest string (ensure it has sha256: prefix)
pub fn normalizeDigest(allocator: std.mem.Allocator, digest: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, digest, "sha256:")) {
        return try allocator.dupe(u8, digest);
    }

    return try std.fmt.allocPrint(allocator, "sha256:{s}", .{digest});
}

test "parseManifest with valid JSON" {
    const allocator = std.testing.allocator;

    const manifest_json =
        \\{
        \\  "schemaVersion": 2,
        \\  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
        \\  "config": {
        \\    "mediaType": "application/vnd.docker.container.image.v1+json",
        \\    "size": 7023,
        \\    "digest": "sha256:abc123"
        \\  },
        \\  "layers": [
        \\    {
        \\      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
        \\      "size": 977,
        \\      "digest": "sha256:layer1"
        \\    },
        \\    {
        \\      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
        \\      "size": 123,
        \\      "digest": "sha256:layer2"
        \\    }
        \\  ]
        \\}
    ;

    var manifest = try parseManifest(allocator, manifest_json);
    defer manifest.deinit();

    try std.testing.expectEqual(@as(i32, 2), manifest.schema_version);
    try std.testing.expectEqualStrings("application/vnd.docker.distribution.manifest.v2+json", manifest.media_type);
    try std.testing.expectEqual(@as(usize, 2), manifest.layers.items.len);
}

test "extractDigestFromImage" {
    const repo_digests = [_][]const u8{"nginx@sha256:abc123"};
    const digest = extractDigestFromImage("sha256:def456", &repo_digests);
    try std.testing.expect(digest != null);
    try std.testing.expectEqualStrings("sha256:abc123", digest.?);
}

test "normalizeDigest" {
    const allocator = std.testing.allocator;

    const normalized1 = try normalizeDigest(allocator, "sha256:abc123");
    defer allocator.free(normalized1);
    try std.testing.expectEqualStrings("sha256:abc123", normalized1);

    const normalized2 = try normalizeDigest(allocator, "abc123");
    defer allocator.free(normalized2);
    try std.testing.expectEqualStrings("sha256:abc123", normalized2);
}
