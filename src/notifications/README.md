# WatchZ Notification System

Phase 4 implementation of the WatchZ notification system, providing multiple notification backends for alerting when container updates occur.

## Features

- **Multiple Notification Backends**:
  - Generic Webhook (HTTP POST with JSON payload)
  - Email (SMTP)
  - Slack (via Incoming Webhooks)
  - Discord (via Webhooks)

- **Shoutrrr URL Format**: Compatible with Watchtower's notification URL format
- **Notification Levels**: Debug, Info, Warn, Error
- **Session Reports**: Comprehensive update session summaries
- **Thread-Safe**: Notification manager supports concurrent access

## Architecture

### Core Components

```
notifications/
├── notifier.zig       # Base notifier interface and manager
├── webhook.zig        # Generic webhook implementation
├── email.zig          # SMTP email notifications
├── slack.zig          # Slack & Discord webhooks
└── shoutrrr.zig       # Shoutrrr URL parser
```

### Session Tracking

```
session/
├── session.zig        # Session tracker and ID generator
└── report.zig         # Session report and container update types
```

## Usage Examples

### 1. Using NotificationManager

```zig
const std = @import("std");
const notifier = @import("notifications/notifier.zig");
const NotificationManager = notifier.NotificationManager;
const NotificationLevel = notifier.NotificationLevel;

var manager = NotificationManager.init(allocator, .info, true);
defer manager.deinit();

// Send a simple notification
manager.notifyText(.info, "Container Updated", "nginx was updated to latest version");
```

### 2. Using Shoutrrr URLs

```zig
const shoutrrr = @import("notifications/shoutrrr.zig");

var parser = shoutrrr.ShoutrrrParser.init(allocator);

// Parse and create notifier from Shoutrrr URL
const url = "slack://T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX@#updates";
var slack_notifier = try parser.parseAndCreate(url);
defer slack_notifier.deinit();

// Add to notification manager
try manager.addNotifier(slack_notifier);
```

### 3. Session Reporting

```zig
const SessionReport = @import("session/report.zig").SessionReport;
const ContainerUpdate = @import("session/report.zig").ContainerUpdate;

// Create a session report
var session = try SessionReport.init(allocator, "session-123");
defer session.deinit();

session.containers_scanned = 10;
session.containers_updated = 2;

// Add container updates
var update = try ContainerUpdate.init(
    allocator,
    "my-container",
    "abc123",
    "nginx:latest",
    .success,
);
try session.addUpdate(update);

session.complete();

// Send report via all configured notifiers
manager.notifyReport(&session);
```

### 4. Creating Custom Notifiers

```zig
const webhook = @import("notifications/webhook.zig");

// Create a custom webhook notifier
var my_webhook = try webhook.WebhookNotifier.init(
    allocator,
    "https://example.com/webhook",
);
defer my_webhook.deinit();

// Add custom headers
try my_webhook.addHeader("Authorization", "Bearer token123");
try my_webhook.addHeader("X-Custom-Header", "value");

// Convert to generic notifier and add to manager
try manager.addNotifier(my_webhook.asNotifier());
```

## Shoutrrr URL Formats

WatchZ supports the same notification URL formats as Watchtower for compatibility:

### Generic Webhook
```
webhook://example.com/path
generic://example.com:8080/webhook
```

### Slack
```
slack://token_a/token_b/token_c@channel
slack://token@channel?username=WatchZ&icon=:robot:
```

Format: `https://hooks.slack.com/services/{token_a}/{token_b}/{token_c}`

### Discord
```
discord://webhook_id@token
discord://webhook_id@token?username=WatchZ
```

Format: `https://discord.com/api/webhooks/{webhook_id}/{token}`

### Email (SMTP)
```
smtp://user:password@smtp.example.com:587/?from=sender@example.com&to=recipient@example.com
smtp://smtp.gmail.com:587/?from=watchz@example.com&to=admin@example.com&tls=true
```

Parameters:
- `from`: Sender email address (required)
- `to`: Recipient email address (required)
- `tls`: Use TLS (default: true)

## Configuration

Add notification URLs via command line or environment variables:

