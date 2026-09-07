const std = @import("std");
const config = @import("config.zig");
const util = @import("util.zig");

pub const Engine = enum { podman, docker };

pub const ResourceKind = enum {
    containers,
    images,
    volumes,
    networks,
    pods,
};

pub const Row = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    extra: []const u8,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
        allocator.free(self.extra);
    }
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    engine: Engine,
    host: ?*const config.Host = null,

    pub fn detect(allocator: std.mem.Allocator, io: std.Io, host: *const config.Host) !Backend {
        const preferred = host.container.engine;
        if (preferred == .podman or preferred == .auto) {
            if (try hasBinary(io, allocator, "podman")) {
                return .{ .allocator = allocator, .io = io, .engine = .podman, .host = host };
            }
        }
        if (preferred == .docker or preferred == .auto) {
            if (try hasBinary(io, allocator, "docker")) {
                return .{ .allocator = allocator, .io = io, .engine = .docker, .host = host };
            }
        }
        // Default label even if missing — UI can show errors from commands.
        return .{
            .allocator = allocator,
            .io = io,
            .engine = if (preferred == .docker) .docker else .podman,
            .host = host,
        };
    }

    pub fn list(self: *Backend, kind: ResourceKind) ![]Row {
        return switch (kind) {
            .containers => self.listContainers(),
            .images => self.listImages(),
            .volumes => self.listVolumes(),
            .networks => self.listNetworks(),
            .pods => self.listPods(),
        };
    }

    pub fn action(self: *Backend, verb: []const u8, id: []const u8) ![]u8 {
        const argv = try self.buildArgv(&.{ verb, id });
        defer freeArgv(self.allocator, argv);
        return self.runCapture(argv);
    }

    pub fn logs(self: *Backend, id: []const u8, tail: u32) ![]u8 {
        var tail_buf: [16]u8 = undefined;
        const tail_s = try std.fmt.bufPrint(&tail_buf, "{d}", .{tail});
        const argv = try self.buildArgv(&.{ "logs", "--tail", tail_s, id });
        defer freeArgv(self.allocator, argv);
        return self.runCapture(argv);
    }

    pub fn inspect(self: *Backend, kind: ResourceKind, id: []const u8) ![]u8 {
        const resource = switch (kind) {
            .containers => "container",
            .images => "image",
            .volumes => "volume",
            .networks => "network",
            .pods => "pod",
        };
        const argv = try self.buildArgv(&.{ resource, "inspect", id });
        defer freeArgv(self.allocator, argv);
        return self.runCapture(argv);
    }

    fn listContainers(self: *Backend) ![]Row {
        const fmt = "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}";
        const argv = try self.buildArgv(&.{ "ps", "-a", "--format", fmt });
        defer freeArgv(self.allocator, argv);
        const out = self.runCapture(argv) catch return try self.emptyRows();
        defer self.allocator.free(out);
        return parseTsv(self.allocator, out, 4);
    }

    fn listImages(self: *Backend) ![]Row {
        const fmt = "{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}";
        const argv = try self.buildArgv(&.{ "images", "--format", fmt });
        defer freeArgv(self.allocator, argv);
        const out = self.runCapture(argv) catch return try self.emptyRows();
        defer self.allocator.free(out);
        return parseTsv(self.allocator, out, 4);
    }

    fn listVolumes(self: *Backend) ![]Row {
        const fmt = "{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}\t";
        const argv = try self.buildArgv(&.{ "volume", "ls", "--format", fmt });
        defer freeArgv(self.allocator, argv);
        const out = self.runCapture(argv) catch return try self.emptyRows();
        defer self.allocator.free(out);
        return parseTsv(self.allocator, out, 4);
    }

    fn listNetworks(self: *Backend) ![]Row {
        const fmt = "{{.ID}}\t{{.Name}}\t{{.Driver}}\t{{.Scope}}";
        const argv = try self.buildArgv(&.{ "network", "ls", "--format", fmt });
        defer freeArgv(self.allocator, argv);
        const out = self.runCapture(argv) catch return try self.emptyRows();
        defer self.allocator.free(out);
        return parseTsv(self.allocator, out, 4);
    }

    fn listPods(self: *Backend) ![]Row {
        if (self.engine != .podman) return try self.emptyRows();
        const fmt = "{{.ID}}\t{{.Name}}\t{{.Status}}\t{{.NumberOfContainers}}";
        const argv = try self.buildArgv(&.{ "pod", "ps", "--format", fmt });
        defer freeArgv(self.allocator, argv);
        const out = self.runCapture(argv) catch return try self.emptyRows();
        defer self.allocator.free(out);
        return parseTsv(self.allocator, out, 4);
    }

    fn emptyRows(self: *Backend) ![]Row {
        return try self.allocator.alloc(Row, 0);
    }

    fn buildArgv(self: *Backend, rest: []const []const u8) ![]const []const u8 {
        var argv_list: std.ArrayList([]const u8) = .empty;
        errdefer argv_list.deinit(self.allocator);

        if (self.host) |h| {
            if (h.kind == .ssh and h.ssh.host.len > 0) {
                try argv_list.append(self.allocator, try self.allocator.dupe(u8, "ssh"));
                if (h.ssh.port != 22) {
                    try argv_list.append(self.allocator, try self.allocator.dupe(u8, "-p"));
                    try argv_list.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{h.ssh.port}));
                }
                if (h.ssh.identity_file.len > 0) {
                    try argv_list.append(self.allocator, try self.allocator.dupe(u8, "-i"));
                    try argv_list.append(self.allocator, try util.expandHome(self.allocator, h.ssh.identity_file));
                }
                const target = if (h.ssh.user.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ h.ssh.user, h.ssh.host })
                else
                    try self.allocator.dupe(u8, h.ssh.host);
                try argv_list.append(self.allocator, target);
            }
        }

        try argv_list.append(self.allocator, try self.allocator.dupe(u8, @tagName(self.engine)));
        for (rest) |r| try argv_list.append(self.allocator, try self.allocator.dupe(u8, r));
        return argv_list.toOwnedSlice(self.allocator);
    }

    fn runCapture(self: *Backend, argv: []const []const u8) ![]u8 {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| {
            return std.fmt.allocPrint(self.allocator, "error: {s}", .{@errorName(err)});
        };
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| {
                if (code == 0) return result.stdout;
                defer self.allocator.free(result.stdout);
                if (result.stderr.len > 0) return try self.allocator.dupe(u8, result.stderr);
                return try std.fmt.allocPrint(self.allocator, "exit {d}", .{code});
            },
            else => {
                defer self.allocator.free(result.stdout);
                return try std.fmt.allocPrint(self.allocator, "command failed: {s}", .{result.stderr});
            },
        }
    }
};

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

fn hasBinary(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "which", name },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn parseTsv(allocator: std.mem.Allocator, text: []const u8, _: usize) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const id = cols.next() orelse continue;
        const name = cols.next() orelse "";
        const status = cols.next() orelse "";
        const extra = cols.next() orelse "";
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, std.mem.trim(u8, id, " \t\r")),
            .name = try allocator.dupe(u8, std.mem.trim(u8, name, " \t\r")),
            .status = try allocator.dupe(u8, std.mem.trim(u8, status, " \t\r")),
            .extra = try allocator.dupe(u8, std.mem.trim(u8, extra, " \t\r")),
        });
    }
    return rows.toOwnedSlice(allocator);
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |*r| r.deinit(allocator);
    allocator.free(rows);
}
