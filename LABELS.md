# WatchZ Label Reference

WatchZ supports both **Watchtower-compatible labels** and **custom WatchZ labels** for maximum flexibility.

## Label Namespaces

### Watchtower Labels (Fully Compatible)
```
com.centurylinklabs.watchtower.*
```

### WatchZ Custom Labels
```
ing.wik.watchz.*
```

**Both work identically!** Use whichever you prefer, or mix both in the same deployment.

---

## Available Labels

### 1. Enable/Disable Monitoring

Control whether a container should be monitored for updates.

**Watchtower:**
```yaml
labels:
  - "com.centurylinklabs.watchtower.enable=true"   # Enable
  - "com.centurylinklabs.watchtower.enable=false"  # Disable
```

**WatchZ:**
```yaml
labels:
  - "ing.wik.watchz.enable=true"   # Enable
  - "ing.wik.watchz.enable=false"  # Disable
```

**Usage:**
- `enable=true`: Container will be monitored (when using `--label-enable` flag)
- `enable=false`: Container will NEVER be updated (explicit disable)
- No label: Container will be monitored by default (unless `--label-enable` is used)

---

### 2. Monitor-Only Mode

Check for updates but don't apply them.

**Watchtower:**
```yaml
labels:
  - "com.centurylinklabs.watchtower.monitor-only=true"
```

**WatchZ:**
```yaml
labels:
  - "ing.wik.watchz.monitor-only=true"
```

**Usage:**
- Container will be checked for updates
- Updates will be detected and logged
- No containers will be stopped/restarted
- Useful for testing before enabling full updates

---

### 3. Scope Filtering

Run multiple WatchZ instances with different scopes.

**Watchtower:**
```yaml
labels:
  - "com.centurylinklabs.watchtower.scope=production"
```

**WatchZ:**
```yaml
labels:
  - "ing.wik.watchz.scope=production"
```

**Usage:**
```bash
# Terminal 1: Production instance
watchz --scope production

# Terminal 2: Staging instance
watchz --scope staging

# Terminal 3: Development instance
watchz --scope dev
```

Only containers with matching scope labels will be monitored by each instance.

---

### 4. No-Pull

Disable image pulling for specific containers.

**Watchtower:**
```yaml
labels:
  - "com.centurylinklabs.watchtower.no-pull=true"
```

**WatchZ:**
```yaml
labels:
  - "ing.wik.watchz.no-pull=true"
```

**Usage:**
- WatchZ will check for updates
- Updates will be detected
- No new image will be pulled
- Useful for containers with pre-pulled images

---

### 5. Stop Signal

Custom signal for graceful container shutdown.

**Watchtower:**
```yaml
labels:
  - "com.centurylinklabs.watchtower.stop-signal=SIGUSR1"
```

**WatchZ:**
```yaml
labels:
  - "ing.wik.watchz.stop-signal=SIGUSR1"
```

**Common signals:**
- `SIGTERM` (default): Standard termination
- `SIGINT`: Interrupt (Ctrl+C)
- `SIGUSR1` / `SIGUSR2`: User-defined signals
- `SIGQUIT`: Quit with core dump
- `SIGHUP`: Hangup (reload config)

---

## CLI Flags

Labels work in conjunction with CLI flags:

### `--label-enable`
Only monitor containers with an enable label.

```bash
watchz --label-enable
```

**Behavior:**
- Containers with `enable=true` (either namespace): ✓ Monitored
- Containers without enable label: ✗ Ignored
- Containers with `enable=false`: ✗ Ignored

### `--scope <SCOPE>`
Filter by scope label.

```bash
watchz --scope production
```

**Behavior:**
- Only containers with matching scope label are monitored
- Containers without scope label are ignored
- Different WatchZ instances can monitor different scopes

### `--monitor-only`
Global monitor-only mode (overrides labels).

```bash
watchz --monitor-only
```

**Behavior:**
- All containers are in monitor-only mode
- Per-container monitor-only labels still work
- Use for dry-run/testing

### `--no-pull`
Global no-pull mode (overrides labels).

```bash
watchz --no-pull
```

**Behavior:**
- No images will be pulled for any container
- Per-container no-pull labels still work
- Updates will still be detected

---

## Examples

### Example 1: Basic Enable/Disable

```yaml
services:
  # This will be monitored
  web:
    image: nginx:latest
    labels:
      - "ing.wik.watchz.enable=true"
  
  # This will NEVER be updated
  database:
    image: postgres:14
    labels:
      - "ing.wik.watchz.enable=false"
```

```bash
watchz --label-enable
```

### Example 2: Multiple Scopes

```yaml
services:
  prod-web:
    image: myapp:latest
    labels:
      - "ing.wik.watchz.enable=true"
      - "ing.wik.watchz.scope=production"
  
  staging-web:
    image: myapp:latest
    labels:
      - "ing.wik.watchz.enable=true"
      - "ing.wik.watchz.scope=staging"
```

```bash
# Terminal 1: Production
watchz --scope production --label-enable

# Terminal 2: Staging
watchz --scope staging --label-enable
```

### Example 3: Monitor-Only Testing

```yaml
services:
  critical-app:
    image: critical:latest
    labels:
      - "ing.wik.watchz.enable=true"
      - "ing.wik.watchz.monitor-only=true"  # Safe testing
```

```bash
# Check for updates but don't apply them
watchz --label-enable --run-once
```

### Example 4: Custom Stop Signal

