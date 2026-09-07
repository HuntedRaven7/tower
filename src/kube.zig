const std = @import("std");
const config = @import("config.zig");
const util = @import("util.zig");

pub const ResourceKind = enum {
    pods,
    nodes,
    deployments,
    services,
    namespaces,
};

pub const Row = struct {
    name: []const u8,
    namespace: []const u8,
    status: []const u8,
    extra: []const u8,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.namespace);
        allocator.free(self.status);
        allocator.free(self.extra);
    }
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    kubeconfig_path: []u8,
    context: []u8,
    host: ?*const config.Host = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: *const config.Host, context: []const u8) !Backend {
        const kcfg = try util.expandHome(allocator, host.kubeconfig);
        return .{
            .allocator = allocator,
            .io = io,
            .kubeconfig_path = kcfg,
            .context = try allocator.dupe(u8, context),
            .host = host,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.allocator.free(self.kubeconfig_path);
        self.allocator.free(self.context);
    }

    pub fn setContext(self: *Backend, context: []const u8) !void {
        self.allocator.free(self.context);
        self.context = try self.allocator.dupe(u8, context);
    }

    pub fn listContexts(self: *Backend) ![][]u8 {
        const argv = try self.buildKubectl(&.{ "config", "get-contexts", "-o", "name" });
        defer freeArgv(self.allocator, argv);
        const out = self.runCapture(argv) catch return try self.allocator.alloc([]u8, 0);
        defer self.allocator.free(out);
        var items: std.ArrayList([]u8) = .empty;
        errdefer {
            for (items.items) |c| self.allocator.free(c);
            items.deinit(self.allocator);
        }
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            try items.append(self.allocator, try self.allocator.dupe(u8, t));
        }
        return items.toOwnedSlice(self.allocator);
    }

    pub fn list(self: *Backend, kind: ResourceKind) ![]Row {
        const resource = switch (kind) {
            .pods => "pods",
            .nodes => "nodes",
            .deployments => "deployments",
            .services => "services",
            .namespaces => "namespaces",
        };
        const all_ns = kind != .namespaces and kind != .nodes;
        var args_buf: [8][]const u8 = undefined;
        var n: usize = 0;
        args_buf[n] = "get";
        n += 1;
        args_buf[n] = resource;
        n += 1;
        if (all_ns) {
            args_buf[n] = "-A";
            n += 1;
        }
        args_buf[n] = "-o";
        n += 1;
        args_buf[n] = "custom-columns=NAME:.metadata.name,NS:.metadata.namespace,STATUS:.status.phase,EXTRA:.metadata.creationTimestamp";
        n += 1;
        args_buf[n] = "--no-headers";
        n += 1;

        const argv = try self.buildKubectl(args_buf[0..n]);
        defer freeArgv(self.allocator, argv);
        const out = self.runCapture(argv) catch return try self.allocator.alloc(Row, 0);
        defer self.allocator.free(out);
        return parseRows(self.allocator, out);
    }

    pub fn logs(self: *Backend, ns: []const u8, name: []const u8, tail: u32) ![]u8 {
        var tail_buf: [16]u8 = undefined;
        const tail_s = try std.fmt.bufPrint(&tail_buf, "{d}", .{tail});
        const argv = try self.buildKubectl(&.{ "logs", "-n", ns, name, "--tail", tail_s });
        defer freeArgv(self.allocator, argv);
        return self.runCapture(argv);
    }

    pub fn describe(self: *Backend, kind: ResourceKind, ns: []const u8, name: []const u8) ![]u8 {
        const resource = @tagName(kind);
        if (ns.len > 0 and kind != .nodes and kind != .namespaces) {
            const argv = try self.buildKubectl(&.{ "describe", resource, "-n", ns, name });
            defer freeArgv(self.allocator, argv);
            return self.runCapture(argv);
        }
        const argv = try self.buildKubectl(&.{ "describe", resource, name });
        defer freeArgv(self.allocator, argv);
        return self.runCapture(argv);
    }

    pub fn delete(self: *Backend, kind: ResourceKind, ns: []const u8, name: []const u8) ![]u8 {
        const resource = @tagName(kind);
        if (ns.len > 0 and kind != .nodes and kind != .namespaces) {
            const argv = try self.buildKubectl(&.{ "delete", resource, "-n", ns, name });
            defer freeArgv(self.allocator, argv);
            return self.runCapture(argv);
        }
        const argv = try self.buildKubectl(&.{ "delete", resource, name });
        defer freeArgv(self.allocator, argv);
        return self.runCapture(argv);
    }

    pub fn k0sStatus(self: *Backend) ![]u8 {
        const argv = try self.buildRemote(&.{ "k0s", "status" });
        defer freeArgv(self.allocator, argv);
        return self.runCapture(argv);
    }

    pub fn k0sctl(self: *Backend, args: []const []const u8) ![]u8 {
        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(self.allocator);
        try argv_list.append(self.allocator, "k0sctl");
        try argv_list.appendSlice(self.allocator, args);
        const owned = try dupArgv(self.allocator, argv_list.items);
        defer freeArgv(self.allocator, owned);
        // k0sctl usually runs locally against remote inventory
        return self.runCaptureDirect(owned);
    }

    fn buildKubectl(self: *Backend, rest: []const []const u8) ![]const []const u8 {
        var argv_list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (argv_list.items) |a| self.allocator.free(a);
            argv_list.deinit(self.allocator);
        }
        try self.prependSsh(&argv_list);
        try argv_list.append(self.allocator, try self.allocator.dupe(u8, "kubectl"));
        try argv_list.append(self.allocator, try self.allocator.dupe(u8, "--kubeconfig"));
        try argv_list.append(self.allocator, try self.allocator.dupe(u8, self.kubeconfig_path));
        if (self.context.len > 0) {
            try argv_list.append(self.allocator, try self.allocator.dupe(u8, "--context"));
            try argv_list.append(self.allocator, try self.allocator.dupe(u8, self.context));
        }
        for (rest) |r| try argv_list.append(self.allocator, try self.allocator.dupe(u8, r));
        return argv_list.toOwnedSlice(self.allocator);
    }

    fn buildRemote(self: *Backend, rest: []const []const u8) ![]const []const u8 {
        var argv_list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (argv_list.items) |a| self.allocator.free(a);
            argv_list.deinit(self.allocator);
        }
        try self.prependSsh(&argv_list);
        for (rest) |r| try argv_list.append(self.allocator, try self.allocator.dupe(u8, r));
        return argv_list.toOwnedSlice(self.allocator);
    }

    fn prependSsh(self: *Backend, argv_list: *std.ArrayList([]const u8)) !void {
        const h = self.host orelse return;
        if (h.kind != .ssh or h.ssh.host.len == 0) return;
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

    fn runCapture(self: *Backend, argv: []const []const u8) ![]u8 {
        return self.runCaptureDirect(argv);
    }

    fn runCaptureDirect(self: *Backend, argv: []const []const u8) ![]u8 {
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
                return try std.fmt.allocPrint(self.allocator, "failed: {s}", .{result.stderr});
            },
        }
    }
};

fn parseRows(allocator: std.mem.Allocator, text: []const u8) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        const name = cols.next() orelse continue;
        const ns = cols.next() orelse "<none>";
        const status = cols.next() orelse "";
        const extra = cols.rest();
        try rows.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .namespace = try allocator.dupe(u8, if (std.mem.eql(u8, ns, "<none>")) "" else ns),
            .status = try allocator.dupe(u8, status),
            .extra = try allocator.dupe(u8, std.mem.trim(u8, extra, " \t\r")),
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

fn dupArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(out);
    for (argv, 0..) |a, i| out[i] = try allocator.dupe(u8, a);
    return out;
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |*r| r.deinit(allocator);
    allocator.free(rows);
}

pub fn freeContexts(allocator: std.mem.Allocator, ctxs: [][]u8) void {
    for (ctxs) |c| allocator.free(c);
    allocator.free(ctxs);
}
