const std = @import("std");
const registry = @import("../src/registry/client.zig");
const types = @import("../src/registry/types.zig");
const log = @import("../src/utils/log.zig");

/// Example: Check if an image has an update available
/// Usage: zig run examples/registry_check.zig -- nginx:latest sha256:abc123...
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logger
    log.init(.info);

    // Get command line arguments
    var args = std.process.argsWithAllocator(allocator) catch |err| {
        std.debug.print("Failed to get args: {}\n", .{err});
        return;
    };
    defer args.deinit();

    _ = args.skip(); // Skip program name

    const image_name = args.next() orelse {
        std.debug.print("Usage: registry_check <image_name> <current_digest>\n", .{});
        std.debug.print("Example: registry_check nginx:latest sha256:abc123...\n", .{});
        return error.MissingArguments;
    };

    const current_digest = args.next() orelse {
        std.debug.print("Usage: registry_check <image_name> <current_digest>\n", .{});
        std.debug.print("Example: registry_check nginx:latest sha256:abc123...\n", .{});
        return error.MissingArguments;
    };

    std.debug.print("Checking for updates: {s}\n", .{image_name});
    std.debug.print("Current digest: {s}\n\n", .{current_digest});

    // Create default config for the example
    const config = @import("../src/config.zig").Config.init(allocator);

    // Create registry client
    var client = registry.RegistryClient.init(allocator, &config);
    defer client.deinit();

    // Check for updates
    var result = client.checkForUpdate(current_digest, image_name) catch |err| {
        std.debug.print("Error checking for updates: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    // Display results
    if (result.has_update) {
        std.debug.print("✓ UPDATE AVAILABLE!\n", .{});
        std.debug.print("  Latest digest: {s}\n", .{result.latest_digest});
        if (result.message) |msg| {
            std.debug.print("  Message: {s}\n", .{msg});
        }
    } else {
        std.debug.print("✗ No updates available\n", .{});
        std.debug.print("  Image is up to date\n", .{});
    }
}
