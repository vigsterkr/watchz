# WatchZ - Docker Container Updater in Zig

A lightweight, high-performance Zig implementation of [Watchtower](https://github.com/containrrr/watchtower) - automated Docker container base image updates.

**Binary Size**: ~1.7MB (vs Watchtower's ~15-20MB)  
**Memory Usage**: Minimal (no garbage collection overhead)  
**Startup Time**: Near-instant

---

## Features

### Core Functionality
- ✅ **Automatic Container Updates** - Monitor and update Docker containers when new images are available
- ✅ **Multi-Registry Support** - Docker Hub, GHCR, private registries
- ✅ **Label-Based Filtering** - Control which containers to update via labels
- ✅ **Name-Based Filtering** - Watch specific containers by name
- ✅ **Monitor-Only Mode** - Check for updates without applying them
- ✅ **Scope Support** - Run multiple WatchZ instances with different scopes
- ✅ **Secure Authentication** - Support for private registries and Docker Hub credentials
- ✅ **Notifications** - Slack, Email, Webhook, and Shoutrrr URL format support

### Registry Support
- **Docker Hub** - Public and private images with OAuth2 token authentication
- **GitHub Container Registry (GHCR)** - Personal access token authentication
- **Private Registries** - Basic auth and bearer token support
- **Efficient Checking** - Uses HEAD requests to check digests without downloading images

### Container Selection
Compatible with Watchtower labels:
- `com.centurylinklabs.watchtower.enable` - Enable/disable updates
- `com.centurylinklabs.watchtower.monitor-only` - Monitor without updating
- `com.centurylinklabs.watchtower.scope` - Scope filtering
- `ing.wik.watchz.enable` - WatchZ-specific enable label

---

## Installation

### Using Docker (Recommended)

```bash
docker run -d \
  --name watchz \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/vigsterkr/watchz:latest
```

With options:
```bash
docker run -d \
  --name watchz \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e WATCHZ_POLL_INTERVAL=300 \
  -e WATCHZ_CLEANUP=true \
  -e WATCHZ_LABEL_ENABLE=true \
  ghcr.io/vigsterkr/watchz:latest
```

### Standalone Binary

Download from [GitHub Releases](https://github.com/vigsterkr/watchz/releases):

```bash
# Linux (amd64)
wget https://github.com/vigsterkr/watchz/releases/latest/download/watchz-linux-amd64
chmod +x watchz-linux-amd64
./watchz-linux-amd64

# Linux (arm64)
wget https://github.com/vigsterkr/watchz/releases/latest/download/watchz-linux-arm64
chmod +x watchz-linux-arm64
./watchz-linux-arm64
```

### Building from Source

Requires [Zig 0.15.2+](https://ziglang.org/download/):

```bash
# Clone repository
git clone https://github.com/vigsterkr/watchz.git
cd watchz

# Build (debug)
zig build

# Build (optimized)
zig build -Doptimize=ReleaseSafe

# Run
./zig-out/bin/watchz --help
```

---

## Quick Start

### Run with Docker

```bash
# Basic usage - check daily
docker run -d \
  --name watchz \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/vigsterkr/watchz:latest

# Check every 5 minutes with cleanup
docker run -d \
  --name watchz \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e WATCHZ_POLL_INTERVAL=300 \
  -e WATCHZ_CLEANUP=true \
  ghcr.io/vigsterkr/watchz:latest
```

---

## Usage

### Basic Usage

```bash
# Run once and check for updates
watchz --run-once

# Run continuously with 5-minute interval
watchz --interval 300

# Enable debug logging
watchz --debug

# Monitor only (don't update)
watchz --monitor-only

# Clean up old images after updates
watchz --cleanup
```

### Container Filtering

```bash
# Only update containers with enable label
watchz --label-enable

# Update specific containers by name
watchz container1 container2 container3

# Use scope filtering
watchz --scope production
```

### Docker Host Configuration

```bash
# Use custom Docker socket
watchz -H unix:///path/to/docker.sock

# Connect to remote Docker daemon
watchz -H tcp://192.168.1.100:2375

# Use Docker context
export DOCKER_HOST=unix:///var/run/docker.sock
watchz
```

### Private Registry Authentication

```bash
# Set via environment variables
export DOCKER_USERNAME=myuser
export DOCKER_PASSWORD=mytoken
watchz

# For GitHub Container Registry (GHCR)
export DOCKER_USERNAME=github-username
export DOCKER_PASSWORD=ghp_your_personal_access_token
watchz
```

---

## Configuration

### Command-Line Options

```
USAGE: watchz [OPTIONS] [CONTAINER_NAMES...]

OPTIONS:
  -h, --help                    Show help message
  -i, --interval <SECONDS>      Poll interval (default: 86400)
  -R, --run-once                Run once and exit
  -d, --debug                   Enable debug logging
  --trace                       Enable trace logging
  -c, --cleanup                 Remove old images after update
  -S, --include-stopped         Include stopped containers
  --label-enable                Only update containers with enable label
  --monitor-only                Check without updating
  --scope <SCOPE>               Filter by scope label
  
DOCKER OPTIONS:
  -H, --host <HOST>             Docker host (default: unix:///var/run/docker.sock)

NOTIFICATION OPTIONS:
  --notification-url <URL>      Notification URL (can be repeated)
  --notification-level <LEVEL>  Minimum notification level (info/warn/error)
  --notification-report         Send session report
```

### Environment Variables

All options can be set via environment variables with `WATCHZ_` prefix:

```bash
WATCHZ_POLL_INTERVAL=300       # Check every 5 minutes
WATCHZ_CLEANUP=true            # Remove old images
WATCHZ_DEBUG=true              # Enable debug logging
WATCHZ_LABEL_ENABLE=true       # Only watch labeled containers
WATCHZ_MONITOR_ONLY=true       # Monitor mode
WATCHZ_SCOPE=production        # Scope filter
DOCKER_HOST=unix:///var/run/docker.sock

# Notifications
WATCHZ_NOTIFICATION_URL="slack://token@channel"
WATCHZ_NOTIFICATION_LEVEL=info
WATCHZ_NOTIFICATION_REPORT=true
```

### Container Labels

Add labels to your containers to control WatchZ behavior:

```yaml
# docker-compose.yml
services:
  webapp:
    image: myapp:latest
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
      - "com.centurylinklabs.watchtower.scope=production"
  
  database:
    image: postgres:15
    labels:
      - "com.centurylinklabs.watchtower.enable=false"  # Don't update
```

See [LABELS.md](LABELS.md) for complete label documentation.

---

## Notifications

WatchZ supports multiple notification backends to alert you when containers are updated.

### Configuration

Notifications are configured via the `--notification-url` flag or `WATCHZ_NOTIFICATION_URL` environment variable. You can specify multiple notification URLs.

```bash
# Slack
watchz --notification-url "slack://token@channel"

# Email (SMTP)
watchz --notification-url "smtp://user:password@smtp.gmail.com:587/?from=watchz@example.com&to=admin@example.com"

# Webhook
watchz --notification-url "webhook://https://example.com/webhook"

# Multiple notifications
export WATCHZ_NOTIFICATION_URL="slack://token@channel,smtp://user:pass@smtp.gmail.com:587/?from=watchz@example.com&to=admin@example.com"
watchz
```

### Notification Levels

Control which events trigger notifications:

```bash
# Only errors
watchz --notification-level error

# Warnings and errors
watchz --notification-level warn

# All events (default)
watchz --notification-level info
```

### Session Reports

Enable detailed session reports with `--notification-report`:

```bash
watchz --notification-report --notification-url "slack://token@channel"
```

### Shoutrrr URL Format

WatchZ supports the [Shoutrrr](https://containrrr.dev/shoutrrr/) URL format for compatibility with Watchtower:

```bash
# Discord
watchz --notification-url "discord://token@id"

# Slack
watchz --notification-url "slack://token@channel"

# Email
watchz --notification-url "smtp://user:password@host:port/?from=x&to=y"

# Generic webhook
watchz --notification-url "generic://host:port/path"
```

---

## How It Works

WatchZ monitors your Docker containers and automatically updates them when new images are available.

### Update Process

1. **Discovery** - List running containers via Docker API
2. **Filtering** - Apply name/label/scope filters
3. **Registry Check** - Fetch image manifest digests from registries
4. **Comparison** - Compare current digest with latest digest
5. **Update** - If different, pull new image and recreate container
6. **Cleanup** - Optionally remove old images
7. **Notify** - Send notifications on success or failure

### Registry Communication

WatchZ uses efficient HEAD requests to check for image updates without downloading entire manifests:

```
HEAD /v2/library/nginx/manifests/latest
Docker-Content-Digest: sha256:abc123...

Current: sha256:def456...
Latest:  sha256:abc123...
→ Update available!
```

---

## Why WatchZ?

WatchZ is designed to be a **drop-in replacement** for Watchtower with better performance characteristics:

### Key Advantages

- **10x Smaller**: 1.7MB vs 15-20MB binary size
- **Lower Memory**: No garbage collection overhead
- **Faster Startup**: Near-instant initialization
- **Full Compatibility**: Uses same labels and environment variables as Watchtower

### When to Use WatchZ

- ✅ Resource-constrained environments (Raspberry Pi, edge devices)
- ✅ Large-scale deployments (lower per-instance overhead)
- ✅ Systems with many WatchZ instances running
- ✅ When you want minimal dependencies

### When to Use Watchtower

- 🤔 You need HTTP API triggers (WatchZ planned)
- 🤔 You need cron scheduling (WatchZ planned)
- 🤔 You prefer Go ecosystem

---

## Comparison with Watchtower

| Feature | Watchtower (Go) | WatchZ (Zig) |
|---------|----------------|--------------|
| Binary Size | ~15-20MB | ~1.7MB |
| Memory Usage | Higher (GC) | Lower (manual) |
| Startup Time | Fast | Near-instant |
| CPU Usage | Moderate | Minimal |
| Dependencies | Go runtime + libs | Zig stdlib only |
| Container Updates | ✅ | ✅ |
| Label Filtering | ✅ | ✅ |
| Private Registries | ✅ | ✅ |
| Notifications | ✅ | ✅ |
| Rolling Restarts | ✅ | ✅ |
| HTTP API | ✅ | 🚧 Planned |
| Cron Scheduling | ✅ | 🚧 Planned |

---

## Current Status

WatchZ is in **active development** with most core features complete.

### ✅ Fully Implemented

- Docker API integration (Unix socket)
- Container discovery and filtering
- Registry authentication (Docker Hub, GHCR, private registries)
- Image digest comparison
- Automatic container updates with rollback
- Label-based filtering (Watchtower compatible)
- Name and scope filtering
- Monitor-only mode
- Notifications (Slack, Email, Webhook, Shoutrrr)
- Rolling restarts
- Image cleanup

### 🚧 Planned Features

- HTTP API for triggering updates
- Prometheus metrics endpoint
- Cron scheduling (6-field expressions)
- Lifecycle hooks (pre/post update scripts)
- TCP Docker daemon connections
- Linked container support

---

## Contributing

Contributions are welcome!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes and test them
4. Commit changes (`git commit -m 'Add amazing feature'`)
5. Push to branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

---

## Troubleshooting

### Cannot connect to Docker daemon
```bash
# Check Docker is running
docker ps

# Check socket permissions
ls -l /var/run/docker.sock

# Add user to docker group (Linux)
sudo usermod -aG docker $USER
```

### Registry authentication failed
```bash
# Test credentials manually
echo $DOCKER_PASSWORD | docker login -u $DOCKER_USERNAME --password-stdin

# Check Docker config
cat ~/.docker/config.json
```

### Container not updating
```bash
# Check labels
docker inspect container_name | grep -A5 Labels

# Run with debug logging
watchz --debug --run-once

# Test specific container
watchz --debug container_name
```

---

## FAQ

**Q: Is WatchZ compatible with Watchtower?**  
A: Yes! WatchZ uses the same labels and configuration options as Watchtower. You can swap them directly.

**Q: Can I use WatchZ with Docker Swarm/Kubernetes?**  
A: Currently, WatchZ only supports standalone Docker. Swarm/K8s support is planned for future releases.

**Q: How often should I check for updates?**  
A: The default is 24 hours. For production, we recommend 1-6 hours depending on your update urgency and registry rate limits.

**Q: Does WatchZ support Docker Compose?**  
A: Yes, WatchZ works with containers started via Docker Compose. Use labels to control update behavior.

**Q: What happens if an update fails?**  
A: WatchZ will attempt to rollback to the previous container state and log the error. The old container remains running if rollback succeeds.

**Q: Can I test updates without actually applying them?**  
A: Yes! Use `--monitor-only` mode to check for updates without making any changes.

**Q: How do I exclude certain containers from updates?**  
A: Set the label `com.centurylinklabs.watchtower.enable=false` on containers you want to exclude.

---

## License

Apache-2.0 (same as original Watchtower)

---

## Acknowledgments

- [Watchtower](https://github.com/containrrr/watchtower) - The original project that inspired WatchZ
- [Zig Programming Language](https://ziglang.org/) - For enabling high-performance systems programming
- Docker community for excellent API documentation

---

## Links

- **Issues**: [GitHub Issues](https://github.com/vigsterkr/watchz/issues)
- **Discussions**: [GitHub Discussions](https://github.com/vigsterkr/watchz/discussions)
- **Releases**: [GitHub Releases](https://github.com/vigsterkr/watchz/releases)
- **Container Registry**: [GitHub Container Registry](https://github.com/vigsterkr/watchz/pkgs/container/watchz)
- **Original Watchtower**: https://github.com/containrrr/watchtower
