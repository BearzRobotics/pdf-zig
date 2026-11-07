//! CCITTFaxDecode (ISO 32000-1:2008, 7.4.6): ITU-T T.4 (Group 3, one- and
//! two-dimensional) and T.6 (Group 4) fax coding.
//!
//! `decode` returns the image as one bit per pixel, rows padded to a whole
//! byte, most significant bit first. A damaged stream yields the rows decoded
//! so far; the rest is white. The decoder never reads outside its input.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tables = @import("ccitt_tables.zig");

pub const Error = error{ TooLarge, OutOfMemory };

pub const Params = struct {
    /// Negative: Group 4. Zero: Group 3, one-dimensional. Positive: Group 3, mixed.
    k: i32 = 0,
    columns: u32 = 1728,
    /// Rows to decode (0: until the data ends).
    rows: u32 = 0,
    /// 1 bits are black (the output is then 1 for black; by default 0 is black).
    black_is_1: bool = false,
    byte_align: bool = false,
};

/// A (length, code) to run-length lookup, built at compile time and searched by
/// binary search on `key`.
const Entry = struct { key: u32, run: u16 };

fn key(len: u8, code: u16) u32 {
    return (@as(u32, len) << 16) | code;
}

fn buildTable(comptime sets: []const []const tables.Code) [countOf(sets)]Entry {
    @setEvalBranchQuota(200_000);
    var out: [countOf(sets)]Entry = undefined;
    var n: usize = 0;
    for (sets) |set| for (set) |c| {
        out[n] = .{ .key = key(c.len, c.code), .run = c.run };
        n += 1;
    };
    std.mem.sort(Entry, &out, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return x.key < y.key;
        }
    }.lt);
    return out;
}

fn countOf(comptime sets: []const []const tables.Code) usize {
    var n: usize = 0;
    for (sets) |s| n += s.len;
    return n;
}

const white_table = buildTable(&.{ &tables.white_terminating, &tables.white_make_up, &tables.additional_make_up });
const black_table = buildTable(&.{ &tables.black_terminating, &tables.black_make_up, &tables.additional_make_up });

fn lookup(table: []const Entry, k: u32) ?u16 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (table[mid].key == k) return table[mid].run;
        if (table[mid].key < k) lo = mid + 1 else hi = mid;
    }
    return null;
}

const Bits = struct {
    data: []const u8,
    pos: usize = 0, // in bits

    fn left(self: *const Bits) usize {
        return self.data.len * 8 -| self.pos;
    }

    fn peek(self: *const Bits, n: u6) u32 {
        var v: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const at = self.pos + i;
            const bit: u32 = if (at / 8 < self.data.len) (self.data[at / 8] >> @intCast(7 - at % 8)) & 1 else 0;
            v = (v << 1) | bit;
        }
        return v;
    }

    fn skip(self: *Bits, n: usize) void {
        self.pos += n;
    }

    fn alignByte(self: *Bits) void {
        self.pos = (self.pos + 7) / 8 * 8;
    }

    /// Consumes an end-of-line code (at least eleven zeros and a one),
    /// including fill bits. Returns true if there was one.
    fn eol(self: *Bits) bool {
        var p = self.pos;
        var zeros: usize = 0;
        while (p < self.data.len * 8) : (p += 1) {
            const bit = (self.data[p / 8] >> @intCast(7 - p % 8)) & 1;
            if (bit == 0) {
                zeros += 1;
            } else {
                if (zeros >= 11) {
                    self.pos = p + 1;
                    return true;
                }
                return false;
            }
        }
        return false;
    }
};

