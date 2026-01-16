const std = @import("std");
const http = std.http;
const types = @import("types.zig");
const log = @import("../utils/log.zig");
const encoding = @import("../utils/encoding.zig");
const docker_config = @import("docker_config.zig");
const decompress_utils = @import("../utils/decompress.zig");

// Hardcoded registry list removed - now uses WWW-Authenticate discovery
// Only Docker Hub is handled as a special case in getRegistryToken()

/// Authentication endpoint information discovered from WWW-Authenticate header
pub const AuthEndpoint = struct {
    realm: []const u8, // Token endpoint URL
    service: []const u8, // Service name
    scope: ?[]const u8, // Optional scope
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AuthEndpoint) void {
        self.allocator.free(self.realm);
        self.allocator.free(self.service);
        if (self.scope) |s| {
            self.allocator.free(s);
        }
    }
};

/// Parse WWW-Authenticate header to extract token endpoint info
/// Format: Bearer realm="https://...",service="...",scope="..."
pub fn parseWWWAuthenticate(allocator: std.mem.Allocator, header_value: []const u8) !AuthEndpoint {
    log.debug("Parsing WWW-Authenticate header: {s}", .{header_value});

    // Check if it starts with "Bearer "
    if (!std.mem.startsWith(u8, header_value, "Bearer ")) {
        log.warn("WWW-Authenticate header doesn't start with 'Bearer '", .{});
        return error.InvalidAuthHeader;
    }

    const params_str = header_value["Bearer ".len..];

    var realm: ?[]const u8 = null;
    var service: ?[]const u8 = null;
    var scope: ?[]const u8 = null;

    // Parse comma-separated key="value" pairs
    var iter = std.mem.splitScalar(u8, params_str, ',');
    while (iter.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");

        // Split on '='
        const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

        // Remove quotes from value
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        if (std.mem.eql(u8, key, "realm")) {
            realm = value;
        } else if (std.mem.eql(u8, key, "service")) {
            service = value;
        } else if (std.mem.eql(u8, key, "scope")) {
            scope = value;
        }
    }

    // Realm and service are required
    const realm_val = realm orelse {
        log.warn("WWW-Authenticate header missing 'realm'", .{});
        return error.MissingRealm;
    };
    const service_val = service orelse {
        log.warn("WWW-Authenticate header missing 'service'", .{});
        return error.MissingService;
    };

    log.debug("Discovered auth endpoint - realm: {s}, service: {s}, scope: {?s}", .{ realm_val, service_val, scope });

    return AuthEndpoint{
        .realm = try allocator.dupe(u8, realm_val),
        .service = try allocator.dupe(u8, service_val),
        .scope = if (scope) |s| try allocator.dupe(u8, s) else null,
        .allocator = allocator,
    };
}

