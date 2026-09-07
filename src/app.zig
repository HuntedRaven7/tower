const std = @import("std");
const zz = @import("zigzag");
const config = @import("config.zig");
const container = @import("container.zig");
const kube = @import("kube.zig");
const hermes = @import("hermes.zig");
const ssh = @import("ssh.zig");
const util = @import("util.zig");

pub const Focus = enum { hosts, main, split };
pub const SplitKind = enum { none, ssh, hermes, detail };
pub const Overlay = enum { none, help, command, filter, confirm };
pub const MainView = enum {
    containers,
    images,
    volumes,
    networks,
    pods,
    k8s_pods,
    k8s_nodes,
    k8s_deployments,
    k8s_services,
    k8s_namespaces,
    k0s,
};

pub const TableRow = struct {
    cols: [4][]const u8,
    id: []const u8,
    ns: []const u8 = "",
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    host_idx: usize = 0,
    focus: Focus = .main,
    split: SplitKind = .none,
    overlay: Overlay = .none,
    main_view: MainView = .containers,
    selected: usize = 0,
    scroll: usize = 0,
    filter_buf: [128]u8 = undefined,
    filter_len: usize = 0,
    cmd_buf: [256]u8 = undefined,
    cmd_len: usize = 0,
    status: []u8,
    detail: []u8,
    rows: std.ArrayList(TableRow),
    contexts: std.ArrayList([]u8),
    context_idx: usize = 0,
    confirm_action: ConfirmAction = .none,
    confirm_modal: zz.Modal = undefined,
    help_visible: bool = false,
    ssh_session: ssh.Session = undefined,
    hermes_client: ?hermes.Client = null,
    hermes_log: std.ArrayList(u8),
    hermes_input: [512]u8 = undefined,
    hermes_input_len: usize = 0,
    hermes_busy: bool = false,
    tmux_prefix: bool = false,
    engine_label: []u8,
    needs_refresh: bool = true,
    should_quit: bool = false,

    pub const ConfirmAction = union(enum) {
        none,
        container_rm: []const u8,
        container_stop: []const u8,
        kube_delete: struct { kind: kube.ResourceKind, ns: []const u8, name: []const u8 },
        k0sctl_reset,
    };

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, ctx: *zz.Context) !zz.Cmd(Msg) {
        const allocator = ctx.persistent_allocator;
        const io = ctx.io;
        const cfg = try config.loadOrCreate(allocator, io);
        const status = try allocator.dupe(u8, "tower ready — ? help  : commands  q quit");
        const engine_label = try allocator.dupe(u8, "auto");
        const session = try ssh.Session.init(allocator, io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .status = status,
            .detail = try allocator.dupe(u8, ""),
            .rows = .empty,
            .contexts = .empty,
            .confirm_modal = zz.Modal.init(),
            .ssh_session = session,
            .hermes_log = .empty,
            .engine_label = engine_label,
        };
        try self.refreshRows();
        return zz.Cmd(Msg).tickMs(200);
    }

    pub fn deinit(self: *Model) void {
        self.clearRows();
        for (self.contexts.items) |c| self.allocator.free(c);
        self.contexts.deinit(self.allocator);
        self.allocator.free(self.status);
        self.allocator.free(self.detail);
        self.allocator.free(self.engine_label);
        self.hermes_log.deinit(self.allocator);
        if (self.hermes_client) |*c| c.deinit();
        self.ssh_session.deinit();
        self.cfg.deinit();
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .tick => {
                if (self.split == .ssh) self.ssh_session.poll();
                if (self.needs_refresh) {
                    self.refreshRows() catch {};
                    self.needs_refresh = false;
                }
                if (self.should_quit) return .quit;
                return zz.Cmd(Msg).tickMs(200);
            },
            .key => |k| {
                if (self.overlay == .confirm and self.confirm_modal.isVisible()) {
                    self.confirm_modal.handleKey(k);
                    if (self.confirm_modal.getResult()) |res| {
                        switch (res) {
                            .button_pressed => |idx| {
                                if (idx == 0) self.runConfirm() catch {};
                                self.overlay = .none;
                                self.confirm_action = .none;
                            },
                            .dismissed => {
                                self.overlay = .none;
                                self.confirm_action = .none;
                            },
                        }
                    }
                    return zz.Cmd(Msg).tickMs(200);
                }

                if (self.overlay == .help) {
                    if (isChar(k, 'q') or isChar(k, '?') or isKey(k, .escape)) self.overlay = .none;
                    return zz.Cmd(Msg).tickMs(200);
                }

                if (self.overlay == .filter) {
                    self.handleFilterKey(k);
                    return zz.Cmd(Msg).tickMs(200);
                }

                if (self.overlay == .command) {
                    self.handleCommandKey(k);
                    return zz.Cmd(Msg).tickMs(200);
                }

                if (self.tmux_prefix) {
                    self.tmux_prefix = false;
                    self.handleTmuxKey(k);
                    return zz.Cmd(Msg).tickMs(200);
                }

                if (self.focus == .split and self.split == .ssh) {
                    if (isChar(k, 'q') and false) {} // never
                    if (isCtrl(k, 'b')) {
                        self.tmux_prefix = true;
                        return zz.Cmd(Msg).tickMs(200);
                    }
                    self.forwardSshKey(k);
                    return zz.Cmd(Msg).tickMs(200);
                }

                if (self.focus == .split and self.split == .hermes) {
                    if (isCtrl(k, 'c')) {
                        self.setStatus("hermes: interrupt requested");
                        self.hermes_busy = false;
                        return zz.Cmd(Msg).tickMs(200);
                    }
                    if (isCtrl(k, 'b')) {
                        self.tmux_prefix = true;
                        return zz.Cmd(Msg).tickMs(200);
                    }
                    self.handleHermesKey(k);
                    return zz.Cmd(Msg).tickMs(200);
                }

                return self.handleNormalKey(k);
            },
        }
    }

    fn handleNormalKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        if (isCtrl(k, 'b')) {
            self.tmux_prefix = true;
            self.setStatus("tmux prefix — % \" hjkl d");
            return zz.Cmd(Msg).tickMs(200);
        }
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => return .quit,
                '?' => {
                    self.overlay = .help;
                },
                ':' => {
                    self.overlay = .command;
                    self.cmd_len = 0;
                },
                '/' => {
                    self.overlay = .filter;
                    self.filter_len = 0;
                },
                'j' => self.moveSel(1),
                'k' => self.moveSel(-1),
                'g' => self.selected = 0,
                'G' => {
                    if (self.filteredCount() > 0) self.selected = self.filteredCount() - 1;
                },
                'h' => self.focus = .hosts,
                'l' => self.focus = .main,
                'r' => {
                    self.needs_refresh = true;
                    self.setStatus("refreshing…");
                },
                'i' => self.showInspect() catch {},
                'd' => self.promptDestructive(.stop),
                'x' => self.promptDestructive(.rm),
                '1' => self.setView(.containers),
                '2' => self.setView(.images),
                '3' => self.setView(.volumes),
                '4' => self.setView(.networks),
                '5' => self.setView(.pods),
                '6' => self.setView(.k8s_pods),
                '7' => self.setView(.k8s_nodes),
                '8' => self.setView(.k8s_deployments),
                '9' => self.setView(.k0s),
                else => {},
            },
            .up => self.moveSel(-1),
            .down => self.moveSel(1),
            .left => self.focus = .hosts,
            .right => self.focus = .main,
            .enter => {
                if (self.focus == .hosts) {
                    // host already selected via j/k on hosts — enter focuses main
                    self.focus = .main;
                    self.needs_refresh = true;
                } else {
                    self.showInspect() catch {};
                }
            },
            .escape => {
                if (self.split != .none) {
                    self.split = .none;
                    self.focus = .main;
                }
            },
            .page_down => self.moveSel(10),
            .page_up => self.moveSel(-10),
            else => {},
        }
        // Host list navigation when focused
        if (self.focus == .hosts) {
            switch (k.key) {
                .char => |c| switch (c) {
                    'j' => {
                        if (self.host_idx + 1 < self.cfg.hosts.items.len) {
                            self.host_idx += 1;
                            self.needs_refresh = true;
                        }
                    },
                    'k' => {
                        if (self.host_idx > 0) {
                            self.host_idx -= 1;
                            self.needs_refresh = true;
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
        return zz.Cmd(Msg).tickMs(200);
    }

    fn handleTmuxKey(self: *Model, k: zz.KeyEvent) void {
        switch (k.key) {
            .char => |c| switch (c) {
                '%' => {
                    self.split = .ssh;
                    self.focus = .split;
                    if (self.cfg.selectedOrFirst(self.host_idx)) |h| {
                        self.ssh_session.start(h) catch |err| {
                            self.setStatusFmt("ssh failed: {s}", .{@errorName(err)});
                        };
                    }
                    self.setStatus("split: ssh");
                },
                '"' => {
                    self.split = .hermes;
                    self.focus = .split;
                    self.ensureHermes() catch {};
                    self.setStatus("split: hermes");
                },
                'h' => self.focus = .hosts,
                'l' => self.focus = .main,
                'j', 'k' => self.focus = if (self.split != .none) .split else .main,
                'd' => {
                    self.split = .none;
                    self.focus = .main;
                    self.ssh_session.stop();
                    self.setStatus("pane closed");
                },
                else => self.setStatus("unknown tmux key"),
            },
            else => {},
        }
    }

    fn handleFilterKey(self: *Model, k: zz.KeyEvent) void {
        switch (k.key) {
            .escape => self.overlay = .none,
            .enter => {
                self.overlay = .none;
                self.selected = 0;
            },
            .backspace => {
                if (self.filter_len > 0) self.filter_len -= 1;
            },
            .char => |c| {
                if (c > 127) return;
                const ch: u8 = @intCast(c);
                if (self.filter_len < self.filter_buf.len) {
                    self.filter_buf[self.filter_len] = ch;
                    self.filter_len += 1;
                }
            },
            else => {},
        }
    }

    fn handleCommandKey(self: *Model, k: zz.KeyEvent) void {
        switch (k.key) {
            .escape => self.overlay = .none,
            .enter => {
                const cmd = self.cmd_buf[0..self.cmd_len];
                self.runColon(cmd);
                self.overlay = .none;
            },
            .backspace => {
                if (self.cmd_len > 0) self.cmd_len -= 1;
            },
            .char => |c| {
                if (c > 127) return;
                const ch: u8 = @intCast(c);
                if (self.cmd_len < self.cmd_buf.len) {
                    self.cmd_buf[self.cmd_len] = ch;
                    self.cmd_len += 1;
                }
            },
            else => {},
        }
    }

    fn handleHermesKey(self: *Model, k: zz.KeyEvent) void {
        switch (k.key) {
            .enter => {
                if (self.hermes_input_len == 0 or self.hermes_busy) return;
                const prompt = self.hermes_input[0..self.hermes_input_len];
                self.appendHermesLog("you", prompt) catch {};
                self.hermes_busy = true;
                self.sendHermes(prompt) catch |err| {
                    self.appendHermesLog("error", @errorName(err)) catch {};
                };
                self.hermes_busy = false;
                self.hermes_input_len = 0;
            },
            .backspace => {
                if (self.hermes_input_len > 0) self.hermes_input_len -= 1;
            },
            .char => |c| {
                if (c > 127) return;
                const ch: u8 = @intCast(c);
                if (self.hermes_input_len < self.hermes_input.len) {
                    self.hermes_input[self.hermes_input_len] = ch;
                    self.hermes_input_len += 1;
                }
            },
            .escape => {
                self.focus = .main;
            },
            else => {},
        }
    }

    fn forwardSshKey(self: *Model, k: zz.KeyEvent) void {
        var buf: [16]u8 = undefined;
        const bytes: []const u8 = switch (k.key) {
            .char => |c| blk: {
                if (c > 127) return;
                buf[0] = @intCast(c);
                break :blk buf[0..1];
            },
            .enter => "\r",
            .backspace => "\x7f",
            .tab => "\t",
            .up => "\x1b[A",
            .down => "\x1b[B",
            .right => "\x1b[C",
            .left => "\x1b[D",
            .escape => "\x1b",
            else => return,
        };
        self.ssh_session.write(bytes) catch {};
    }

    fn runColon(self: *Model, cmd: []const u8) void {
        const c = std.mem.trim(u8, cmd, " \t");
        if (c.len == 0) return;
        if (std.mem.eql(u8, c, "q") or std.mem.eql(u8, c, "quit")) {
            self.should_quit = true;
            self.setStatus("quitting…");
            return;
        }
        if (std.mem.eql(u8, c, "split") or std.mem.eql(u8, c, "ssh")) {
            self.handleTmuxKey(.{ .key = .{ .char = '%' }, .modifiers = .{} });
            return;
        }
        if (std.mem.eql(u8, c, "hermes")) {
            self.handleTmuxKey(.{ .key = .{ .char = '"' }, .modifiers = .{} });
            return;
        }
        if (std.mem.startsWith(u8, c, "host ")) {
            const name = std.mem.trim(u8, c["host ".len..], " \t");
            if (self.cfg.findHost(name)) |idx| {
                self.host_idx = idx;
                self.needs_refresh = true;
                self.setStatusFmt("host {s}", .{name});
            } else self.setStatusFmt("unknown host {s}", .{name});
            return;
        }
        if (std.mem.startsWith(u8, c, "ctx ") or std.mem.startsWith(u8, c, "context ")) {
            const name = if (std.mem.startsWith(u8, c, "ctx "))
                std.mem.trim(u8, c["ctx ".len..], " \t")
            else
                std.mem.trim(u8, c["context ".len..], " \t");
            for (self.contexts.items, 0..) |ctx_name, i| {
                if (std.mem.eql(u8, ctx_name, name)) {
                    self.context_idx = i;
                    self.needs_refresh = true;
                    self.setStatusFmt("context {s}", .{name});
                    return;
                }
            }
            self.setStatusFmt("unknown context {s}", .{name});
            return;
        }
        if (std.mem.eql(u8, c, "podman")) {
            self.setView(.containers);
            return;
        }
        if (std.mem.eql(u8, c, "docker")) {
            self.setView(.containers);
            return;
        }
        if (std.mem.eql(u8, c, "k0s")) {
            self.setView(.k0s);
            return;
        }
        if (std.mem.eql(u8, c, "pods")) {
            self.setView(.k8s_pods);
        } else if (std.mem.eql(u8, c, "nodes")) {
            self.setView(.k8s_nodes);
        } else if (std.mem.eql(u8, c, "deploy") or std.mem.eql(u8, c, "deployments")) {
            self.setView(.k8s_deployments);
        } else if (std.mem.eql(u8, c, "svc") or std.mem.eql(u8, c, "services")) {
            self.setView(.k8s_services);
        } else if (std.mem.eql(u8, c, "ns") or std.mem.eql(u8, c, "namespaces")) {
            self.setView(.k8s_namespaces);
        } else if (std.mem.eql(u8, c, "images")) {
            self.setView(.images);
        } else if (std.mem.eql(u8, c, "volumes")) {
            self.setView(.volumes);
        } else if (std.mem.eql(u8, c, "networks")) {
            self.setView(.networks);
        } else if (std.mem.eql(u8, c, "containers")) {
            self.setView(.containers);
        } else if (std.mem.eql(u8, c, "refresh")) {
            self.needs_refresh = true;
        } else {
            self.setStatusFmt("unknown :{s}", .{c});
        }
    }

    fn setView(self: *Model, v: MainView) void {
        self.main_view = v;
        self.selected = 0;
        self.needs_refresh = true;
        self.setStatusFmt("view {s}", .{@tagName(v)});
    }

    fn moveSel(self: *Model, delta: i32) void {
        const n = self.filteredCount();
        if (n == 0) return;
        if (delta < 0) {
            const d: usize = @intCast(-delta);
            if (self.selected > d) self.selected -= d else self.selected = 0;
        } else {
            const d: usize = @intCast(delta);
            if (self.selected + d < n) self.selected += d else self.selected = n - 1;
        }
    }

    fn filterText(self: *const Model) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    fn rowMatches(self: *const Model, row: TableRow) bool {
        const f = self.filterText();
        if (f.len == 0) return true;
        inline for (row.cols) |col| {
            if (std.ascii.indexOfIgnoreCase(col, f) != null) return true;
        }
        return std.ascii.indexOfIgnoreCase(row.id, f) != null;
    }

    fn filteredCount(self: *const Model) usize {
        var n: usize = 0;
        for (self.rows.items) |r| {
            if (self.rowMatches(r)) n += 1;
        }
        return n;
    }

    fn filteredRow(self: *const Model, idx: usize) ?TableRow {
        var n: usize = 0;
        for (self.rows.items) |r| {
            if (!self.rowMatches(r)) continue;
            if (n == idx) return r;
            n += 1;
        }
        return null;
    }

    fn clearRows(self: *Model) void {
        for (self.rows.items) |r| {
            for (r.cols) |c| self.allocator.free(c);
            self.allocator.free(r.id);
            if (r.ns.len > 0) self.allocator.free(r.ns);
        }
        self.rows.clearRetainingCapacity();
    }

    fn refreshRows(self: *Model) !void {
        self.clearRows();
        const host = self.cfg.selectedOrFirst(self.host_idx) orelse return;

        switch (self.main_view) {
            .containers, .images, .volumes, .networks, .pods => {
                var backend = try container.Backend.detect(self.allocator, self.io, host);
                self.allocator.free(self.engine_label);
                self.engine_label = try self.allocator.dupe(u8, @tagName(backend.engine));
                const kind: container.ResourceKind = switch (self.main_view) {
                    .containers => .containers,
                    .images => .images,
                    .volumes => .volumes,
                    .networks => .networks,
                    .pods => .pods,
                    else => unreachable,
                };
                const list = try backend.list(kind);
                defer container.freeRows(self.allocator, list);
                for (list) |r| {
                    try self.rows.append(self.allocator, .{
                        .cols = .{
                            try self.allocator.dupe(u8, util.truncate(r.id, 12)),
                            try self.allocator.dupe(u8, util.truncate(r.name, 32)),
                            try self.allocator.dupe(u8, util.truncate(r.status, 24)),
                            try self.allocator.dupe(u8, util.truncate(r.extra, 32)),
                        },
                        .id = try self.allocator.dupe(u8, r.id),
                    });
                }
            },
            .k8s_pods, .k8s_nodes, .k8s_deployments, .k8s_services, .k8s_namespaces => {
                const ctx_name = if (self.contexts.items.len > 0 and self.context_idx < self.contexts.items.len)
                    self.contexts.items[self.context_idx]
                else
                    "";
                var backend = try kube.Backend.init(self.allocator, self.io, host, ctx_name);
                defer backend.deinit();

                if (self.contexts.items.len == 0) {
                    const ctxs = try backend.listContexts();
                    defer kube.freeContexts(self.allocator, ctxs);
                    for (ctxs) |c| try self.contexts.append(self.allocator, try self.allocator.dupe(u8, c));
                }

                const kind: kube.ResourceKind = switch (self.main_view) {
                    .k8s_pods => .pods,
                    .k8s_nodes => .nodes,
                    .k8s_deployments => .deployments,
                    .k8s_services => .services,
                    .k8s_namespaces => .namespaces,
                    else => unreachable,
                };
                const list = try backend.list(kind);
                defer kube.freeRows(self.allocator, list);
                for (list) |r| {
                    try self.rows.append(self.allocator, .{
                        .cols = .{
                            try self.allocator.dupe(u8, util.truncate(r.name, 40)),
                            try self.allocator.dupe(u8, util.truncate(r.namespace, 20)),
                            try self.allocator.dupe(u8, util.truncate(r.status, 16)),
                            try self.allocator.dupe(u8, util.truncate(r.extra, 24)),
                        },
                        .id = try self.allocator.dupe(u8, r.name),
                        .ns = try self.allocator.dupe(u8, r.namespace),
                    });
                }
            },
            .k0s => {
                var backend = try kube.Backend.init(self.allocator, self.io, host, "");
                defer backend.deinit();
                const status = try backend.k0sStatus();
                defer self.allocator.free(status);
                self.allocator.free(self.detail);
                self.detail = try self.allocator.dupe(u8, status);
                try self.rows.append(self.allocator, .{
                    .cols = .{
                        try self.allocator.dupe(u8, "k0s status"),
                        try self.allocator.dupe(u8, ""),
                        try self.allocator.dupe(u8, "see detail"),
                        try self.allocator.dupe(u8, "i to inspect"),
                    },
                    .id = try self.allocator.dupe(u8, "k0s-status"),
                });
                try self.rows.append(self.allocator, .{
                    .cols = .{
                        try self.allocator.dupe(u8, "k0sctl apply"),
                        try self.allocator.dupe(u8, ""),
                        try self.allocator.dupe(u8, "lifecycle"),
                        try self.allocator.dupe(u8, ":k0s"),
                    },
                    .id = try self.allocator.dupe(u8, "k0sctl-apply"),
                });
            },
        }
        self.setStatusFmt("{s} · {d} rows", .{ @tagName(self.main_view), self.rows.items.len });
    }

    fn showInspect(self: *Model) !void {
        const row = self.filteredRow(self.selected) orelse return;
        const host = self.cfg.selectedOrFirst(self.host_idx) orelse return;
        self.split = .detail;
        self.focus = .split;

        const text = switch (self.main_view) {
            .containers, .images, .volumes, .networks, .pods => blk: {
                var backend = try container.Backend.detect(self.allocator, self.io, host);
                const kind: container.ResourceKind = switch (self.main_view) {
                    .containers => .containers,
                    .images => .images,
                    .volumes => .volumes,
                    .networks => .networks,
                    .pods => .pods,
                    else => unreachable,
                };
                if (self.main_view == .containers) {
                    break :blk try backend.logs(row.id, 100);
                }
                break :blk try backend.inspect(kind, row.id);
            },
            .k8s_pods, .k8s_nodes, .k8s_deployments, .k8s_services, .k8s_namespaces => blk: {
                const ctx_name = if (self.contexts.items.len > 0) self.contexts.items[self.context_idx] else "";
                var backend = try kube.Backend.init(self.allocator, self.io, host, ctx_name);
                defer backend.deinit();
                const kind: kube.ResourceKind = switch (self.main_view) {
                    .k8s_pods => .pods,
                    .k8s_nodes => .nodes,
                    .k8s_deployments => .deployments,
                    .k8s_services => .services,
                    .k8s_namespaces => .namespaces,
                    else => unreachable,
                };
                if (self.main_view == .k8s_pods) {
                    break :blk try backend.logs(row.ns, row.id, 100);
                }
                break :blk try backend.describe(kind, row.ns, row.id);
            },
            .k0s => try self.allocator.dupe(u8, self.detail),
        };
        self.allocator.free(self.detail);
        self.detail = text;
    }

    const DestructKind = enum { stop, rm };

    fn promptDestructive(self: *Model, kind: DestructKind) void {
        const row = self.filteredRow(self.selected) orelse return;
        switch (self.main_view) {
            .containers => {
                self.confirm_action = switch (kind) {
                    .stop => .{ .container_stop = row.id },
                    .rm => .{ .container_rm = row.id },
                };
                const title = if (kind == .stop) "Stop container?" else "Remove container?";
                const body = row.id;
                self.confirm_modal = zz.Modal.confirm(title, body);
                self.confirm_modal.backdrop = .{};
                self.confirm_modal.show();
                self.overlay = .confirm;
            },
            .k8s_pods, .k8s_deployments, .k8s_services => {
                const kkind: kube.ResourceKind = switch (self.main_view) {
                    .k8s_pods => .pods,
                    .k8s_deployments => .deployments,
                    .k8s_services => .services,
                    else => .pods,
                };
                self.confirm_action = .{ .kube_delete = .{ .kind = kkind, .ns = row.ns, .name = row.id } };
                self.confirm_modal = zz.Modal.confirm("Delete resource?", row.id);
                self.confirm_modal.backdrop = .{};
                self.confirm_modal.show();
                self.overlay = .confirm;
            },
            else => self.setStatus("no destructive action for this view"),
        }
    }

    fn runConfirm(self: *Model) !void {
        const host = self.cfg.selectedOrFirst(self.host_idx) orelse return;
        switch (self.confirm_action) {
            .none => {},
            .container_stop => |id| {
                var backend = try container.Backend.detect(self.allocator, self.io, host);
                const out = try backend.action(.containers, "stop", id);
                defer self.allocator.free(out);
                self.setStatusFmt("stopped {s}", .{id});
                self.needs_refresh = true;
            },
            .container_rm => |id| {
                var backend = try container.Backend.detect(self.allocator, self.io, host);
                const out = try backend.action(.containers, "rm", id);
                defer self.allocator.free(out);
                self.setStatusFmt("removed {s}", .{id});
                self.needs_refresh = true;
            },
            .kube_delete => |d| {
                const ctx_name = if (self.contexts.items.len > 0) self.contexts.items[self.context_idx] else "";
                var backend = try kube.Backend.init(self.allocator, self.io, host, ctx_name);
                defer backend.deinit();
                const out = try backend.delete(d.kind, d.ns, d.name);
                defer self.allocator.free(out);
                self.setStatusFmt("deleted {s}", .{d.name});
                self.needs_refresh = true;
            },
            .k0sctl_reset => {
                var backend = try kube.Backend.init(self.allocator, self.io, host, "");
                defer backend.deinit();
                const out = try backend.k0sctl(&.{"reset"});
                defer self.allocator.free(out);
                self.setStatus("k0sctl reset requested");
            },
        }
    }

    fn ensureHermes(self: *Model) !void {
        if (self.hermes_client != null) return;
        const host = self.cfg.selectedOrFirst(self.host_idx) orelse return;
        self.hermes_client = try hermes.Client.initFromHost(self.allocator, self.io, host);
        try self.hermes_log.appendSlice(self.allocator, "hermes ready — type a message and Enter\n");
    }

    fn sendHermes(self: *Model, prompt: []const u8) !void {
        try self.ensureHermes();
        var client = &(self.hermes_client orelse return);
        const messages = [_]hermes.Message{.{ .role = "user", .content = prompt }};
        const reply = try client.chat(&messages);
        defer self.allocator.free(reply);
        try self.appendHermesLog("hermes", reply);
    }

    fn appendHermesLog(self: *Model, who: []const u8, text: []const u8) !void {
        try self.hermes_log.appendSlice(self.allocator, who);
        try self.hermes_log.appendSlice(self.allocator, ": ");
        try self.hermes_log.appendSlice(self.allocator, text);
        try self.hermes_log.append(self.allocator, '\n');
    }

    fn setStatus(self: *Model, msg: []const u8) void {
        self.allocator.free(self.status);
        self.status = self.allocator.dupe(u8, msg) catch {
            self.status = self.allocator.alloc(u8, 0) catch return;
            return;
        };
    }

    fn setStatusFmt(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.allocator.free(self.status);
        self.status = msg;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        const alloc = ctx.allocator;
        if (self.overlay == .confirm and self.confirm_modal.isVisible()) {
            return self.confirm_modal.viewWithBackdrop(alloc, ctx.width, ctx.height);
        }
        if (self.overlay == .help) return try renderHelp(alloc, ctx.width, ctx.height);

        const areas = try zz.flex.layout(alloc, @intCast(ctx.width), @intCast(ctx.height), &.{
            .{ .constraint = .{ .fixed = 1 } }, // title
            .{ .constraint = .fill }, // body
            .{ .constraint = .{ .fixed = 1 } }, // status
            .{ .constraint = .{ .fixed = if (self.overlay == .command or self.overlay == .filter) 1 else 0 } },
        }, .{ .direction = .column, .gap = 0 });

        const title = try renderTitle(self, alloc, areas[0].width);
        const body = try renderBody(self, alloc, areas[1].width, areas[1].height);
        const status = try renderStatus(self, alloc, areas[2].width);

        if (self.overlay == .command or self.overlay == .filter) {
            const prompt = try renderPrompt(self, alloc, areas[3].width);
            return zz.joinVertical(alloc, &.{ title, body, status, prompt });
        }
        return zz.joinVertical(alloc, &.{ title, body, status });
    }
};

fn renderTitle(self: *const Model, alloc: std.mem.Allocator, width: usize) ![]const u8 {
    _ = width;
    var style = zz.Style{};
    style = style.bold(true).fg(zz.Color.cyan).inline_style(true);
    const host = if (self.cfg.selectedOrFirst(self.host_idx)) |h| h.name else "-";
    const ctx = if (self.contexts.items.len > 0 and self.context_idx < self.contexts.items.len)
        self.contexts.items[self.context_idx]
    else
        "-";
    const text = try std.fmt.allocPrint(alloc, " tower  host:{s}  engine:{s}  ctx:{s}  view:{s}  focus:{s} ", .{
        host,
        self.engine_label,
        ctx,
        @tagName(self.main_view),
        @tagName(self.focus),
    });
    return style.render(alloc, text);
}

fn renderStatus(self: *const Model, alloc: std.mem.Allocator, width: usize) ![]const u8 {
    _ = width;
    var style = zz.Style{};
    style = style.fg(zz.Color.gray(12)).inline_style(true);
    return style.render(alloc, self.status);
}

fn renderPrompt(self: *const Model, alloc: std.mem.Allocator, width: usize) ![]const u8 {
    _ = width;
    var style = zz.Style{};
    style = style.fg(zz.Color.yellow).inline_style(true);
    if (self.overlay == .command) {
        const text = try std.fmt.allocPrint(alloc, ":{s}", .{self.cmd_buf[0..self.cmd_len]});
        return style.render(alloc, text);
    }
    const text = try std.fmt.allocPrint(alloc, "/{s}", .{self.filter_buf[0..self.filter_len]});
    return style.render(alloc, text);
}

fn renderBody(self: *const Model, alloc: std.mem.Allocator, width: usize, height: usize) ![]const u8 {
    const w = @max(width, 20);
    const h = @max(height, 3);
    const host_w: usize = @min(22, w / 4);
    const split_on = self.split != .none;
    const main_w = if (split_on) (w -| host_w -| 1) / 2 else w -| host_w -| 1;
    const split_w = if (split_on) w -| host_w -| main_w -| 2 else 0;

    const hosts = try renderHosts(self, alloc, host_w, h);
    const main = try renderMain(self, alloc, @max(main_w, 10), h);

    if (!split_on) {
        return zz.joinHorizontal(alloc, &.{ hosts, "│", main });
    }
    const split = try renderSplit(self, alloc, @max(split_w, 10), h);
    return zz.joinHorizontal(alloc, &.{ hosts, "│", main, "│", split });
}

fn renderHosts(self: *const Model, alloc: std.mem.Allocator, width: usize, height: usize) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);

    var header_s = zz.Style{};
    header_s = header_s.bold(true).fg(zz.Color.magenta).inline_style(true);
    try lines.append(alloc, try header_s.render(alloc, pad("HOSTS", width)));

    for (self.cfg.hosts.items, 0..) |h, i| {
        const selected = i == self.host_idx;
        const focused = self.focus == .hosts and selected;
        var s = zz.Style{};
        if (focused) {
            s = s.bold(true).fg(zz.Color.black).bg(zz.Color.cyan).inline_style(true);
        } else if (selected) {
            s = s.fg(zz.Color.cyan).inline_style(true);
        } else {
            s = s.fg(zz.Color.gray(14)).inline_style(true);
        }
        const mark = if (selected) ">" else " ";
        const label = try std.fmt.allocPrint(alloc, "{s}{s}", .{ mark, h.name });
        try lines.append(alloc, try s.render(alloc, pad(label, width)));
    }

    try lines.append(alloc, try padLine(alloc, "", width));
    var hint_s = zz.Style{};
    hint_s = hint_s.fg(zz.Color.gray(10)).inline_style(true);
    try lines.append(alloc, try hint_s.render(alloc, pad("1-5 ctr 6-9 k8s", width)));

    while (lines.items.len < height) try lines.append(alloc, try padLine(alloc, "", width));
    return zz.joinVertical(alloc, lines.items[0..@min(lines.items.len, height)]);
}

fn renderMain(self: *const Model, alloc: std.mem.Allocator, width: usize, height: usize) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);

    var header_s = zz.Style{};
    header_s = header_s.bold(true).fg(zz.Color.green).inline_style(true);
    const headers = switch (self.main_view) {
        .containers, .images, .volumes, .networks, .pods => "ID/NAME          NAME/REPO                      STATUS                   EXTRA",
        else => "NAME                                    NS                   STATUS           EXTRA",
    };
    try lines.append(alloc, try header_s.render(alloc, pad(headers, width)));

    var shown: usize = 0;
    var idx: usize = 0;
    for (self.rows.items) |r| {
        if (!self.rowMatches(r)) continue;
        if (shown >= height -| 1) break;
        const selected = idx == self.selected;
        var s = zz.Style{};
        if (selected and self.focus == .main) {
            s = s.bold(true).fg(zz.Color.black).bg(zz.Color.green).inline_style(true);
        } else if (selected) {
            s = s.fg(zz.Color.green).inline_style(true);
        } else {
            s = s.inline_style(true);
        }
        const line = try std.fmt.allocPrint(alloc, "{s:<16} {s:<28} {s:<22} {s}", .{
            util.truncate(r.cols[0], 16),
            util.truncate(r.cols[1], 28),
            util.truncate(r.cols[2], 22),
            util.truncate(r.cols[3], 24),
        });
        try lines.append(alloc, try s.render(alloc, pad(line, width)));
        shown += 1;
        idx += 1;
    }
    if (shown == 0) {
        var empty_s = zz.Style{};
        empty_s = empty_s.fg(zz.Color.gray(10)).inline_style(true);
        try lines.append(alloc, try empty_s.render(alloc, pad("(no resources — press r to refresh)", width)));
    }
    while (lines.items.len < height) try lines.append(alloc, try padLine(alloc, "", width));
    return zz.joinVertical(alloc, lines.items[0..@min(lines.items.len, height)]);
}

