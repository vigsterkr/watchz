const std = @import("std");
const types = @import("../docker/types.zig");
const log = @import("../utils/log.zig");

/// Build a JSON configuration for creating a container from a ContainerDetails struct
/// This preserves all the original container configuration when recreating it
pub fn buildCreateConfig(
    allocator: std.mem.Allocator,
    details: *const types.ContainerDetails,
    new_image: []const u8,
) ![]u8 {
    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    const writer = json.writer(allocator);

    try writer.writeAll("{");

    // Image - use the new image
    try writer.print("\"Image\":\"{s}\"", .{new_image});

    // Hostname
    if (details.config.hostname.len > 0) {
        try writer.print(",\"Hostname\":\"{s}\"", .{details.config.hostname});
    }

    // User
    if (details.config.user.len > 0) {
        try writer.print(",\"User\":\"{s}\"", .{details.config.user});
    }

    // WorkingDir
    if (details.config.working_dir.len > 0) {
        try writer.print(",\"WorkingDir\":\"{s}\"", .{details.config.working_dir});
    }

    // Env
    if (details.config.env.items.len > 0) {
        try writer.writeAll(",\"Env\":[");
        for (details.config.env.items, 0..) |env_var, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{try escapeJson(allocator, env_var)});
        }
        try writer.writeAll("]");
    }

    // Cmd
    if (details.config.cmd.items.len > 0) {
        try writer.writeAll(",\"Cmd\":[");
        for (details.config.cmd.items, 0..) |cmd, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{try escapeJson(allocator, cmd)});
        }
        try writer.writeAll("]");
    }

    // Entrypoint
    if (details.config.entrypoint.items.len > 0) {
        try writer.writeAll(",\"Entrypoint\":[");
        for (details.config.entrypoint.items, 0..) |ep, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{try escapeJson(allocator, ep)});
        }
        try writer.writeAll("]");
    }

    // Labels
    if (details.config.labels.count() > 0) {
        try writer.writeAll(",\"Labels\":{");
        var iter = details.config.labels.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("\"{s}\":\"{s}\"", .{ try escapeJson(allocator, entry.key_ptr.*), try escapeJson(allocator, entry.value_ptr.*) });
        }
        try writer.writeAll("}");
    }

    // ExposedPorts
    if (details.config.exposed_ports.count() > 0) {
        try writer.writeAll(",\"ExposedPorts\":{");
        var iter = details.config.exposed_ports.keyIterator();
        var first = true;
        while (iter.next()) |key| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("\"{s}\":{{}}", .{key.*});
        }
        try writer.writeAll("}");
    }

    // Volumes (anonymous volumes)
    if (details.config.volumes.count() > 0) {
        try writer.writeAll(",\"Volumes\":{");
        var iter = details.config.volumes.keyIterator();
        var first = true;
        while (iter.next()) |key| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("\"{s}\":{{}}", .{key.*});
        }
        try writer.writeAll("}");
    }

    // HostConfig
    try writer.writeAll(",\"HostConfig\":{");

    var hc_first = true;

    // Binds
    if (details.host_config.binds.items.len > 0) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"Binds\":[");
        for (details.host_config.binds.items, 0..) |bind, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{try escapeJson(allocator, bind)});
        }
        try writer.writeAll("]");
    }

    // PortBindings
    if (details.host_config.port_bindings.count() > 0) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"PortBindings\":{");
        var pb_iter = details.host_config.port_bindings.iterator();
        var pb_first = true;
        while (pb_iter.next()) |entry| {
            if (!pb_first) try writer.writeAll(",");
            pb_first = false;
            try writer.print("\"{s}\":[", .{entry.key_ptr.*});
            for (entry.value_ptr.items, 0..) |binding, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.writeAll("{");
                if (binding.host_ip.len > 0) {
                    try writer.print("\"HostIp\":\"{s}\",", .{binding.host_ip});
                }
                try writer.print("\"HostPort\":\"{s}\"", .{binding.host_port});
                try writer.writeAll("}");
            }
            try writer.writeAll("]");
        }
        try writer.writeAll("}");
    }

    // RestartPolicy
    if (details.host_config.restart_policy.name.len > 0) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.print("\"RestartPolicy\":{{\"Name\":\"{s}\"", .{details.host_config.restart_policy.name});
        if (details.host_config.restart_policy.maximum_retry_count > 0) {
            try writer.print(",\"MaximumRetryCount\":{d}", .{details.host_config.restart_policy.maximum_retry_count});
        }
        try writer.writeAll("}");
    }

    // NetworkMode
    if (details.host_config.network_mode.len > 0) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.print("\"NetworkMode\":\"{s}\"", .{details.host_config.network_mode});
    }

    // Privileged
    if (details.host_config.privileged) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"Privileged\":true");
    }

    // Links
    if (details.host_config.links.items.len > 0) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"Links\":[");
        for (details.host_config.links.items, 0..) |link, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{try escapeJson(allocator, link)});
        }
        try writer.writeAll("]");
    }

    // AutoRemove
    if (details.host_config.auto_remove) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"AutoRemove\":true");
    }

    // PublishAllPorts
    if (details.host_config.publish_all_ports) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"PublishAllPorts\":true");
    }

    // CapAdd
    if (details.host_config.cap_add.items.len > 0) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"CapAdd\":[");
        for (details.host_config.cap_add.items, 0..) |cap, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{cap});
        }
        try writer.writeAll("]");
    }

    // CapDrop
    if (details.host_config.cap_drop.items.len > 0) {
        if (!hc_first) try writer.writeAll(",");
        hc_first = false;
        try writer.writeAll("\"CapDrop\":[");
        for (details.host_config.cap_drop.items, 0..) |cap, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{cap});
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}"); // End HostConfig

    try writer.writeAll("}"); // End config

    return try json.toOwnedSlice(allocator);
}

