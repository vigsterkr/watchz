const std = @import("std");
const log = @import("log.zig");

/// Configuration for retry behavior
pub const RetryConfig = struct {
    max_retries: u8 = 3,
    initial_delay_ms: u64 = 1000, // 1 second
    max_delay_ms: u64 = 10000, // 10 seconds
    backoff_multiplier: f64 = 2.0,
};

/// Identifies if an error is transient and should be retried
pub fn isTransientError(err: anyerror) bool {
    return switch (err) {
        // Network-related transient errors
        error.ConnectionTimedOut,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.Unexpected, // Can include errno 110 (ETIMEDOUT)
        error.WouldBlock,
        error.BrokenPipe,
        error.NotOpenForReading,
        error.NotOpenForWriting,

        // HTTP-specific transient errors
        error.EndOfStream,
        error.UnexpectedEndOfStream,
        error.HttpHeadersOversize,
        error.HttpChunkInvalid,
        error.InvalidContentLength,

        // Registry-specific that might be transient
        error.ManifestFetchFailed,
        => true,

        else => false,
    };
}

/// Retry an operation with exponential backoff
///
/// Example:
/// ```
/// const result = try retryWithBackoff(
///     allocator,
///     config,
///     "fetch manifest",
///     fetchManifestFn,
///     .{arg1, arg2}
/// );
/// ```
pub inline fn retryWithBackoff(
    retry_config: RetryConfig,
    operation_name: []const u8,
    comptime func: anytype,
    args: anytype,
) @TypeOf(@call(.auto, func, args)) {
    var attempt: u8 = 0;
    var delay_ms = retry_config.initial_delay_ms;

    while (attempt <= retry_config.max_retries) : (attempt += 1) {
        const result = @call(.auto, func, args);

        if (result) |success| {
            // Success!
            if (attempt > 0) {
                log.info("✓ {s} succeeded after {d} retry(s)", .{ operation_name, attempt });
            }
            return success;
        } else |err| {
            // Check if this is the last attempt
            const is_last_attempt = (attempt >= retry_config.max_retries);

            if (isTransientError(err)) {
                if (is_last_attempt) {
                    log.warn("✗ {s} failed after {d} attempts: {}", .{ operation_name, attempt + 1, err });
                    return err;
                } else {
                    log.debug("⟳ {s} failed (attempt {d}/{d}): {}. Retrying in {d}ms...", .{
                        operation_name,
                        attempt + 1,
                        retry_config.max_retries + 1,
                        err,
                        delay_ms,
                    });

                    // Sleep before retry
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);

                    // Calculate next delay with exponential backoff
                    const next_delay = @as(u64, @intFromFloat(@as(f64, @floatFromInt(delay_ms)) * retry_config.backoff_multiplier));
                    delay_ms = @min(next_delay, retry_config.max_delay_ms);
                }
            } else {
                // Non-transient error, don't retry
                log.debug("✗ {s} failed with non-transient error: {}", .{ operation_name, err });
                return err;
            }
        }
    }

    // Should never reach here, but satisfy the compiler
    unreachable;
}

test "isTransientError identifies network errors" {
    try std.testing.expect(isTransientError(error.ConnectionTimedOut));
    try std.testing.expect(isTransientError(error.ConnectionRefused));
    try std.testing.expect(isTransientError(error.Unexpected));
    try std.testing.expect(isTransientError(error.BrokenPipe));
}

test "isTransientError rejects permanent errors" {
    try std.testing.expect(!isTransientError(error.OutOfMemory));
    try std.testing.expect(!isTransientError(error.AccessDenied));
    try std.testing.expect(!isTransientError(error.InvalidArgument));
}

test "RetryConfig default values" {
    const config = RetryConfig{};
    try std.testing.expectEqual(@as(u8, 3), config.max_retries);
    try std.testing.expectEqual(@as(u64, 1000), config.initial_delay_ms);
    try std.testing.expectEqual(@as(u64, 10000), config.max_delay_ms);
}