/// One run length of colour `black`, or null if the code is invalid.
fn readRun(b: *Bits, black: bool) ?u32 {
    var total: u32 = 0;
    while (true) {
        var found: ?u16 = null;
        var len: u8 = 1;
        while (len <= 13) : (len += 1) {
            const code: u16 = @intCast(b.peek(@intCast(len)));
            if (lookup(if (black) &black_table else &white_table, key(len, code))) |r| {
                found = r;
                break;
            }
        }
        const r = found orelse return null;
        if (b.left() < len) return null;
        b.skip(len);
        total += r;
        if (r < 64) return total; // a terminating code ends the run
        if (total > 1 << 20) return null;
    }
}

const Mode = enum { pass, horizontal, v0, vr1, vr2, vr3, vl1, vl2, vl3, extension, eof };

/// Reads a two-dimensional mode code (T.6, table 1).
fn readMode(b: *Bits) ?Mode {
    if (b.peek(1) == 1) return take(b, 1, .v0);
    switch (b.peek(3)) {
        0b011 => return take(b, 3, .vr1),
        0b010 => return take(b, 3, .vl1),
        0b001 => return take(b, 3, .horizontal),
        else => {},
    }
    if (b.peek(4) == 0b0001) return take(b, 4, .pass);
    switch (b.peek(6)) {
        0b000011 => return take(b, 6, .vr2),
        0b000010 => return take(b, 6, .vl2),
        else => {},
    }
    switch (b.peek(7)) {
        0b0000011 => return take(b, 7, .vr3),
        0b0000010 => return take(b, 7, .vl3),
        0b0000001 => return take(b, 7, .extension),
        else => {},
    }
    if (b.peek(12) == 1) return .eof; // an end-of-line: the end of a Group 4 block
    return null;
}

fn take(b: *Bits, n: usize, m: Mode) Mode {
    b.skip(n);
    return m;
}

/// Decodes `data`. The result has `rows` rows (or as many as the data holds if
/// `p.rows` is 0) of `(columns + 7) / 8` bytes.
pub fn decode(a: Allocator, data: []const u8, p: Params, max: usize) Error![]u8 {
    const cols: usize = @max(1, @min(p.columns, 1 << 20));
    const stride = (cols + 7) / 8;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var bits: Bits = .{ .data = data };
    // The change positions of the reference line and of the line being coded.
    var ref: std.ArrayList(u32) = .empty;
    defer ref.deinit(a);
    var cur: std.ArrayList(u32) = .empty;
    defer cur.deinit(a);

    var row: usize = 0;
    const limit: usize = if (p.rows > 0) p.rows else std.math.maxInt(usize);
    while (row < limit and bits.left() > 0) : (row += 1) {
        if (p.byte_align) bits.alignByte();
        cur.clearRetainingCapacity();
        var two_d = p.k < 0;
        if (p.k >= 0) {
            // Group 3: an optional end-of-line, then for K > 0 a tag bit.
            _ = bits.eol();
            while (bits.eol()) {} // fill and repeated EOLs (a run of RTC)
            if (p.k > 0) {
                if (bits.left() < 1) break;
                two_d = bits.peek(1) == 0;
                bits.skip(1);
            }
            if (bits.left() == 0) break;
        }
        const ok = if (two_d) codeLine2d(a, &bits, ref.items, &cur, cols) else codeLine1d(a, &bits, &cur, cols);
        if (!ok and cur.items.len == 0 and bits.left() == 0) break;
        if (out.items.len + stride > max) return error.TooLarge;
        try appendRow(a, &out, cur.items, cols, stride);
        std.mem.swap(std.ArrayList(u32), &ref, &cur);
        if (!ok) {
            // A damaged line: keep what was decoded of it and stop.
            row += 1;
            break;
        }
    }
    // Missing rows are white.
    if (p.rows > 0) {
        while (row < p.rows) : (row += 1) {
            if (out.items.len + stride > max) return error.TooLarge;
            try appendRow(a, &out, &.{}, cols, stride);
        }
    }
    // Pixel values: white is 1 and black 0, unless the caller asked for the reverse.
    if (p.black_is_1) for (out.items) |*byte| {
        byte.* = ~byte.*;
    };
    return out.toOwnedSlice(a);
}

