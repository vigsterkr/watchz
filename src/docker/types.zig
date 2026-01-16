const std = @import("std");

/// Empty struct for map values (exposed ports, volumes)
pub const EmptyValue = struct {};

pub const Container = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    image_id: []const u8,
    state: []const u8,
    status: []const u8,
    labels: std.StringHashMap([]const u8),
    created: i64,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Container) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.image);
        self.allocator.free(self.image_id);
        self.allocator.free(self.state);
        self.allocator.free(self.status);
        self.labels.deinit();
    }
};

pub const ContainerDetails = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    config: ContainerConfig,
    state: ContainerState,
    host_config: HostConfig,
    network_settings: NetworkSettings,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ContainerDetails) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.image);
        self.config.deinit();
        self.state.deinit();
        self.host_config.deinit();
        self.network_settings.deinit();
    }
};

pub const ContainerConfig = struct {
    hostname: []const u8,
    env: std.ArrayList([]const u8),
    cmd: std.ArrayList([]const u8),
    image: []const u8,
    labels: std.StringHashMap([]const u8),
    entrypoint: std.ArrayList([]const u8),
    working_dir: []const u8,
    user: []const u8,
    exposed_ports: std.StringHashMap(EmptyValue),
    volumes: std.StringHashMap(EmptyValue),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ContainerConfig {
        return .{
            .hostname = "",
            .env = .{},
            .cmd = .{},
            .image = "",
            .labels = std.StringHashMap([]const u8).init(allocator),
            .entrypoint = .{},
            .working_dir = "",
            .user = "",
            .exposed_ports = std.StringHashMap(EmptyValue).init(allocator),
            .volumes = std.StringHashMap(EmptyValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ContainerConfig) void {
        if (self.hostname.len > 0) self.allocator.free(self.hostname);
        for (self.env.items) |item| self.allocator.free(item);
        self.env.deinit(self.allocator);
        for (self.cmd.items) |item| self.allocator.free(item);
        self.cmd.deinit(self.allocator);
        if (self.image.len > 0) self.allocator.free(self.image);
        self.labels.deinit();
        for (self.entrypoint.items) |item| self.allocator.free(item);
        self.entrypoint.deinit(self.allocator);
        if (self.working_dir.len > 0) self.allocator.free(self.working_dir);
        if (self.user.len > 0) self.allocator.free(self.user);
        self.exposed_ports.deinit();
        self.volumes.deinit();
    }
};

pub const ContainerState = struct {
    status: []const u8,
    running: bool,
    paused: bool,
    restarting: bool,
    pid: i32,
    exit_code: i32,
    started_at: []const u8,
    finished_at: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ContainerState) void {
        self.allocator.free(self.status);
        self.allocator.free(self.started_at);
        self.allocator.free(self.finished_at);
    }
};

pub const HostConfig = struct {
    binds: std.ArrayList([]const u8),
    port_bindings: std.StringHashMap(std.ArrayList(PortBinding)),
    restart_policy: RestartPolicy,
    network_mode: []const u8,
    privileged: bool,
    links: std.ArrayList([]const u8),
    auto_remove: bool,
    publish_all_ports: bool,
    cap_add: std.ArrayList([]const u8),
    cap_drop: std.ArrayList([]const u8),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HostConfig {
        return .{
            .binds = .{},
            .port_bindings = std.StringHashMap(std.ArrayList(PortBinding)).init(allocator),
            .restart_policy = .{ .name = "", .maximum_retry_count = 0 },
            .network_mode = "",
            .privileged = false,
            .links = .{},
            .auto_remove = false,
            .publish_all_ports = false,
            .cap_add = .{},
            .cap_drop = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HostConfig) void {
        for (self.binds.items) |item| self.allocator.free(item);
        self.binds.deinit(self.allocator);

        var iter = self.port_bindings.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |binding| {
                if (binding.host_ip.len > 0) self.allocator.free(binding.host_ip);
                if (binding.host_port.len > 0) self.allocator.free(binding.host_port);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.port_bindings.deinit();

        if (self.restart_policy.name.len > 0) self.allocator.free(self.restart_policy.name);
        if (self.network_mode.len > 0) self.allocator.free(self.network_mode);

        for (self.links.items) |item| self.allocator.free(item);
        self.links.deinit(self.allocator);

        for (self.cap_add.items) |item| self.allocator.free(item);
        self.cap_add.deinit(self.allocator);

        for (self.cap_drop.items) |item| self.allocator.free(item);
        self.cap_drop.deinit(self.allocator);
    }
};

pub const PortBinding = struct {
    host_ip: []const u8,
    host_port: []const u8,
};

pub const RestartPolicy = struct {
    name: []const u8,
    maximum_retry_count: i32,
};

pub const NetworkSettings = struct {
    networks: std.StringHashMap(NetworkEndpoint),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NetworkSettings {
        return .{
            .networks = std.StringHashMap(NetworkEndpoint).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NetworkSettings) void {
        var iter = self.networks.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.ip_address.len > 0) self.allocator.free(entry.value_ptr.ip_address);
            if (entry.value_ptr.gateway.len > 0) self.allocator.free(entry.value_ptr.gateway);
            entry.value_ptr.deinit(self.allocator);
        }
        self.networks.deinit();
    }
};

pub const NetworkEndpoint = struct {
    network_id: []const u8,
    ip_address: []const u8,
    gateway: []const u8,
    ip_prefix_len: i32,
    aliases: std.ArrayList([]const u8),

    pub fn deinit(self: *NetworkEndpoint, allocator: std.mem.Allocator) void {
        for (self.aliases.items) |alias| allocator.free(alias);
        self.aliases.deinit(allocator);
    }
};

pub const Image = struct {
    id: []const u8,
    repo_tags: std.ArrayList([]const u8),
    repo_digests: std.ArrayList([]const u8),
    created: i64,
    size: u64,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.id);
        for (self.repo_tags.items) |tag| self.allocator.free(tag);
        self.repo_tags.deinit(self.allocator);
        for (self.repo_digests.items) |digest| self.allocator.free(digest);
        self.repo_digests.deinit(self.allocator);
    }
};

pub const Version = struct {
    version: []const u8,
    api_version: []const u8,
    min_api_version: []const u8,
    git_commit: []const u8,
    go_version: []const u8,
    os: []const u8,
    arch: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Version) void {
        self.allocator.free(self.version);
        self.allocator.free(self.api_version);
        self.allocator.free(self.min_api_version);
        self.allocator.free(self.git_commit);
        self.allocator.free(self.go_version);
        self.allocator.free(self.os);
        self.allocator.free(self.arch);
    }
};
