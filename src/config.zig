const std = @import("std");
const util = @import("util.zig");

pub const Engine = enum { auto, podman, docker };

pub const HostKind = enum { local, ssh };

pub const ContainerCfg = struct {
    engine: Engine = .auto,
    rootless: bool = true,
};

pub const SshCfg = struct {
    host: []const u8 = "",
    user: []const u8 = "",
    port: u16 = 22,
    identity_file: []const u8 = "",
};

pub const HermesCfg = struct {
    base_url: []const u8 = "http://127.0.0.1:8642/v1",
    api_key_env: []const u8 = "HERMES_API_KEY",
};

pub const Host = struct {
    name: []const u8,
    kind: HostKind = .local,
    container: ContainerCfg = .{},
    ssh: SshCfg = .{},
    kubeconfig: []const u8 = "~/.kube/config",
    contexts: []const []const u8 = &.{},
    hermes: HermesCfg = .{},

    pub fn deinit(self: *Host, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.ssh.host);
        allocator.free(self.ssh.user);
        allocator.free(self.ssh.identity_file);
        allocator.free(self.kubeconfig);
        for (self.contexts) |c| allocator.free(c);
        allocator.free(self.contexts);
        allocator.free(self.hermes.base_url);
        allocator.free(self.hermes.api_key_env);
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    hosts: std.ArrayList(Host),
    path: []u8,

    pub fn deinit(self: *Config) void {
        for (self.hosts.items) |*h| h.deinit(self.allocator);
        self.hosts.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    pub fn selectedOrFirst(self: *const Config, idx: usize) ?*const Host {
        if (self.hosts.items.len == 0) return null;
        if (idx >= self.hosts.items.len) return &self.hosts.items[0];
        return &self.hosts.items[idx];
    }

    pub fn findHost(self: *const Config, name: []const u8) ?usize {
        for (self.hosts.items, 0..) |h, i| {
            if (std.mem.eql(u8, h.name, name)) return i;
        }
        return null;
    }
};

pub fn defaultLocal(allocator: std.mem.Allocator) !Host {
    return .{
        .name = try allocator.dupe(u8, "local"),
        .kind = .local,
        .container = .{ .engine = .auto, .rootless = true },
        .ssh = .{
            .host = try allocator.dupe(u8, ""),
            .user = try allocator.dupe(u8, ""),
            .identity_file = try allocator.dupe(u8, ""),
        },
        .kubeconfig = try allocator.dupe(u8, "~/.kube/config"),
        .contexts = &.{},
        .hermes = .{
            .base_url = try allocator.dupe(u8, "http://127.0.0.1:8642/v1"),
            .api_key_env = try allocator.dupe(u8, "HERMES_API_KEY"),
        },
    };
}

pub fn loadOrCreate(allocator: std.mem.Allocator, io: std.Io) !Config {
    const path = try util.configPath(allocator);
    errdefer allocator.free(path);

    var cfg: Config = .{
        .allocator = allocator,
        .hosts = .empty,
        .path = path,
    };
    errdefer cfg.deinit();

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try ensureDir(allocator, io);
            try cfg.hosts.append(allocator, try defaultLocal(allocator));
            try save(&cfg, io);
            return cfg;
        },
        else => return err,
    };
    defer allocator.free(contents);
    try parseYaml(&cfg, contents);
    if (cfg.hosts.items.len == 0) {
        try cfg.hosts.append(allocator, try defaultLocal(allocator));
    }
    return cfg;
}

fn ensureDir(allocator: std.mem.Allocator, io: std.Io) !void {
    const dir = try util.configDir(allocator);
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
}