### Command Line
```bash
watchz --notification-url "slack://token@channel" \
       --notification-url "smtp://user:pass@smtp.example.com:587/?from=a@example.com&to=b@example.com" \
       --notification-level info \
       --notification-report
```

### Environment Variables
```bash
WATCHZ_NOTIFICATION_URL="slack://token@channel"
WATCHZ_NOTIFICATION_LEVEL="info"
WATCHZ_NOTIFICATION_REPORT="true"
```

## Notification Levels

Notifications are filtered by minimum level:

| Level | Priority | Usage |
|-------|----------|-------|
| debug | 0 | Verbose debugging information |
| info  | 1 | Normal operational messages |
| warn  | 2 | Warning conditions |
| error | 3 | Error conditions |

Set `notification_level` to control which notifications are sent. For example, setting it to `warn` will only send warn and error notifications.

## Session Report Format

Session reports include:

- **Session ID**: Unique identifier
- **Status**: completed, partial_failure, failed, running
- **Duration**: Time taken in seconds
- **Summary**:
  - Containers scanned
  - Updates available
  - Successfully updated
  - Failed updates
- **Container Updates**: Individual container details with:
  - Container name and ID
  - Image name
  - Old and new digests
  - Update status
  - Error messages (if failed)

Example formatted report:

```
WatchZ Update Session Report
===========================

Session ID: 1234567890-abc123
Status: completed
Duration: 45s

Summary:
  Containers scanned: 10
  Updates available: 3
  Successfully updated: 3
  Failed: 0

Container Updates:
  - nginx-web
    Image: nginx:latest
    Status: success
    Old digest: sha256:old1234...
    New digest: sha256:new5678...

  - redis-cache
    Image: redis:7-alpine
    Status: success
    Old digest: sha256:oldabc...
    New digest: sha256:newdef...
```

## Extending the Notification System

To add a new notification backend:

1. Implement the `Notifier` vtable interface
2. Create `send()` and `sendReport()` methods
3. Add parsing logic to `shoutrrr.zig` if needed
4. Update the config parser to support new URL schemes

Example:

```zig
pub const MyNotifier = struct {
    // Your fields
    allocator: std.mem.Allocator,
    
    pub fn asNotifier(self: *MyNotifier) Notifier {
        return Notifier{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendReport = sendReport,
                .deinit = deinitNotifier,
            },
        };
    }
    
    fn send(ptr: *anyopaque, notification: Notification) !void {
        const self: *MyNotifier = @ptrCast(@alignCast(ptr));
        // Implementation
    }
    
    fn sendReport(ptr: *anyopaque, report: *const SessionReport) !void {
        const self: *MyNotifier = @ptrCast(@alignCast(ptr));
        // Implementation
    }
    
    fn deinitNotifier(ptr: *anyopaque) void {
        const self: *MyNotifier = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
```

## Testing

Run the notification demo:

```bash
zig build notification-demo
./zig-out/bin/notification-demo
```

Run unit tests:

```bash
zig test src/notifications/webhook.zig
zig test src/notifications/email.zig
zig test src/notifications/slack.zig
zig test src/notifications/shoutrrr.zig
```

## Security Considerations

1. **Credentials in URLs**: Notification URLs may contain sensitive credentials. Store them securely and never log them.

2. **HTTPS for Webhooks**: Always use HTTPS for webhook URLs to prevent credential leakage.

3. **Email Authentication**: Use TLS/SSL for SMTP connections when possible.

4. **Rate Limiting**: Consider implementing rate limiting to prevent notification spam.

5. **Validation**: Validate URLs and parameters before creating notifiers.

## Future Enhancements

Potential additions for Phase 5+:

- [ ] Telegram bot integration
- [ ] Microsoft Teams webhooks
- [ ] PagerDuty integration
- [ ] Gotify support
- [ ] Matrix protocol support
- [ ] SMS via Twilio
- [ ] Custom notification templates
- [ ] Retry logic with exponential backoff
- [ ] Notification batching
- [ ] Per-container notification settings

## License

Apache-2.0 (same as WatchZ project)