/// Build a NetworkingConfig JSON for a single network (Docker limitation)
/// Returns null if no networks are configured
pub fn buildNetworkingConfig(
    allocator: std.mem.Allocator,
    details: *const types.ContainerDetails,
) !?[]u8 {
    // Get the first network (Docker only allows one at create time)
    var iter = details.network_settings.networks.iterator();
    const first_network = iter.next() orelse return null;

    var json: std.ArrayList(u8) = .{};
    defer json.deinit(allocator);

    const writer = json.writer(allocator);

    try writer.writeAll("{\"EndpointsConfig\":{");
    try writer.print("\"{s}\":{{", .{first_network.key_ptr.*});

    // Add aliases if present, filtering out the old container ID
    if (first_network.value_ptr.aliases.items.len > 0) {
        try writer.writeAll("\"Aliases\":[");
        var first_alias = true;
        const short_id = if (details.id.len >= 12) details.id[0..12] else details.id;

        for (first_network.value_ptr.aliases.items) |alias| {
            // Skip the old container ID alias
            if (std.mem.eql(u8, alias, short_id)) continue;

            if (!first_alias) try writer.writeAll(",");
            first_alias = false;
            try writer.print("\"{s}\"", .{alias});
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}}}");

    return try json.toOwnedSlice(allocator);
}

/// Escape special characters for JSON strings
/// Handles: " \ newline carriage-return tab and control characters
fn escapeJson(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    // First pass: count how many extra bytes we need for escaping
    var extra_bytes: usize = 0;
    for (s) |c| {
        switch (c) {
            '"', '\\' => extra_bytes += 1, // These become 2 chars: \" or \\
            '\n', '\r', '\t' => extra_bytes += 1, // These become 2 chars: \n, \r, \t
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => extra_bytes += 5, // \uXXXX = 6 chars, replacing 1
            else => {},
        }
    }

    // If nothing needs escaping, return the original string
    if (extra_bytes == 0) return s;

    // Allocate buffer for escaped string
    const result = try allocator.alloc(u8, s.len + extra_bytes);
    var i: usize = 0;

    for (s) |c| {
        switch (c) {
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                result[i] = '\\';
                result[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                result[i] = '\\';
                result[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                result[i] = '\\';
                result[i + 1] = 't';
                i += 2;
            },
            // Control characters (0x00-0x1F except \n \r \t which are handled above)
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                // Format as \uXXXX
                result[i] = '\\';
                result[i + 1] = 'u';
                result[i + 2] = '0';
                result[i + 3] = '0';
                // Convert to hex digits
                const high = c >> 4;
                const low = c & 0x0F;
                result[i + 4] = if (high < 10) '0' + high else 'a' + (high - 10);
                result[i + 5] = if (low < 10) '0' + low else 'a' + (low - 10);
                i += 6;
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }

    return result[0..i];
}
