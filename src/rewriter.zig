const std = @import("std");
const Io = std.Io;

pub fn rewriteFile(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    line_num: u32,
    col_byte: u32,
    old_word: []const u8,
    new_word: []const u8,
) !void {
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    var rbuf: [65536]u8 = undefined;
    var reader = Io.File.Reader.init(file, io, &rbuf);
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);
    try reader.interface.appendRemaining(allocator, &content, .unlimited);
    file.close(io);

    // find the line
    var current_line: u32 = 1;
    var line_start: usize = 0;
    for (content.items, 0..) |c, i| {
        if (current_line == line_num) break;
        if (c == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }

    const target_start = line_start + col_byte;
    if (target_start + old_word.len > content.items.len) return;
    if (!std.mem.eql(u8, content.items[target_start .. target_start + old_word.len], old_word)) return;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, content.items[0..target_start]);
    try out.appendSlice(allocator, new_word);
    try out.appendSlice(allocator, content.items[target_start + old_word.len ..]);

    const out_file = try cwd.createFile(io, path, .{});
    var wbuf: [65536]u8 = undefined;
    var w = Io.File.Writer.init(out_file, io, &wbuf);
    try w.interface.writeAll(out.items);
    try w.flush();
    out_file.close(io);
}
