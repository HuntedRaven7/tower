const std = @import("std");
const zz = @import("zigzag");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    var program = zz.Program(app.Model).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();
    try program.run();
}
