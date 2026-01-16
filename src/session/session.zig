const std = @import("std");
const SessionReport = @import("report.zig").SessionReport;

/// Simple session ID generator
pub fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const random = std.crypto.random.int(u32);

    return std.fmt.allocPrint(
        allocator,
        "{d}-{x}",
        .{ timestamp, random },
    );
}

/// Session tracker that can be used globally to track the current update session
pub const SessionTracker = struct {
    current_session: ?*SessionReport,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) SessionTracker {
        return SessionTracker{
            .current_session = null,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *SessionTracker) void {
        if (self.current_session) |session| {
            session.deinit();
            self.allocator.destroy(session);
        }
    }

    /// Start a new session
    pub fn startSession(self: *SessionTracker) !*SessionReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up any existing session
        if (self.current_session) |old_session| {
            old_session.deinit();
            self.allocator.destroy(old_session);
        }

        const session_id = try generateSessionId(self.allocator);
        defer self.allocator.free(session_id);

        const session = try self.allocator.create(SessionReport);
        session.* = try SessionReport.init(self.allocator, session_id);

        self.current_session = session;
        return session;
    }

    /// Get the current active session
    pub fn getCurrentSession(self: *SessionTracker) ?*SessionReport {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_session;
    }

    /// Complete the current session
    pub fn completeSession(self: *SessionTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.current_session) |session| {
            session.complete();
        }
    }
};