/// Authenticator handles Docker registry authentication
pub const Authenticator = struct {
    allocator: std.mem.Allocator,
    config: std.StringHashMap(types.AuthConfig),

    pub fn init(allocator: std.mem.Allocator) Authenticator {
        return .{
            .allocator = allocator,
            .config = std.StringHashMap(types.AuthConfig).init(allocator),
        };
    }

    pub fn deinit(self: *Authenticator) void {
        var iter = self.config.iterator();
        while (iter.next()) |entry| {
            var auth = entry.value_ptr.*;
            auth.deinit();
        }
        self.config.deinit();
    }

    /// Add authentication config for a registry
    pub fn addAuth(self: *Authenticator, registry: []const u8, username: []const u8, password: []const u8) !void {
        var auth = try types.AuthConfig.init(self.allocator, registry);
        auth.username = try self.allocator.dupe(u8, username);
        auth.password = try self.allocator.dupe(u8, password);

        // Create base64 encoded auth string
        auth.auth = try encoding.encodeBasicAuth(self.allocator, username, password);

        try self.config.put(registry, auth);
    }

    /// Get authentication config for a registry
    pub fn getAuth(self: *Authenticator, registry: []const u8) ?*types.AuthConfig {
        return self.config.getPtr(registry);
    }

    /// Load credentials from Docker config.json
    pub fn loadFromDockerConfig(self: *Authenticator) !void {
        var docker_cfg = try docker_config.loadDockerConfig(self.allocator);
        defer docker_cfg.deinit();

        var iter = docker_cfg.auths.iterator();
        while (iter.next()) |entry| {
            const registry = entry.key_ptr.*;
            const auth_entry = entry.value_ptr.*;

            // Decode the base64 auth string
            const decoded = docker_config.DockerConfig.decodeAuth(self.allocator, auth_entry.auth) catch |err| {
                log.warn("Failed to decode auth for {s}: {}", .{ registry, err });
                continue;
            };
            defer self.allocator.free(decoded.username);
            defer self.allocator.free(decoded.password);

            // Add to authenticator
            self.addAuth(registry, decoded.username, decoded.password) catch |err| {
                log.warn("Failed to add auth for {s}: {}", .{ registry, err });
                continue;
            };

            log.debug("Loaded credentials for {s}", .{registry});
        }
    }

    /// Get token for any supported registry
    /// Only handles Docker Hub special case - all other registries use auto-discovery
    pub fn getRegistryToken(
        self: *Authenticator,
        registry: []const u8,
        repository: []const u8,
    ) !?types.TokenResponse {
        const scope = try std.fmt.allocPrint(self.allocator, "repository:{s}:pull", .{repository});
        defer self.allocator.free(scope);

        // Special case: Docker Hub uses auth.docker.io instead of registry-1.docker.io
        // All other registries will use WWW-Authenticate discovery
        if (std.mem.eql(u8, registry, "docker.io")) {
            log.debug("Using hardcoded auth endpoint for Docker Hub", .{});
            return try self.fetchToken(registry, repository, "https://auth.docker.io/token", "registry.docker.io", scope);
        }

        // For all other registries: return null to trigger discovery in client
        log.debug("Registry {s} will use WWW-Authenticate discovery", .{registry});
        return null;
    }

    /// Fetch token using discovered auth endpoint
    pub fn fetchTokenFromEndpoint(
        self: *Authenticator,
        registry: []const u8,
        repository: []const u8,
        endpoint: *const AuthEndpoint,
    ) !types.TokenResponse {
        // Use the scope from the endpoint if provided, otherwise construct default scope
        const scope = endpoint.scope orelse try std.fmt.allocPrint(
            self.allocator,
            "repository:{s}:pull",
            .{repository},
        );
        defer if (endpoint.scope == null) self.allocator.free(scope);

        return try self.fetchToken(registry, repository, endpoint.realm, endpoint.service, scope);
    }

    /// Fetch token from a registry's token endpoint with custom scope
    fn fetchTokenWithScope(
        self: *Authenticator,
        registry: []const u8,
        token_endpoint: []const u8,
        service: []const u8,
        scope: []const u8,
    ) !types.TokenResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}?service={s}&scope={s}",
            .{ token_endpoint, service, scope },
        );
        defer self.allocator.free(url);

        log.debug("Fetching token from: {s}", .{url});

        // Check for stored credentials
        var auth_header: ?[]const u8 = null;
        defer if (auth_header) |ah| self.allocator.free(ah);

        if (self.getAuth(registry)) |auth| {
            if (auth.username) |username| {
                if (auth.password) |password| {
                    auth_header = try encoding.createBasicAuthHeader(self.allocator, username, password);
                }
            }
        }

        const body = self.httpGetWithAuth(url, auth_header) catch |err| {
            log.warn("HTTP request failed for {s}: {}", .{ url, err });
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return parseTokenResponse(self.allocator, body) catch |err| {
            log.err("Failed to parse token response from {s}: {}", .{ url, err });
            return error.InvalidTokenResponse;
        };
    }

    /// Fetch token from a registry's token endpoint
    fn fetchToken(
        self: *Authenticator,
        registry: []const u8,
        _: []const u8, // repository - unused but kept for compatibility
        token_endpoint: []const u8,
        service: []const u8,
        scope: []const u8,
    ) !types.TokenResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}?service={s}&scope={s}",
            .{ token_endpoint, service, scope },
        );
        defer self.allocator.free(url);

        log.debug("Fetching token from: {s}", .{url});

        // Check for stored credentials
        var auth_header: ?[]const u8 = null;
        defer if (auth_header) |ah| self.allocator.free(ah);

        if (self.getAuth(registry)) |auth| {
            if (auth.username) |username| {
                if (auth.password) |password| {
                    auth_header = try encoding.createBasicAuthHeader(self.allocator, username, password);
                }
            }
        }

        const body = self.httpGetWithAuth(url, auth_header) catch |err| {
            log.warn("HTTP request failed for {s}: {}", .{ url, err });
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return parseTokenResponse(self.allocator, body) catch |err| {
            log.err("Failed to parse token response from {s}: {}", .{ url, err });
            return error.InvalidTokenResponse;
        };
    }

    /// Get Docker Hub token for accessing a repository
    /// This implements the Docker Registry V2 token authentication flow
    pub fn getDockerHubToken(
        self: *Authenticator,
        repository: []const u8,
    ) !types.TokenResponse {
        const auth = self.getAuth("docker.io") orelse {
            // Anonymous access
            return try self.getAnonymousToken(repository);
        };

        return try self.getAuthenticatedToken(repository, auth);
    }

    /// Helper to perform HTTP GET and return body
    fn httpGetWithAuth(
        self: *Authenticator,
        url: []const u8,
        auth_header: ?[]const u8,
    ) ![]u8 {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);

        // Build extra headers array
        var extra_headers_buf: [1]http.Header = undefined;
        var extra_headers: []const http.Header = &.{};

        if (auth_header) |ah| {
            extra_headers_buf[0] = .{ .name = "Authorization", .value = ah };
            extra_headers = extra_headers_buf[0..1];
        }

        var req = try client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Check Content-Encoding header for compression BEFORE reading body
        // (reading body may invalidate response.head)
        var content_encoding: ?[]const u8 = null;
        var content_encoding_buf: [64]u8 = undefined;
        var header_iter = response.head.iterateHeaders();
        while (header_iter.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-encoding")) {
                // Copy the value to local buffer since response.head may be invalidated
                const len = @min(hdr.value.len, content_encoding_buf.len);
                @memcpy(content_encoding_buf[0..len], hdr.value[0..len]);
                content_encoding = content_encoding_buf[0..len];
                log.debug("Response has Content-Encoding: {s}", .{content_encoding.?});
                break;
            }
        }

        // Read body using Reader.allocRemaining (for both success and error cases)
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        const body = reader.allocRemaining(self.allocator, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };

        // Decompress if needed
        const final_body = if (content_encoding) |enc| blk: {
            const is_gzip = std.mem.indexOf(u8, enc, "gzip") != null;

            if (is_gzip) {
                log.debug("Decompressing gzip response ({d} bytes compressed)", .{body.len});

                const decompressed = decompress_utils.decompressGzip(self.allocator, body) catch |err| {
                    log.err("Failed to decompress gzip response: {}", .{err});
                    log.debug("Compressed data (first 100 bytes): {x}", .{body[0..@min(body.len, 100)]});
                    self.allocator.free(body);
                    return error.DecompressionFailed;
                };

                log.debug("Decompressed to {d} bytes", .{decompressed.len});
                self.allocator.free(body); // Free compressed body
                break :blk decompressed;
            } else {
                log.debug("Unsupported Content-Encoding: {s}, using as-is", .{enc});
                break :blk body;
            }
        } else body;

        // Check status after decompression (using final_body)
        if (response.head.status != .ok) {
            // Log error details
            const status_code = @intFromEnum(response.head.status);
            log.warn("HTTP {d} from {s}", .{ status_code, url });

            // Log first 500 chars of response body for debugging
            const preview_len = @min(final_body.len, 500);
            log.debug("Response body (first 500 chars): {s}{s}", .{
                final_body[0..preview_len],
                if (final_body.len > 500) "..." else "",
            });

            // Free body before returning error
            self.allocator.free(final_body);
            return error.HttpRequestFailed;
        }

        return final_body;
    }

    /// Get token for authenticated Docker Hub access
    fn getAuthenticatedToken(
        self: *Authenticator,
        repository: []const u8,
        auth_config: *types.AuthConfig,
    ) !types.TokenResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{s}:pull",
            .{repository},
        );
        defer self.allocator.free(url);

        // Build basic auth header
        var auth_header: ?[]const u8 = null;
        defer if (auth_header) |ah| self.allocator.free(ah);

        if (auth_config.username) |username| {
            if (auth_config.password) |password| {
                auth_header = try encoding.createBasicAuthHeader(self.allocator, username, password);
            }
        }

        const body = self.httpGetWithAuth(url, auth_header) catch |err| {
            log.warn("HTTP request failed for {s}: {}", .{ url, err });
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return parseTokenResponse(self.allocator, body) catch |err| {
            log.err("Failed to parse token response from {s}: {}", .{ url, err });
            return error.InvalidTokenResponse;
        };
    }

    /// Get anonymous token for Docker Hub
    fn getAnonymousToken(self: *Authenticator, repository: []const u8) !types.TokenResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{s}:pull",
            .{repository},
        );
        defer self.allocator.free(url);

        const body = self.httpGetWithAuth(url, null) catch |err| {
            log.warn("HTTP request failed for {s}: {}", .{ url, err });
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return parseTokenResponse(self.allocator, body) catch |err| {
            log.err("Failed to parse token response from {s}: {}", .{ url, err });
            return error.InvalidTokenResponse;
        };
    }

    /// Get token for private registry (if it uses token auth)
    pub fn getPrivateRegistryToken(
        self: *Authenticator,
        registry: []const u8,
        repository: []const u8,
        auth_endpoint: []const u8,
        service: []const u8,
    ) !types.TokenResponse {
        const auth = self.getAuth(registry);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}?service={s}&scope=repository:{s}:pull",
            .{ auth_endpoint, service, repository },
        );
        defer self.allocator.free(url);

        // Build basic auth header if available
        var auth_header: ?[]const u8 = null;
        defer if (auth_header) |ah| self.allocator.free(ah);

        if (auth) |a| {
            if (a.username) |username| {
                if (a.password) |password| {
                    auth_header = try encoding.createBasicAuthHeader(self.allocator, username, password);
                }
            }
        }

        const body = self.httpGetWithAuth(url, auth_header) catch |err| {
            log.warn("HTTP request failed for {s}: {}", .{ url, err });
            return error.AuthenticationFailed;
        };
        defer self.allocator.free(body);

        return parseTokenResponse(self.allocator, body) catch |err| {
            log.err("Failed to parse token response from {s}: {}", .{ url, err });
            return error.InvalidTokenResponse;
        };
    }
};

