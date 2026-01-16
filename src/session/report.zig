const std = @import("std");

/// Tracks the state and events of an update session
pub const SessionReport = struct {
    /// Unique session ID
    session_id: []const u8,

    /// Session start time (Unix timestamp)
    start_time: i64,

    /// Session end time (Unix timestamp)
    end_time: ?i64 = null,

    /// Containers scanned during this session
    containers_scanned: usize = 0,

    /// Containers that had updates available
    containers_with_updates: usize = 0,

    /// Containers successfully updated
    containers_updated: usize = 0,

    /// Containers that failed to update
    containers_failed: usize = 0,

    /// Individual container update records
    updates: std.ArrayList(ContainerUpdate),

    /// Overall session status
    status: SessionStatus = .running,

    allocator: std.mem.Allocator,

    pub const SessionStatus = enum {
        running,
        completed,
        partial_failure,
        failed,
    };

    pub fn init(allocator: std.mem.Allocator, session_id: []const u8) !SessionReport {
        const owned_id = try allocator.dupe(u8, session_id);
        return SessionReport{
            .session_id = owned_id,
            .start_time = std.time.timestamp(),
            .updates = std.ArrayList(ContainerUpdate).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionReport) void {
        self.allocator.free(self.session_id);
        for (self.updates.items) |*update| {
            update.deinit();
        }
        self.updates.deinit();
    }

    pub fn addUpdate(self: *SessionReport, update: ContainerUpdate) !void {
        try self.updates.append(update);
    }

    pub fn complete(self: *SessionReport) void {
        self.end_time = std.time.timestamp();

        // Determine overall status
        if (self.containers_failed > 0) {
            if (self.containers_updated > 0) {
                self.status = .partial_failure;
            } else {
                self.status = .failed;
            }
        } else {
            self.status = .completed;
        }
    }

    pub fn duration(self: *const SessionReport) i64 {
        const end = self.end_time orelse std.time.timestamp();
        return end - self.start_time;
    }

    /// Format the report as a human-readable string
    pub fn format(self: *const SessionReport, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        try writer.print("WatchZ Update Session Report\n", .{});
        try writer.print("===========================\n\n", .{});
        try writer.print("Session ID: {s}\n", .{self.session_id});
        try writer.print("Status: {s}\n", .{@tagName(self.status)});
        try writer.print("Duration: {d}s\n\n", .{self.duration()});

        try writer.print("Summary:\n", .{});
        try writer.print("  Containers scanned: {d}\n", .{self.containers_scanned});
        try writer.print("  Updates available: {d}\n", .{self.containers_with_updates});
        try writer.print("  Successfully updated: {d}\n", .{self.containers_updated});
        try writer.print("  Failed: {d}\n\n", .{self.containers_failed});

        if (self.updates.items.len > 0) {
            try writer.print("Container Updates:\n", .{});
            for (self.updates.items) |update| {
                try writer.print("  - {s}\n", .{update.container_name});
                try writer.print("    Image: {s}\n", .{update.image});
                try writer.print("    Status: {s}\n", .{@tagName(update.status)});
                if (update.error_message) |err| {
                    try writer.print("    Error: {s}\n", .{err});
                }
                if (update.old_digest) |old| {
                    try writer.print("    Old digest: {s}\n", .{old});
                }
                if (update.new_digest) |new| {
                    try writer.print("    New digest: {s}\n", .{new});
                }
                try writer.print("\n", .{});
            }
        }

        return buffer.toOwnedSlice();
    }
};

/// Record of a single container update
pub const ContainerUpdate = struct {
    /// Container name or ID
    container_name: []const u8,

    /// Container ID
    container_id: []const u8,

    /// Image being updated
    image: []const u8,

    /// Old image digest (if available)
    old_digest: ?[]const u8 = null,

    /// New image digest (if available)
    new_digest: ?[]const u8 = null,

    /// Update status
    status: UpdateStatus,

    /// Error message if update failed
    error_message: ?[]const u8 = null,

    /// Update timestamp
    timestamp: i64,

    allocator: std.mem.Allocator,

    pub const UpdateStatus = enum {
        /// Update check in progress
        checking,

        /// Update available
        update_available,

        /// No update available
        up_to_date,

        /// Pulling new image
        pulling,

        /// Stopping container
        stopping,

        /// Starting new container
        starting,

        /// Update successful
        success,

        /// Update failed
        failed,

        /// Skipped (monitor-only mode)
        skipped,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        container_name: []const u8,
        container_id: []const u8,
        image: []const u8,
        status: UpdateStatus,
    ) !ContainerUpdate {
        return ContainerUpdate{
            .container_name = try allocator.dupe(u8, container_name),
            .container_id = try allocator.dupe(u8, container_id),
            .image = try allocator.dupe(u8, image),
            .status = status,
            .timestamp = std.time.timestamp(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ContainerUpdate) void {
        self.allocator.free(self.container_name);
        self.allocator.free(self.container_id);
        self.allocator.free(self.image);
        if (self.old_digest) |d| self.allocator.free(d);
        if (self.new_digest) |d| self.allocator.free(d);
        if (self.error_message) |e| self.allocator.free(e);
    }

    pub fn setError(self: *ContainerUpdate, error_message: []const u8) !void {
        if (self.error_message) |old| {
            self.allocator.free(old);
        }
        self.error_message = try self.allocator.dupe(u8, error_message);
        self.status = .failed;
    }

    pub fn setDigests(self: *ContainerUpdate, old: ?[]const u8, new: ?[]const u8) !void {
        if (old) |o| {
            if (self.old_digest) |old_d| self.allocator.free(old_d);
            self.old_digest = try self.allocator.dupe(u8, o);
        }
        if (new) |n| {
            if (self.new_digest) |new_d| self.allocator.free(new_d);
            self.new_digest = try self.allocator.dupe(u8, n);
        }
    }
};
