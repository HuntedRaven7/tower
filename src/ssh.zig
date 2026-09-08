const std = @import("std");
const config = @import("config.zig");
const util = @import("util.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: ?std.process.Child = null,
    output: std.ArrayList(u8),
    alive: bool = false,
    last_error: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Session {
        return .{
            .allocator = allocator,
            .io = io,
            .output = .empty,
            .last_error = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *Session) void {
        self.stop();
        self.output.deinit(self.allocator);
        self.allocator.free(self.last_error);
    }

    pub fn start(self: *Session, host: *const config.Host) !void {
        self.stop();
        self.output.clearRetainingCapacity();

        var argv: std.ArrayList([]const u8) = .empty;
        defer {
            for (argv.items) |a| self.allocator.free(a);
            argv.deinit(self.allocator);
        }

        if (host.kind == .local) {
            const shell = util.getenv("SHELL") orelse "/bin/bash";
            try argv.append(self.allocator, try self.allocator.dupe(u8, shell));
            try argv.append(self.allocator, try self.allocator.dupe(u8, "-l"));
        } else {
            try argv.append(self.allocator, try self.allocator.dupe(u8, "ssh"));
            try argv.append(self.allocator, try self.allocator.dupe(u8, "-tt"));
            if (host.ssh.port != 22) {
                try argv.append(self.allocator, try self.allocator.dupe(u8, "-p"));
                try argv.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{host.ssh.port}));
            }
            if (host.ssh.identity_file.len > 0) {
                try argv.append(self.allocator, try self.allocator.dupe(u8, "-i"));
                try argv.append(self.allocator, try util.expandHome(self.allocator, host.ssh.identity_file));
            }
            const target = if (host.ssh.user.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ host.ssh.user, host.ssh.host })
            else
                try self.allocator.dupe(u8, host.ssh.host);
            try argv.append(self.allocator, target);
        }

        // Dup argv for spawn lifetime (child may need pointers until wait)
        const spawn_argv = try self.allocator.alloc([]const u8, argv.items.len);
        errdefer self.allocator.free(spawn_argv);
        for (argv.items, 0..) |a, i| spawn_argv[i] = try self.allocator.dupe(u8, a);

        const child = std.process.spawn(self.io, .{
            .argv = spawn_argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            for (spawn_argv) |a| self.allocator.free(a);
            self.allocator.free(spawn_argv);
            self.setError(try std.fmt.allocPrint(self.allocator, "ssh spawn failed: {s}", .{@errorName(err)}));
            try self.output.appendSlice(self.allocator, self.last_error);
            try self.output.append(self.allocator, '\n');
            return err;
        };

        // Keep argv alive on the session via output note; free after stop.
        // Store argv pointer in a side channel by appending marker — simpler: leak until stop via child userdata.
        // Free spawn_argv immediately after spawn — process has copied args on POSIX.
        for (spawn_argv) |a| self.allocator.free(a);
        self.allocator.free(spawn_argv);

        self.child = child;
        self.alive = true;
        const banner = if (host.kind == .local)
            try std.fmt.allocPrint(self.allocator, "[tower] local shell on {s}\n", .{host.name})
        else
            try std.fmt.allocPrint(self.allocator, "[tower] ssh {s}@{s}\n", .{ host.ssh.user, host.ssh.host });
        defer self.allocator.free(banner);
        try self.output.appendSlice(self.allocator, banner);
    }

    pub fn startCommand(self: *Session, argv: []const []const u8) !void {
        self.stop();
        self.output.clearRetainingCapacity();

        const spawn_argv = try self.allocator.alloc([]const u8, argv.len);
        errdefer self.allocator.free(spawn_argv);
        for (argv, 0..) |a, i| spawn_argv[i] = try self.allocator.dupe(u8, a);

        const child = std.process.spawn(self.io, .{
            .argv = spawn_argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            for (spawn_argv) |a| self.allocator.free(a);
            self.allocator.free(spawn_argv);
            self.setError(try std.fmt.allocPrint(self.allocator, "exec spawn failed: {s}", .{@errorName(err)}));
            try self.output.appendSlice(self.allocator, self.last_error);
            try self.output.append(self.allocator, '\n');
            return err;
        };

        for (spawn_argv) |a| self.allocator.free(a);
        self.allocator.free(spawn_argv);

        self.child = child;
        self.alive = true;
        try self.output.appendSlice(self.allocator, "[tower] exec session\n");
    }

    pub fn stop(self: *Session) void {
        if (self.child) |*c| {
            c.kill(self.io);
            self.child = null;
        }
        self.alive = false;
    }

    pub fn write(self: *Session, bytes: []const u8) !void {
        const child = &(self.child orelse return error.NotConnected);
        const stdin = child.stdin orelse return error.NotConnected;
        var buf: [256]u8 = undefined;
        var w = stdin.writer(self.io, &buf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    pub fn poll(self: *Session) void {
        const child = &(self.child orelse return);
        self.drain(child.stdout);
        self.drain(child.stderr);
    }

    fn drain(self: *Session, maybe_file: ?std.Io.File) void {
        const file = maybe_file orelse return;
        var buf: [4096]u8 = undefined;
        // Best-effort non-blocking-ish read: use reader with short timeout if available.
        var reader_buf: [512]u8 = undefined;
        var r = file.reader(self.io, &reader_buf);
        while (true) {
            const n = r.interface.readSliceShort(buf[0..]) catch break;
            if (n == 0) break;
            self.output.appendSlice(self.allocator, buf[0..n]) catch break;
            if (self.output.items.len > 512 * 1024) {
                const keep = self.output.items[self.output.items.len - 256 * 1024 ..];
                const copy = self.allocator.dupe(u8, keep) catch break;
                self.output.clearRetainingCapacity();
                self.output.appendSlice(self.allocator, copy) catch {};
                self.allocator.free(copy);
            }
            if (n < buf.len) break;
        }
    }

    pub fn displayText(self: *const Session, allocator: std.mem.Allocator) ![]u8 {
        const cleaned = try util.stripAnsi(allocator, self.output.items);
        // Keep last ~200 lines
        var count: usize = 0;
        var i = cleaned.len;
        while (i > 0) : (i -= 1) {
            if (cleaned[i - 1] == '\n') {
                count += 1;
                if (count > 200) break;
            }
        }
        const slice = cleaned[i..];
        const owned = try allocator.dupe(u8, slice);
        allocator.free(cleaned);
        return owned;
    }

    fn setError(self: *Session, msg: []u8) void {
        self.allocator.free(self.last_error);
        self.last_error = msg;
    }
};
