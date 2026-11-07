//! Content-stream syntax (ISO 32000-1:2008, 7.8.2): a sequence of operands
//! followed by an operator. Inline images (`BI` ... `ID` ... `EI`, 8.9.7) are
//! returned as one operation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const Object = object.Object;

pub const InlineImage = struct {
    dict: object.Dict,
    data: []const u8,
};

pub const Op = struct {
    /// The operator, for example `re`, `Tj`, `'`. `BI` for an inline image.
    name: []const u8,
    operands: []const Object,
    /// Set when `name` is `BI`.
    image: ?InlineImage = null,
};

/// Most operands kept for one operator (operators take at most six, plus the
/// arrays and strings of text operators, which count as one each).
const max_operands = 512;

pub const Scanner = struct {
    p: object.Parser,
    operands: std.ArrayList(Object) = .empty,

    /// `a` is used for strings, arrays and dictionaries; it should be an arena
    /// that lives as long as the operations are used.
    pub fn init(a: Allocator, src: []const u8) Scanner {
        return .{ .p = object.Parser.init(a, src, 0) };
    }

    /// The next operation, or null at the end. Syntax errors are skipped one
    /// byte at a time, as viewers do.
    pub fn next(self: *Scanner) Allocator.Error!?Op {
        self.operands.clearRetainingCapacity();
        while (true) {
            self.p.skipWs();
            if (self.p.atEnd()) return null;
            const c = self.p.src[self.p.pos];
            if (isOperandStart(c)) {
                const save = self.p.pos;
                const before_depth = self.p.depth;
                const o = self.p.parseObject() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        self.p.depth = before_depth;
                        self.p.pos = save + 1; // resynchronise after the damage
                        continue;
                    },
                };
                if (self.operands.items.len < max_operands) try self.operands.append(self.p.a, o);
                continue;
            }
            if (!object.isRegular(c)) {
                // A stray delimiter such as `)` or `>`: skip it.
                self.p.pos += 1;
                continue;
            }
            const start = self.p.pos;
            while (self.p.pos < self.p.src.len and object.isRegular(self.p.src[self.p.pos])) self.p.pos += 1;
            const word = self.p.src[start..self.p.pos];
            if (std.mem.eql(u8, word, "true")) {
                try self.operands.append(self.p.a, .{ .boolean = true });
                continue;
            }
            if (std.mem.eql(u8, word, "false")) {
                try self.operands.append(self.p.a, .{ .boolean = false });
                continue;
            }
            if (std.mem.eql(u8, word, "null")) {
                try self.operands.append(self.p.a, .null);
                continue;
            }
            if (std.mem.eql(u8, word, "BI")) return try self.inlineImage();
            return .{ .name = word, .operands = self.operands.items };
        }
    }

    fn isOperandStart(c: u8) bool {
        return switch (c) {
            '/', '(', '<', '[', '+', '-', '.', '0'...'9' => true,
            else => false,
        };
    }

    /// `BI key value ... ID <data> EI`. The data ends at an `EI` that stands
    /// alone between white space and is followed by something that looks like
    /// the rest of a content stream.
    fn inlineImage(self: *Scanner) Allocator.Error!Op {
        var entries: std.ArrayList(object.Entry) = .empty;
        while (true) {
            self.p.skipWs();
            if (self.p.atEnd()) break;
            if (self.p.src[self.p.pos] != '/') {
                // `ID` ends the dictionary.
                const t = self.p.token() orelse break;
                if (std.mem.eql(u8, t, "ID")) break;
                continue;
            }
            const key = (self.p.parseObject() catch break).asName() orelse continue;
            const value = self.p.parseObject() catch continue;
            try entries.append(self.p.a, .{ .key = expandKey(key), .value = value });
        }
        // One white-space byte follows `ID`.
        if (self.p.pos < self.p.src.len and object.isWhite(self.p.src[self.p.pos])) {
            if (self.p.src[self.p.pos] == '\r' and self.p.pos + 1 < self.p.src.len and self.p.src[self.p.pos + 1] == '\n') self.p.pos += 1;
            self.p.pos += 1;
        }
        const start = self.p.pos;
        const src = self.p.src;
        var i = start;
        var end = src.len;
        var after_ei = src.len;
        while (i + 1 < src.len) : (i += 1) {
            if (src[i] != 'E' or src[i + 1] != 'I') continue;
            if (i > start and !object.isWhite(src[i - 1])) continue;
            if (i + 2 < src.len and object.isRegular(src[i + 2])) continue;
            if (!looksLikeContent(src[@min(i + 2, src.len)..])) continue;
            end = if (i > start) i - 1 else i;
            after_ei = i + 2;
            break;
        }
        self.p.pos = after_ei;
        const dict: object.Dict = .{ .entries = entries.items };
        return .{ .name = "BI", .operands = &.{}, .image = .{ .dict = dict, .data = src[start..@max(start, end)] } };
    }

    /// True if the next few tokens parse as operands or operators, which is
    /// not the case for most binary data that happens to contain `EI`.
    fn looksLikeContent(rest: []const u8) bool {
        const n = @min(rest.len, 16);
        for (rest[0..n]) |c| {
            if (c >= 128 or (c < 32 and !object.isWhite(c))) return false;
        }
        return true;
    }

    /// Abbreviated inline-image keys (table 93).
    fn expandKey(k: []const u8) []const u8 {
        const pairs = [_][2][]const u8{
            .{ "BPC", "BitsPerComponent" }, .{ "CS", "ColorSpace" }, .{ "D", "Decode" },
            .{ "DP", "DecodeParms" },       .{ "F", "Filter" },      .{ "H", "Height" },
            .{ "IM", "ImageMask" },         .{ "I", "Interpolate" }, .{ "W", "Width" },
        };
        for (pairs) |p| if (std.mem.eql(u8, k, p[0])) return p[1];
        return k;
    }
};