fn renderSplit(self: *const Model, alloc: std.mem.Allocator, width: usize, height: usize) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var header_s = zz.Style{};
    header_s = header_s.bold(true).fg(zz.Color.yellow).inline_style(true);

    const title = switch (self.split) {
        .ssh => "SSH",
        .hermes => "HERMES",
        .detail => "DETAIL",
        .none => "",
    };
    try lines.append(alloc, try header_s.render(alloc, pad(title, width)));

    const content: []const u8 = switch (self.split) {
        .ssh => try self.ssh_session.displayText(alloc),
        .hermes => blk: {
            const input = try std.fmt.allocPrint(alloc, "\n> {s}", .{self.hermes_input[0..self.hermes_input_len]});
            break :blk try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.hermes_log.items, input });
        },
        .detail => self.detail,
        .none => "",
    };

    var content_lines = std.mem.splitScalar(u8, content, '\n');
    var buf: std.ArrayList([]const u8) = .empty;
    defer buf.deinit(alloc);
    while (content_lines.next()) |ln| try buf.append(alloc, ln);
    const start = if (buf.items.len + 1 > height) buf.items.len - (height - 1) else 0;
    var body_s = zz.Style{};
    body_s = body_s.inline_style(true);
    for (buf.items[start..]) |ln| {
        if (lines.items.len >= height) break;
        try lines.append(alloc, try body_s.render(alloc, pad(util.truncate(ln, width), width)));
    }
    while (lines.items.len < height) try lines.append(alloc, try padLine(alloc, "", width));
    return zz.joinVertical(alloc, lines.items[0..@min(lines.items.len, height)]);
}

