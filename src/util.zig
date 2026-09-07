const std = @import("std");

pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

pub fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '~') {
        const home = getenv("HOME") orelse return allocator.dupe(u8, path);
        if (path.len == 1) return allocator.dupe(u8, home);
        if (path[1] == '/') {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
        }
    }
    return allocator.dupe(u8, path);
}

pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/tower", .{xdg});
    }
    const home = getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/tower", .{home});
}

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/config.yaml", .{dir});
}

/// Strip CSI / OSC sequences so SSH output can sit inside ZigZag views.
pub fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1b) {
            i += 1;
            if (i >= input.len) break;
            if (input[i] == '[') {
                i += 1;
                while (i < input.len) : (i += 1) {
                    const c = input[i];
                    if ((c >= '@' and c <= '~')) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }
            if (input[i] == ']') {
                i += 1;
                while (i < input.len) : (i += 1) {
                    if (input[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
                continue;
            }
            if (input[i] == '(' or input[i] == ')') {
                i += 2;
                continue;
            }
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

test "stripAnsi removes csi" {
    const allocator = std.testing.allocator;
    const cleaned = try stripAnsi(allocator, "\x1b[31mred\x1b[0m");
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings("red", cleaned);
}