```yaml
services:
  app:
    image: myapp:latest
    labels:
      - "ing.wik.watchz.enable=true"
      - "ing.wik.watchz.stop-signal=SIGUSR1"  # Graceful shutdown
```

The app will receive SIGUSR1 when being stopped for updates.

### Example 5: Mixed Watchtower and WatchZ Labels

```yaml
services:
  # Using Watchtower labels
  app1:
    image: app1:latest
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
      - "com.centurylinklabs.watchtower.scope=production"
  
  # Using WatchZ labels
  app2:
    image: app2:latest
    labels:
      - "ing.wik.watchz.enable=true"
      - "ing.wik.watchz.scope=production"
  
  # Both work with the same WatchZ instance!
```

```bash
watchz --scope production --label-enable
# Both app1 and app2 will be monitored!
```

---

## Label Priority

When both Watchtower and WatchZ labels exist for the same setting:

1. ✅ Check Watchtower label first
2. ✅ If not found, check WatchZ label
3. ✅ Use whichever is found

**Example:**
```yaml
labels:
  - "com.centurylinklabs.watchtower.enable=false"
  - "ing.wik.watchz.enable=true"
```

Result: **Disabled** (Watchtower label takes precedence if both exist)

---

## Migration from Watchtower

### Option 1: No Changes Needed

Your existing Watchtower labels work as-is:

```yaml
# Existing docker-compose.yml - works immediately!
services:
  app:
    image: myapp:latest
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
```

Just replace Watchtower with WatchZ:
```bash
# Before:
docker run ... containrrr/watchtower

# After:
watchz
```

### Option 2: Gradually Adopt WatchZ Labels

Use both during transition:

```yaml
services:
  app:
    image: myapp:latest
    labels:
      # Keep old labels for Watchtower compatibility
      - "com.centurylinklabs.watchtower.enable=true"
      # Add new labels for WatchZ-specific features
      - "ing.wik.watchz.enable=true"
```

### Option 3: Full Migration

Replace all labels with WatchZ namespace:

```bash
# Before:
com.centurylinklabs.watchtower.enable=true

# After:
ing.wik.watchz.enable=true
```

---

## Best Practices

### 1. Use `--label-enable` for Production

Don't monitor all containers by default:

```bash
watchz --label-enable
```

Explicitly label containers you want to monitor:
```yaml
labels:
  - "ing.wik.watchz.enable=true"
```

### 2. Use Scopes for Multiple Environments

```yaml
# Production
labels:
  - "ing.wik.watchz.scope=production"

# Staging
labels:
  - "ing.wik.watchz.scope=staging"
```

Run separate instances:
```bash
watchz --scope production  # Production instance
watchz --scope staging     # Staging instance
```

### 3. Test with Monitor-Only First

Before enabling updates:

```yaml
labels:
  - "ing.wik.watchz.enable=true"
  - "ing.wik.watchz.monitor-only=true"  # Safe testing
```

```bash
watchz --label-enable --run-once
# Review logs, then remove monitor-only label
```

### 4. Disable Critical Containers

Never update certain containers:

```yaml
labels:
  - "ing.wik.watchz.enable=false"  # Explicit disable
```

### 5. Use Custom Stop Signals for Graceful Shutdown

If your app needs graceful shutdown:

```yaml
labels:
  - "ing.wik.watchz.stop-signal=SIGUSR1"
```

Then handle SIGUSR1 in your application to save state, close connections, etc.

---

## Quick Reference Table

| Label | Watchtower | WatchZ Custom | Default | Description |
|-------|-----------|---------------|---------|-------------|
| Enable | `com.centurylinklabs.watchtower.enable` | `ing.wik.watchz.enable` | `true` | Enable/disable monitoring |
| Monitor-only | `com.centurylinklabs.watchtower.monitor-only` | `ing.wik.watchz.monitor-only` | `false` | Check but don't update |
| Scope | `com.centurylinklabs.watchtower.scope` | `ing.wik.watchz.scope` | - | Scope filtering |
| No-pull | `com.centurylinklabs.watchtower.no-pull` | `ing.wik.watchz.no-pull` | `false` | Disable image pulling |
| Stop signal | `com.centurylinklabs.watchtower.stop-signal` | `ing.wik.watchz.stop-signal` | `SIGTERM` | Container stop signal |

---

## Troubleshooting

### Container not being monitored?

**Debug:**
```bash
watchz --debug --run-once
```

**Check:**
1. Is `--label-enable` used? Container needs enable label
2. Is `--scope` used? Container needs matching scope label
3. Does container have `enable=false`? This explicitly disables it
4. Check container name matches (if using name filter)

### Both labels present?

If both Watchtower and WatchZ labels exist, Watchtower label takes precedence.

### Label not working?

Make sure the label format is exact:
- ✅ `ing.wik.watchz.enable=true`
- ✗ `ing.wik.watchz.enable = true` (spaces)
- ✗ `ing.wik.watchz.enabled=true` (typo)

---

## Summary

✅ **Watchtower labels**: Fully compatible  
✅ **WatchZ labels**: New custom namespace (`ing.wik.watchz.*`)  
✅ **Both work**: Use whichever you prefer  
✅ **Migration**: Zero changes needed from Watchtower  
✅ **Flexibility**: Mix and match as needed  

WatchZ gives you the flexibility to use familiar Watchtower labels or adopt a new namespace specific to WatchZ!