fn renderHelp(alloc: std.mem.Allocator, width: usize, height: usize) ![]const u8 {
    const text =
        \\tower help
        \\
        \\Navigation   hjkl  g/G  Enter  Esc
        \\Filter       /text
        \\Commands     :host NAME  :ctx NAME  :pods :nodes :containers :images
        \\             :ssh :hermes :k0s :refresh :q
        \\Panes        Ctrl-b %  ssh split
        \\             Ctrl-b "  hermes split
        \\             Ctrl-b d  close pane
        \\Actions      i inspect/logs   d stop   x delete (confirm)
        \\             r refresh   ? help   q quit
        \\Views        1-5 containers/images/volumes/networks/pods
        \\             6-9 k8s pods/nodes/deployments/k0s
        \\
        \\press ? or Esc to close
    ;
    var style = zz.Style{};
    style = style.borderAll(zz.Border.rounded).borderForeground(zz.Color.cyan).paddingAll(1);
    const boxed = try style.render(alloc, text);
    return zz.place.place(alloc, width, height, .center, .middle, boxed);
}

fn pad(text: []const u8, width: usize) []const u8 {
    _ = width;
    return text;
}

fn padLine(alloc: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    if (text.len >= width) return alloc.dupe(u8, text[0..width]);
    var buf = try alloc.alloc(u8, width);
    @memset(buf, ' ');
    @memcpy(buf[0..text.len], text);
    return buf;
}

fn isChar(k: zz.KeyEvent, c: u8) bool {
    return switch (k.key) {
        .char => |ch| ch == c,
        .space => c == ' ',
        else => false,
    };
}

fn isKey(k: zz.KeyEvent, comptime tag: anytype) bool {
    return std.meta.activeTag(k.key) == tag;
}

fn isCtrl(k: zz.KeyEvent, c: u8) bool {
    if (k.modifiers.ctrl and isChar(k, c)) return true;
    if (c >= 'a' and c <= 'z') {
        const code = c - 'a' + 1;
        return isChar(k, code);
    }
    return false;
}