fn collect(a: Allocator, src: []const u8) ![]Op {
    var s = Scanner.init(a, src);
    var ops: std.ArrayList(Op) = .empty;
    while (try s.next()) |op| {
        // Operands live in the scanner's buffer: copy them.
        try ops.append(a, .{ .name = op.name, .operands = try a.dupe(Object, op.operands), .image = op.image });
    }
    return ops.items;
}

test "operators and operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ops = try collect(arena.allocator(), "q 1 0 0 1 10 20 cm\n/F1 12 Tf (Hi) Tj [(A) -120 (B)] TJ\n10 10 100 50 re f* Q");
    try std.testing.expectEqual(@as(usize, 8), ops.len);
    try std.testing.expectEqualStrings("q", ops[0].name);
    try std.testing.expectEqualStrings("cm", ops[1].name);
    try std.testing.expectEqual(@as(usize, 6), ops[1].operands.len);
    try std.testing.expectEqualStrings("F1", ops[2].operands[0].name);
    try std.testing.expectEqualStrings("Hi", ops[3].operands[0].string);
    try std.testing.expectEqual(@as(usize, 3), ops[4].operands[0].array.len);
    try std.testing.expectEqualStrings("re", ops[5].name);
    try std.testing.expectEqualStrings("f*", ops[6].name);
    try std.testing.expectEqualStrings("Q", ops[7].name);
}

test "quote operators, booleans and null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ops = try collect(arena.allocator(), "(line) ' 1 2 (x) \" true false null foo");
    try std.testing.expectEqualStrings("'", ops[0].name);
    try std.testing.expectEqualStrings("\"", ops[1].name);
    try std.testing.expectEqual(@as(usize, 3), ops[1].operands.len);
    try std.testing.expectEqualStrings("foo", ops[2].name);
    try std.testing.expectEqual(@as(usize, 3), ops[2].operands.len);
}

test "inline images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ops = try collect(arena.allocator(), "q BI /W 2 /H 2 /BPC 8 /CS /G ID \x01\x02\x03\x04\nEI Q (after) Tj");
    try std.testing.expectEqual(@as(usize, 4), ops.len);
    try std.testing.expectEqualStrings("BI", ops[1].name);
    const im = ops[1].image.?;
    try std.testing.expectEqual(@as(i64, 2), im.dict.get("Width").?.integer);
    try std.testing.expectEqualStrings("G", im.dict.get("ColorSpace").?.name);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, im.data);
    try std.testing.expectEqualStrings("Q", ops[2].name);
    try std.testing.expectEqualStrings("Tj", ops[3].name);
}

test "inline image data containing EI is not cut short" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ops = try collect(arena.allocator(), "BI /W 4 /H 1 /BPC 8 /CS /G ID a EIx\xff\xfe EI\nQ");
    try std.testing.expectEqualStrings("BI", ops[0].name);
    try std.testing.expectEqualStrings("a EIx\xff\xfe", ops[0].image.?.data);
    try std.testing.expectEqualStrings("Q", ops[1].name);
}

test "damaged streams are skipped, not fatal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ops = try collect(arena.allocator(), ") ] >> (unterminated\n1 2 m 12abc 3 l ((( q");
    var names: usize = 0;
    for (ops) |op| names += op.name.len;
    try std.testing.expect(names > 0); // some operators survive; nothing crashed
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..300) |_| {
        for (&buf) |*b| b.* = rnd.int(u8);
        _ = try collect(arena.allocator(), &buf);
    }
}