/// Appends a row from its change positions: white from 0, black from the first
/// change, and so on. Bits are 1 for white here (`decode` flips for BlackIs1).
fn appendRow(a: Allocator, out: *std.ArrayList(u8), changes: []const u32, cols: usize, stride: usize) Allocator.Error!void {
    const start = out.items.len;
    try out.appendNTimes(a, 0xFF, stride);
    const row = out.items[start..];
    var i: usize = 0;
    while (i < changes.len) : (i += 2) {
        const from = @min(changes[i], cols);
        const to = if (i + 1 < changes.len) @min(changes[i + 1], cols) else cols;
        var x = from;
        while (x < to) : (x += 1) row[x / 8] &= ~(@as(u8, 0x80) >> @intCast(x % 8));
    }
    // The padding bits of the last byte stay white.
}

/// One-dimensional line: alternating white and black runs, starting with white.
fn codeLine1d(a: Allocator, b: *Bits, cur: *std.ArrayList(u32), cols: usize) bool {
    var x: usize = 0;
    var black = false;
    while (x < cols) {
        const run = readRun(b, black) orelse return false;
        x += run;
        if (black == false and x < cols) cur.append(a, @intCast(x)) catch return false; // white to black
        if (black == true and x < cols) cur.append(a, @intCast(x)) catch return false; // black to white
        black = !black;
    }
    return true;
}

/// Two-dimensional line (T.6): modes against the reference line `ref`.
fn codeLine2d(a: Allocator, b: *Bits, ref: []const u32, cur: *std.ArrayList(u32), cols: usize) bool {
    var a0: i64 = -1;
    var black = false; // the colour of the pixels at a0
    var steps: usize = 0;
    while (a0 < @as(i64, @intCast(cols))) {
        steps += 1;
        if (steps > cols * 2 + 16) return false;
        // b1: the first change on the reference line right of a0 to the colour opposite of `black`;
        // changes alternate: even index = white to black.
        var bi: usize = if (black) 1 else 0;
        while (bi < ref.len and @as(i64, ref[bi]) <= a0) bi += 2;
        const b1: i64 = if (bi < ref.len) ref[bi] else @intCast(cols);
        const b2: i64 = if (bi + 1 < ref.len) ref[bi + 1] else @intCast(cols);
        const mode = readMode(b) orelse return false;
        switch (mode) {
            .pass => a0 = b2,
            .horizontal => {
                const r1 = readRun(b, black) orelse return false;
                const r2 = readRun(b, !black) orelse return false;
                const start: i64 = if (a0 < 0) 0 else a0;
                const p1 = start + r1;
                const p2 = p1 + r2;
                cur.append(a, @intCast(@min(p1, @as(i64, @intCast(cols))))) catch return false;
                cur.append(a, @intCast(@min(p2, @as(i64, @intCast(cols))))) catch return false;
                a0 = p2;
            },
            .v0, .vr1, .vr2, .vr3, .vl1, .vl2, .vl3 => {
                const d: i64 = switch (mode) {
                    .vr1 => 1,
                    .vr2 => 2,
                    .vr3 => 3,
                    .vl1 => -1,
                    .vl2 => -2,
                    .vl3 => -3,
                    else => 0,
                };
                const a1 = std.math.clamp(b1 + d, 0, @as(i64, @intCast(cols)));
                if (a1 <= a0 and a0 >= 0) return false;
                cur.append(a, @intCast(a1)) catch return false;
                a0 = a1;
                black = !black;
            },
            .extension, .eof => return false,
        }
    }
    // A change at the very end of the line is not a change.
    while (cur.items.len > 0 and cur.items[cur.items.len - 1] >= cols) _ = cur.pop();
    return true;
}

// ---- tests ----------------------------------------------------------------------------