/// Parse JSON token response from registry
fn parseTokenResponse(allocator: std.mem.Allocator, json_data: []const u8) !types.TokenResponse {
    // Log first 500 chars for debugging
    const preview_len = @min(json_data.len, 500);
    log.debug("Parsing token response ({d} bytes): {s}{s}", .{
        json_data.len,
        json_data[0..preview_len],
        if (json_data.len > 500) "..." else "",
    });

    // Parse JSON with error handling
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch |err| {
        log.err("JSON parse failed: {}", .{err});
        log.err("Invalid JSON (first 500 chars): {s}", .{json_data[0..preview_len]});
        return error.InvalidTokenResponse;
    };
    defer parsed.deinit();

    // Safely get object root
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            log.err("Expected JSON object, got: {s}", .{@tagName(parsed.value)});
            log.err("JSON content (first 500 chars): {s}", .{json_data[0..preview_len]});
            return error.InvalidTokenResponse;
        },
    };

    // Get token field with type checking
    const token_value = root.get("token") orelse root.get("access_token") orelse {
        log.err("No 'token' or 'access_token' field found in response", .{});
        return error.InvalidTokenResponse;
    };

    const token_str = switch (token_value) {
        .string => |s| s,
        else => {
            log.err("Token field is not a string, got: {s}", .{@tagName(token_value)});
            return error.InvalidTokenResponse;
        },
    };

    // Build response with safe field access
    var response = types.TokenResponse{
        .token = try allocator.dupe(u8, token_str),
        .access_token = null,
        .expires_in = null,
        .issued_at = null,
        .allocator = allocator,
    };

    // Safely handle optional fields
    if (root.get("access_token")) |at| {
        if (at == .string) {
            response.access_token = try allocator.dupe(u8, at.string);
        }
    }

    if (root.get("expires_in")) |exp| {
        if (exp == .integer) {
            response.expires_in = exp.integer;
        }
    }

    if (root.get("issued_at")) |issued| {
        if (issued == .string) {
            response.issued_at = try allocator.dupe(u8, issued.string);
        }
    }

    log.debug("Successfully parsed token response", .{});
    return response;
}

