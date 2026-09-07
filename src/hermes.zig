const std = @import("std");
const config = @import("config.zig");
const util = @import("util.zig");

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []u8,
    api_key: []u8,

    pub fn initFromHost(allocator: std.mem.Allocator, io: std.Io, host: *const config.Host) !Client {
        const key = blk: {
            var name_buf: [128]u8 = undefined;
            if (host.hermes.api_key_env.len >= name_buf.len) break :blk try allocator.dupe(u8, "");
            @memcpy(name_buf[0..host.hermes.api_key_env.len], host.hermes.api_key_env);
            name_buf[host.hermes.api_key_env.len] = 0;
            const zname: [:0]const u8 = name_buf[0..host.hermes.api_key_env.len :0];
            if (util.getenv(zname)) |v| break :blk try allocator.dupe(u8, v);
            break :blk try allocator.dupe(u8, "");
        };
        return .{
            .allocator = allocator,
            .io = io,
            .base_url = try allocator.dupe(u8, host.hermes.base_url),
            .api_key = key,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
    }

    pub fn health(self: *Client) bool {
        const url = self.joinUrl("/../health") catch return false;
        defer self.allocator.free(url);
        const out = self.curlGet(url) catch return false;
        defer self.allocator.free(out);
        return out.len > 0;
    }

    pub fn listSessions(self: *Client) ![][]u8 {
        const url = try self.joinUrl("/../api/sessions");
        defer self.allocator.free(url);
        const out = self.curlGet(url) catch return try self.allocator.alloc([]u8, 0);
        defer self.allocator.free(out);
        // Best-effort: extract "id" or "title" strings from JSON-ish text.
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| self.allocator.free(s);
            list.deinit(self.allocator);
        }
        var start: ?usize = null;
        for (out, 0..) |c, i| {
            if (c == '"') {
                if (start) |s| {
                    const slice = out[s + 1 .. i];
                    if (slice.len > 8 and slice.len < 80) {
                        try list.append(self.allocator, try self.allocator.dupe(u8, slice));
                        if (list.items.len >= 32) break;
                    }
                    start = null;
                } else start = i;
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn chat(self: *Client, messages: []const Message) ![]u8 {
        const url = try self.joinUrl("/chat/completions");
        defer self.allocator.free(url);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, "{\"model\":\"hermes-agent\",\"messages\":[");
        for (messages, 0..) |m, i| {
            if (i > 0) try body.append(self.allocator, ',');
            try body.appendSlice(self.allocator, "{\"role\":\"");
            try appendEscaped(&body, self.allocator, m.role);
            try body.appendSlice(self.allocator, "\",\"content\":\"");
            try appendEscaped(&body, self.allocator, m.content);
            try body.appendSlice(self.allocator, "\"}");
        }
        try body.appendSlice(self.allocator, "]}");

        const raw = try self.curlPost(url, body.items);
        defer self.allocator.free(raw);
        return extractAssistantContent(self.allocator, raw);
    }

    pub fn interruptHint(_: *Client) []const u8 {
        return "Send another message or restart the Hermes run from the agent UI.";
    }

    fn joinUrl(self: *Client, suffix: []const u8) ![]u8 {
        // base_url is like http://127.0.0.1:8642/v1
        if (std.mem.startsWith(u8, suffix, "/../")) {
            // Go up from /v1
            if (std.mem.lastIndexOfScalar(u8, self.base_url, '/')) |idx| {
                return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url[0..idx], suffix[3..] });
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, suffix });
    }

    fn curlGet(self: *Client, url: []const u8) ![]u8 {
        return self.curl(url, null);
    }

    fn curlPost(self: *Client, url: []const u8, body: []const u8) ![]u8 {
        return self.curl(url, body);
    }

    fn curl(self: *Client, url: []const u8, body: ?[]const u8) ![]u8 {
        var owned: std.ArrayList([]const u8) = .empty;
        defer {
            for (owned.items) |a| self.allocator.free(a);
            owned.deinit(self.allocator);
        }
        try owned.append(self.allocator, try self.allocator.dupe(u8, "curl"));
        try owned.append(self.allocator, try self.allocator.dupe(u8, "-sS"));
        try owned.append(self.allocator, try self.allocator.dupe(u8, "--max-time"));
        try owned.append(self.allocator, try self.allocator.dupe(u8, "120"));
        if (self.api_key.len > 0) {
            try owned.append(self.allocator, try self.allocator.dupe(u8, "-H"));
            try owned.append(self.allocator, try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.api_key}));
        }
        try owned.append(self.allocator, try self.allocator.dupe(u8, "-H"));
        try owned.append(self.allocator, try self.allocator.dupe(u8, "Content-Type: application/json"));
        if (body) |b| {
            try owned.append(self.allocator, try self.allocator.dupe(u8, "-d"));
            try owned.append(self.allocator, try self.allocator.dupe(u8, b));
        }
        try owned.append(self.allocator, try self.allocator.dupe(u8, url));

        const result = std.process.run(self.allocator, self.io, .{
            .argv = owned.items,
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(256 * 1024),
        }) catch |err| {
            return std.fmt.allocPrint(self.allocator, "hermes curl error: {s}", .{@errorName(err)});
        };
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| {
                if (code == 0) return result.stdout;
                defer self.allocator.free(result.stdout);
                if (result.stderr.len > 0) return try self.allocator.dupe(u8, result.stderr);
                return try std.fmt.allocPrint(self.allocator, "hermes HTTP exit {d}", .{code});
            },
            else => {
                defer self.allocator.free(result.stdout);
                return try std.fmt.allocPrint(self.allocator, "hermes failed: {s}", .{result.stderr});
            },
        }
    }
};

fn appendEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

fn extractAssistantContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Find "content":"..." in choices[0].message — naive but workable.
    const key = "\"content\":\"";
    if (std.mem.indexOf(u8, raw, key)) |idx| {
        const start = idx + key.len;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i = start;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                const n = raw[i + 1];
                const decoded: u8 = switch (n) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '"' => '"',
                    '\\' => '\\',
                    else => n,
                };
                try out.append(allocator, decoded);
                i += 1;
                continue;
            }
            if (raw[i] == '"') break;
            try out.append(allocator, raw[i]);
        }
        return out.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, raw);
}

pub fn freeSessions(allocator: std.mem.Allocator, sessions: [][]u8) void {
    for (sessions) |s| allocator.free(s);
    allocator.free(sessions);
}