pub fn save(cfg: *const Config, io: std.Io) !void {
    try ensureDir(cfg.allocator, io);
    var file = try std.Io.Dir.cwd().createFile(io, cfg.path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try writeYaml(&w.interface, cfg);
    try w.interface.flush();
}

fn writeYaml(w: *std.Io.Writer, cfg: *const Config) !void {
    try w.writeAll("# tower fleet config\nhosts:\n");
    for (cfg.hosts.items) |h| {
        try w.print("  - name: {s}\n", .{h.name});
        try w.print("    kind: {s}\n", .{@tagName(h.kind)});
        try w.print("    container:\n      engine: {s}\n      rootless: {}\n", .{
            @tagName(h.container.engine),
            h.container.rootless,
        });
        if (h.kind == .ssh) {
            try w.print("    ssh:\n      host: {s}\n      user: {s}\n      port: {d}\n", .{
                h.ssh.host,
                h.ssh.user,
                h.ssh.port,
            });
            if (h.ssh.identity_file.len > 0) {
                try w.print("      identity_file: {s}\n", .{h.ssh.identity_file});
            }
        }
        try w.print("    kubeconfig: {s}\n", .{h.kubeconfig});
        if (h.contexts.len > 0) {
            try w.writeAll("    contexts:\n");
            for (h.contexts) |c| try w.print("      - {s}\n", .{c});
        }
        try w.print("    hermes:\n      base_url: {s}\n      api_key_env: {s}\n", .{
            h.hermes.base_url,
            h.hermes.api_key_env,
        });
    }
}

fn parseYaml(cfg: *Config, contents: []const u8) !void {
    var current: ?Host = null;
    var section: enum { none, container, ssh, hermes, contexts } = .none;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const trimmed = std.mem.trimStart(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            if (current) |h| try cfg.hosts.append(cfg.allocator, h);
            current = .{
                .name = try dupValue(cfg.allocator, trimmed["- name:".len..]),
                .kind = .local,
                .container = .{},
                .ssh = .{
                    .host = try cfg.allocator.dupe(u8, ""),
                    .user = try cfg.allocator.dupe(u8, ""),
                    .identity_file = try cfg.allocator.dupe(u8, ""),
                },
                .kubeconfig = try cfg.allocator.dupe(u8, "~/.kube/config"),
                .contexts = &.{},
                .hermes = .{
                    .base_url = try cfg.allocator.dupe(u8, "http://127.0.0.1:8642/v1"),
                    .api_key_env = try cfg.allocator.dupe(u8, "HERMES_API_KEY"),
                },
            };
            section = .none;
            continue;
        }

        var host = &(current orelse continue);

        if (std.mem.eql(u8, trimmed, "container:")) {
            section = .container;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "ssh:")) {
            section = .ssh;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "hermes:")) {
            section = .hermes;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "contexts:")) {
            section = .contexts;
            continue;
        }

        if (section == .contexts and std.mem.startsWith(u8, trimmed, "- ")) {
            const val = try dupValue(cfg.allocator, trimmed[2..]);
            var ctx_list: std.ArrayList([]const u8) = .empty;
            defer ctx_list.deinit(cfg.allocator);
            try ctx_list.appendSlice(cfg.allocator, host.contexts);
            cfg.allocator.free(host.contexts);
            try ctx_list.append(cfg.allocator, val);
            host.contexts = try ctx_list.toOwnedSlice(cfg.allocator);
            continue;
        }

        if (kv(trimmed, "kind")) |v| {
            host.kind = if (std.mem.eql(u8, v, "ssh")) .ssh else .local;
            section = .none;
            continue;
        }
        if (kv(trimmed, "kubeconfig")) |v| {
            cfg.allocator.free(host.kubeconfig);
            host.kubeconfig = try dupValue(cfg.allocator, v);
            section = .none;
            continue;
        }

        switch (section) {
            .container => {
                if (kv(trimmed, "engine")) |v| {
                    host.container.engine = parseEngine(v);
                } else if (kv(trimmed, "rootless")) |v| {
                    host.container.rootless = !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no"));
                }
            },
            .ssh => {
                if (kv(trimmed, "host")) |v| {
                    cfg.allocator.free(host.ssh.host);
                    host.ssh.host = try dupValue(cfg.allocator, v);
                } else if (kv(trimmed, "user")) |v| {
                    cfg.allocator.free(host.ssh.user);
                    host.ssh.user = try dupValue(cfg.allocator, v);
                } else if (kv(trimmed, "identity_file")) |v| {
                    cfg.allocator.free(host.ssh.identity_file);
                    host.ssh.identity_file = try dupValue(cfg.allocator, v);
                } else if (kv(trimmed, "port")) |v| {
                    host.ssh.port = std.fmt.parseInt(u16, v, 10) catch 22;
                }
            },
            .hermes => {
                if (kv(trimmed, "base_url")) |v| {
                    cfg.allocator.free(host.hermes.base_url);
                    host.hermes.base_url = try dupValue(cfg.allocator, v);
                } else if (kv(trimmed, "api_key_env")) |v| {
                    cfg.allocator.free(host.hermes.api_key_env);
                    host.hermes.api_key_env = try dupValue(cfg.allocator, v);
                }
            },
            else => {},
        }
    }
    if (current) |h| try cfg.hosts.append(cfg.allocator, h);
}

fn parseEngine(v: []const u8) Engine {
    if (std.mem.eql(u8, v, "podman")) return .podman;
    if (std.mem.eql(u8, v, "docker")) return .docker;
    return .auto;
}

fn kv(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len <= key.len or line[key.len] != ':') return null;
    return std.mem.trim(u8, line[key.len + 1 ..], " \t\"'");
}

fn dupValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\"'"));
}

test "parse minimal yaml" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{
        .allocator = allocator,
        .hosts = .empty,
        .path = try allocator.dupe(u8, "test"),
    };
    defer cfg.deinit();
    try parseYaml(&cfg,
        \\hosts:
        \\  - name: local
        \\    kind: local
        \\    container:
        \\      engine: podman
        \\      rootless: true
        \\    hermes:
        \\      base_url: http://127.0.0.1:8642/v1
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.hosts.items.len);
    try std.testing.expectEqualStrings("local", cfg.hosts.items[0].name);
    try std.testing.expect(cfg.hosts.items[0].container.engine == .podman);
}