test "ImageRef parsing - simple image" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "nginx");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("library", ref.namespace);
    try std.testing.expectEqualStrings("nginx", ref.repository);
    try std.testing.expectEqualStrings("latest", ref.tag);
}

test "ImageRef parsing - with tag" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "nginx:1.21");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("library", ref.namespace);
    try std.testing.expectEqualStrings("nginx", ref.repository);
    try std.testing.expectEqualStrings("1.21", ref.tag);
}

test "ImageRef parsing - with namespace" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "myuser/myapp:v1.0");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("myuser", ref.namespace);
    try std.testing.expectEqualStrings("myapp", ref.repository);
    try std.testing.expectEqualStrings("v1.0", ref.tag);
}

test "ImageRef parsing - with registry" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "ghcr.io/owner/repo:latest");
    defer ref.deinit();

    try std.testing.expectEqualStrings("ghcr.io", ref.registry);
    try std.testing.expectEqualStrings("owner", ref.namespace);
    try std.testing.expectEqualStrings("repo", ref.repository);
    try std.testing.expectEqualStrings("latest", ref.tag);
}

test "ImageRef parsing - with digest" {
    const allocator = std.testing.allocator;
    var ref = try types.ImageRef.parse(allocator, "nginx@sha256:abc123");
    defer ref.deinit();

    try std.testing.expectEqualStrings("docker.io", ref.registry);
    try std.testing.expectEqualStrings("library", ref.namespace);
    try std.testing.expectEqualStrings("nginx", ref.repository);
    try std.testing.expect(ref.digest != null);
    try std.testing.expectEqualStrings("sha256:abc123", ref.digest.?);
}
