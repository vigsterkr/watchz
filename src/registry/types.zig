const std = @import("std");

/// Registry authentication credentials
pub const AuthConfig = struct {
    username: ?[]const u8,
    password: ?[]const u8,
    auth: ?[]const u8, // Base64 encoded username:password
    server_address: []const u8,
    identity_token: ?[]const u8,
    registry_token: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, server: []const u8) !AuthConfig {
        return .{
            .username = null,
            .password = null,
            .auth = null,
            .server_address = try allocator.dupe(u8, server),
            .identity_token = null,
            .registry_token = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AuthConfig) void {
        if (self.username) |u| self.allocator.free(u);
        if (self.password) |p| self.allocator.free(p);
        if (self.auth) |a| self.allocator.free(a);
        self.allocator.free(self.server_address);
        if (self.identity_token) |t| self.allocator.free(t);
        if (self.registry_token) |t| self.allocator.free(t);
    }
};

/// Docker Registry V2 Token Response
pub const TokenResponse = struct {
    token: []const u8,
    access_token: ?[]const u8,
    expires_in: ?i64,
    issued_at: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *TokenResponse) void {
        self.allocator.free(self.token);
        if (self.access_token) |t| self.allocator.free(t);
        if (self.issued_at) |t| self.allocator.free(t);
    }
};

/// Image reference parsed from a Docker image string
pub const ImageRef = struct {
    registry: []const u8,
    namespace: []const u8,
    repository: []const u8,
    tag: []const u8,
    digest: ?[]const u8,

    allocator: std.mem.Allocator,

    /// Parse a Docker image reference like:
    /// - "nginx:latest"
    /// - "ghcr.io/owner/repo:tag"
    /// - "registry.example.com:5000/namespace/repo:tag"
    /// - "library/nginx@sha256:abc123..."
    pub fn parse(allocator: std.mem.Allocator, image: []const u8) !ImageRef {
        var registry: []const u8 = "docker.io";
        var namespace: []const u8 = "library";
        var repository: []const u8 = "";
        var tag: []const u8 = "latest";
        var digest: ?[]const u8 = null;

        var remaining = image;

        // Check for digest (@sha256:...)
        if (std.mem.indexOf(u8, remaining, "@")) |at_idx| {
            digest = try allocator.dupe(u8, remaining[at_idx + 1 ..]);
            remaining = remaining[0..at_idx];
        }

        // Check for tag (:version)
        if (std.mem.lastIndexOf(u8, remaining, ":")) |colon_idx| {
            // Check if this is a port number (registry:5000) or a tag
            const after_colon = remaining[colon_idx + 1 ..];
            const is_port = for (after_colon) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;

            if (!is_port or std.mem.indexOf(u8, remaining[0..colon_idx], "/") == null) {
                tag = try allocator.dupe(u8, after_colon);
                remaining = remaining[0..colon_idx];
            }
        }

        // Split by slashes
        var parts: std.ArrayList([]const u8) = .{};
        defer parts.deinit(allocator);

        var iter = std.mem.splitScalar(u8, remaining, '/');
        while (iter.next()) |part| {
            try parts.append(allocator, part);
        }

        switch (parts.items.len) {
            0 => return error.InvalidImageReference,
            1 => {
                // Just "nginx" -> docker.io/library/nginx:latest
                repository = try allocator.dupe(u8, parts.items[0]);
            },
            2 => {
                // Could be "library/nginx" or "localhost:5000/repo"
                const first = parts.items[0];
                if (std.mem.indexOf(u8, first, ".") != null or
                    std.mem.indexOf(u8, first, ":") != null or
                    std.mem.eql(u8, first, "localhost"))
                {
                    // It's a registry
                    registry = try allocator.dupe(u8, first);
                    namespace = "";
                    repository = try allocator.dupe(u8, parts.items[1]);
                } else {
                    // It's namespace/repo
                    namespace = try allocator.dupe(u8, first);
                    repository = try allocator.dupe(u8, parts.items[1]);
                }
            },
            else => {
                // "registry.com/namespace/repo" or more
                registry = try allocator.dupe(u8, parts.items[0]);
                namespace = try allocator.dupe(u8, parts.items[1]);
                // Join remaining parts as repository
                var repo_parts: std.ArrayList(u8) = .{};
                defer repo_parts.deinit(allocator);
                for (parts.items[2..], 0..) |part, i| {
                    if (i > 0) try repo_parts.append(allocator, '/');
                    try repo_parts.appendSlice(allocator, part);
                }
                repository = try repo_parts.toOwnedSlice(allocator);
            },
        }

        // Allocate defaults if not already allocated
        if (registry.ptr == "docker.io".ptr) {
            registry = try allocator.dupe(u8, registry);
        }
        if (namespace.len > 0 and namespace.ptr == "library".ptr) {
            namespace = try allocator.dupe(u8, namespace);
        }
        if (tag.ptr == "latest".ptr) {
            tag = try allocator.dupe(u8, tag);
        }

        return .{
            .registry = registry,
            .namespace = namespace,
            .repository = repository,
            .tag = tag,
            .digest = digest,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ImageRef) void {
        self.allocator.free(self.registry);
        if (self.namespace.len > 0) self.allocator.free(self.namespace);
        self.allocator.free(self.repository);
        self.allocator.free(self.tag);
        if (self.digest) |d| self.allocator.free(d);
    }

    /// Get the full repository path (namespace/repository or just repository)
    pub fn getRepositoryPath(self: *const ImageRef, allocator: std.mem.Allocator) ![]const u8 {
        if (self.namespace.len == 0) {
            return try allocator.dupe(u8, self.repository);
        }
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.namespace, self.repository });
    }
};

/// Docker Registry V2 Manifest (simplified)
pub const Manifest = struct {
    schema_version: i32,
    media_type: []const u8,
    digest: []const u8,
    config: ManifestConfig,
    layers: std.ArrayList(ManifestLayer),

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.media_type);
        self.allocator.free(self.digest);
        self.config.deinit();
        for (self.layers.items) |*layer| {
            layer.deinit();
        }
        self.layers.deinit();
    }
};

pub const ManifestConfig = struct {
    media_type: []const u8,
    size: u64,
    digest: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ManifestConfig) void {
        self.allocator.free(self.media_type);
        self.allocator.free(self.digest);
    }
};

pub const ManifestLayer = struct {
    media_type: []const u8,
    size: u64,
    digest: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ManifestLayer) void {
        self.allocator.free(self.media_type);
        self.allocator.free(self.digest);
    }
};

/// Represents the result of checking for an image update
pub const UpdateCheckResult = struct {
    has_update: bool,
    current_digest: []const u8,
    latest_digest: []const u8,
    message: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *UpdateCheckResult) void {
        self.allocator.free(self.current_digest);
        self.allocator.free(self.latest_digest);
        if (self.message) |m| self.allocator.free(m);
    }
};
