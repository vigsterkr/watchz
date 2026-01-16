# Registry Module

The registry module provides functionality for interacting with Docker registries (Docker Hub, private registries, etc.) to check for image updates.

## Components

### `types.zig`
Core data structures for registry operations:
- **ImageRef**: Parsed image reference (registry, namespace, repository, tag, digest)
- **AuthConfig**: Registry authentication credentials
- **TokenResponse**: OAuth2 token response from registries
- **Manifest**: Docker Registry V2 manifest structure
- **UpdateCheckResult**: Result of checking for image updates

### `auth.zig`
Authentication handling:
- **Authenticator**: Manages authentication for multiple registries
- Docker Hub token authentication (anonymous and authenticated)
- Private registry authentication (basic auth, bearer tokens)
- Automatic token fetching and caching

### `client.zig`
HTTP client for registry operations:
- **RegistryClient**: Main client for interacting with registries
- Fetch manifest digests (HEAD requests for efficiency)
- Fetch full manifests (GET requests)
- Check for image updates
- Support for parallel update checking

### `manifest.zig`
Manifest parsing and manipulation:
- Parse Docker Registry V2 manifests from JSON
- Extract digests from manifests
- Parse manifest configs and layers
- Utility functions for digest extraction and normalization

### `digest.zig`
Content digest operations:
- **Digest**: Structured representation of content digests
- Parse and validate digest strings (sha256:..., sha512:...)
- Compare digests for equality
- Calculate SHA256 digests
- Short digest formatting for display

## Usage Examples

### Basic Image Reference Parsing

```zig
const types = @import("registry/types.zig");

// Parse various image formats
var ref1 = try types.ImageRef.parse(allocator, "nginx");
// -> docker.io/library/nginx:latest

var ref2 = try types.ImageRef.parse(allocator, "myuser/myapp:v1.0");
// -> docker.io/myuser/myapp:v1.0

var ref3 = try types.ImageRef.parse(allocator, "ghcr.io/owner/repo:latest");
// -> ghcr.io/owner/repo:latest

var ref4 = try types.ImageRef.parse(allocator, "nginx@sha256:abc123...");
// -> docker.io/library/nginx (with digest)
```

### Checking for Image Updates

```zig
const registry = @import("registry/client.zig");

// Create client
var client = registry.RegistryClient.init(allocator);
defer client.deinit();

// Add authentication for private registry (optional)
try client.addAuth("ghcr.io", "username", "token");

// Check for updates
var result = try client.checkForUpdate(
    "sha256:current_digest...",
    "nginx:latest"
);
defer result.deinit();

if (result.has_update) {
    std.debug.print("Update available!\n", .{});
    std.debug.print("New digest: {s}\n", .{result.latest_digest});
}
```

### Fetching Manifests

```zig
// Parse image reference
var image_ref = try types.ImageRef.parse(allocator, "nginx:latest");
defer image_ref.deinit();

// Get manifest digest (fast HEAD request)
const digest = try client.getManifestDigest(&image_ref);
defer allocator.free(digest);

// Or get full manifest (slower GET request)
const manifest_json = try client.getManifest(&image_ref);
defer allocator.free(manifest_json);

// Parse manifest
var manifest = try parseManifest(allocator, manifest_json);
defer manifest.deinit();
```

### Parallel Update Checking

```zig
const requests = [_]registry.ImageCheckRequest{
    .{ .image_name = "nginx:latest", .current_digest = "sha256:abc..." },
    .{ .image_name = "redis:alpine", .current_digest = "sha256:def..." },
    .{ .image_name = "postgres:15", .current_digest = "sha256:ghi..." },
};

const results = try client.checkForUpdatesParallel(&requests);
defer allocator.free(results);

for (results) |result| {
    defer result.deinit();
    if (result.has_update) {
        std.debug.print("Update available!\n", .{});
    }
}
```

## Supported Registries

### Docker Hub
- **Public images**: No authentication required for pulls
- **Private images**: Use Docker Hub credentials
- **Authentication**: Automatic OAuth2 token fetching
- **URL**: `registry-1.docker.io`

### GitHub Container Registry (GHCR)
- **URL**: `ghcr.io`
- **Authentication**: Personal access token (PAT)
```zig
try client.addAuth("ghcr.io", "username", "ghp_token...");
```

### Private/Self-hosted Registries
- **URL**: Your registry URL (e.g., `registry.example.com:5000`)
- **Authentication**: Basic auth or bearer token
```zig
try client.addAuth("registry.example.com:5000", "admin", "password");
```

## Authentication Methods

### Anonymous Access (Docker Hub public images)
No configuration needed - just use the client.

### Basic Authentication
```zig
try client.addAuth("registry.example.com", "username", "password");
```

### Bearer Token Authentication (Docker Hub)
Automatic - the client will fetch OAuth2 tokens as needed:
```zig
try client.addAuth("docker.io", "username", "password");
// Token is automatically fetched when needed
```

## Performance Considerations

### HEAD vs GET Requests
- **HEAD**: Fast, only fetches digest from headers (~100ms)
- **GET**: Slower, fetches entire manifest (~200-500ms)
- Use HEAD (via `getManifestDigest`) for update checking
- Use GET (via `getManifest`) only when you need manifest details

### Parallel Checking
For multiple containers, use `checkForUpdatesParallel` to:
- Check multiple images concurrently
- Reduce total check time by ~70% with 10+ containers
- Currently sequential (TODO: thread pool implementation)

## Error Handling

Common errors:
- `error.InvalidImageReference`: Malformed image name
- `error.AuthenticationFailed`: Invalid credentials or token fetch failed
- `error.ManifestFetchFailed`: Registry returned non-200 status
- `error.DigestNotFound`: No digest header in response
- `error.InvalidManifest`: Malformed manifest JSON

## Testing

Run tests:
```bash
zig build test
```

Test specific module:
```bash
zig test src/registry/types.zig
zig test src/registry/auth.zig
zig test src/registry/digest.zig
```

## Roadmap

- [ ] Implement parallel checking with thread pool
- [ ] Add manifest caching to reduce registry requests
- [ ] Support for OCI image format
- [ ] Rate limiting and retry logic
- [ ] Support for image signing verification
- [ ] Docker config.json credential helper support