fn pixels(a: Allocator, out: []const u8, cols: usize, row: usize) ![]u8 {
    const stride = (cols + 7) / 8;
    const r = try a.alloc(u8, cols);
    for (0..cols) |x| r[x] = if ((out[row * stride + x / 8] >> @intCast(7 - x % 8)) & 1 == 1) '.' else '#';
    return r;
}

/// Packs a string of '0' and '1' into bytes (padded with zeros).
fn packBits(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, (s.len + 7) / 8);
    @memset(out, 0);
    for (s, 0..) |c, i| if (c == '1') {
        out[i / 8] |= @as(u8, 0x80) >> @intCast(i % 8);
    };
    return out;
}

test "Group 3 one-dimensional: runs of white and black" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 8 columns: 2 white (0111), 3 black (10), 3 white (1000). Codes: white 2 = 0111, black 3 = 10, white 3 = 1000.
    const data = try packBits(a, "0111" ++ "10" ++ "1000");
    const out = try decode(a, data, .{ .k = 0, .columns = 8, .rows = 1 }, 1 << 20);
    try std.testing.expectEqualStrings("..###...", try pixels(a, out, 8, 0));
}

test "Group 4: vertical, horizontal and pass modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Line 1 against an all-white reference line, 8 columns:
    //   horizontal mode (001), white run 2 (0111), black run 3 (10) -> ..###...  then V0 (1) for the rest.
    // Line 2: identical to line 1: V0 V0 V0 (each change follows b1): changes at 2, 5 and the end.
    const data = try packBits(a, "001" ++ "0111" ++ "10" ++ "1" ++ "1" ++ "1" ++ "1");
    const out = try decode(a, data, .{ .k = -1, .columns = 8, .rows = 2 }, 1 << 20);
    try std.testing.expectEqualStrings("..###...", try pixels(a, out, 8, 0));
    try std.testing.expectEqualStrings("..###...", try pixels(a, out, 8, 1));
}

test "Group 4: shifted edges (VR1, VL1) and a pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Line 1: ..###... (horizontal 001 0111 10, then V0).
    // Line 2: edges moved right by one then left by one: VR1 (011) -> start of black at 3;
    //         VL1 (010) -> end of black at 5-1... b1 for black->white is 5, VL1 gives 4.
    const data = try packBits(a, "001" ++ "0111" ++ "10" ++ "1" ++ "011" ++ "010" ++ "1");
    const out = try decode(a, data, .{ .k = -1, .columns = 8, .rows = 2 }, 1 << 20);
    try std.testing.expectEqualStrings("..###...", try pixels(a, out, 8, 0));
    try std.testing.expectEqualStrings("...#....", try pixels(a, out, 8, 1));
    // Pass mode skips a run on the reference line without a change: all-black ref row, all-black row.
}

test "BlackIs1 flips the output, missing rows are white, damaged data stops cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try packBits(a, "0111" ++ "10" ++ "1000");
    const out = try decode(a, data, .{ .k = 0, .columns = 8, .rows = 3, .black_is_1 = true }, 1 << 20);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(@as(u8, 0b00111000), out[0]); // black pixels are 1
    try std.testing.expectEqual(@as(u8, 0), out[1]); // the rows after the data are white (0 with BlackIs1)
    // Garbage and an empty input are not a crash.
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    var buf: [300]u8 = undefined;
    for (0..400) |i| {
        for (&buf) |*x| x.* = rnd.int(u8);
        const k: i32 = @as(i32, @intCast(i % 3)) - 1;
        _ = try decode(a, buf[0 .. 1 + i % buf.len], .{ .k = k, .columns = 64 + @as(u32, @intCast(i % 50)), .rows = 20 }, 1 << 20);
    }
    _ = try decode(a, "", .{ .k = -1, .columns = 8, .rows = 2 }, 1 << 20);
}

test "the size limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.TooLarge, decode(arena.allocator(), "", .{ .k = -1, .columns = 1000, .rows = 1000 }, 100));
}
