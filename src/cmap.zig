//! CMap programs (ISO 32000-1:2008, 9.7.5 and 9.10.3): `/ToUnicode` maps from
//! character codes to Unicode text, and embedded CID maps from codes to CIDs.
//!
//! Only the operators that carry data are read: `codespacerange`, `bfchar`,
//! `bfrange`, `cidchar`, `cidrange` and `notdefrange` (ignored). `usecmap` and
//! the predefined CJK maps are not followed; `Identity-H` and `Identity-V` are
//! handled by the caller.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");

pub const CodeSpace = struct { lo: u32, hi: u32, bytes: u8 };

/// A run of codes `lo..=hi` of `bytes` bytes. For a Unicode map `dst` is the
/// UTF-16 text of `lo`; later codes add one to its last unit. For a CID map
/// `dst` holds the CID of `lo`.
const Range = struct {
    lo: u32,
    hi: u32,
    /// Bytes in the source code (for sorting and lookups of different lengths).
    bytes: u8,
    dst: []const u16,
};

pub const CMap = struct {
    spaces: []const CodeSpace = &.{},
    ranges: []const Range = &.{},

    /// Largest number of entries read from one CMap.
    pub const max_entries = 1 << 20;

    /// How many bytes the next code at `s` takes: from the code space ranges
    /// (9.7.6.2), or `default` if none matches.
    pub fn codeLength(self: CMap, s: []const u8, default: u8) u8 {
        if (self.spaces.len == 0) return @min(default, @as(u8, @intCast(@min(s.len, 255))));
        var best: u8 = 0;
        for (self.spaces) |sp| {
            if (sp.bytes > s.len) continue;
            var v: u32 = 0;
            for (s[0..sp.bytes]) |b| v = (v << 8) | b;
            if (v >= sp.lo and v <= sp.hi) return sp.bytes;
            if (best == 0 or sp.bytes < best) best = sp.bytes;
        }
        // No range matched: skip the shortest code length (9.7.6.3).
        return @min(best, @as(u8, @intCast(@min(s.len, 255))));
    }

    fn find(self: CMap, code: u32, bytes: u8) ?*const Range {
        // Ranges are sorted by (bytes, lo). Later definitions of the same
        // code win, so look at the last range that starts at or before it.
        var lo: usize = 0;
        var hi: usize = self.ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.ranges[mid];
            if (r.bytes < bytes or (r.bytes == bytes and r.lo <= code)) lo = mid + 1 else hi = mid;
        }
        // Walk back over ranges that start before `code`.
        var i = lo;
        var steps: usize = 0;
        while (i > 0 and steps < 8) : (steps += 1) {
            i -= 1;
            const r = &self.ranges[i];
            if (r.bytes != bytes) break;
            if (code >= r.lo and code <= r.hi) return r;
        }
        return null;
    }

    /// CID of `code` (a CID map), or null.
    pub fn cid(self: CMap, code: u32, bytes: u8) ?u32 {
        const r = self.find(code, bytes) orelse return null;
        return r.dst[0] + (code - r.lo);
    }

    /// Appends the Unicode text of `code` (a ToUnicode map) as UTF-8 to `out`.
    /// Returns false if the map has no entry.
    pub fn unicode(self: CMap, a: Allocator, code: u32, bytes: u8, out: *std.ArrayList(u8)) Allocator.Error!bool {
        const r = self.find(code, bytes) orelse return false;
        var units: [16]u16 = undefined;
        const n = @min(r.dst.len, units.len);
        @memcpy(units[0..n], r.dst[0..n]);
        if (n > 0) units[n - 1] +%= @intCast(code - r.lo);
        var it = std.unicode.Utf16LeIterator.init(units[0..n]);
        while (it.nextCodepoint() catch return false) |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch continue;
            try out.appendSlice(a, buf[0..len]);
        }
        return true;
    }
};

fn hexValue(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |b| v = (v << 8) | b;
    return v;
}

fn utf16Of(a: Allocator, s: []const u8) Allocator.Error![]const u16 {
    const n = s.len / 2;
    const out = try a.alloc(u16, @max(n, 1));
    out[0] = 0;
    for (0..n) |i| out[i] = (@as(u16, s[2 * i]) << 8) | s[2 * i + 1];
    if (n == 0 and s.len == 1) out[0] = s[0];
    return out[0..@max(n, 1)];
}

fn lessThan(_: void, x: Range, y: Range) bool {
    if (x.bytes != y.bytes) return x.bytes < y.bytes;
    return x.lo < y.lo;
}

/// Parses CMap program text. Allocations come from `a` (use an arena).
pub fn parse(a: Allocator, src: []const u8) Allocator.Error!CMap {
    var p = object.Parser.init(a, src, 0);
    var spaces: std.ArrayList(CodeSpace) = .empty;
    var ranges: std.ArrayList(Range) = .empty;
    var section: enum { none, space, bfchar, bfrange, cidchar, cidrange } = .none;
    var pending: [3]object.Object = undefined;
    var npending: usize = 0;

    while (true) {
        p.skipWs();
        if (p.atEnd()) break;
        const c = p.src[p.pos];
        if (c == '/' or c == '(' or c == '<' or c == '[' or c == '+' or c == '-' or c == '.' or (c >= '0' and c <= '9')) {
            const o = p.parseObject() catch {
                p.pos += 1;
                continue;
            };
            if (section == .none) continue;
            // `[ ... ]` arrays appear as the destination of bfrange.
            pending[npending % 3] = o;
            npending += 1;
            const need: usize = switch (section) {
                .space => 2,
                .bfchar, .cidchar => 2,
                .bfrange, .cidrange => 3,
                .none => 3,
            };
            if (npending == need) {
                npending = 0;
                if (ranges.items.len >= CMap.max_entries) continue;
                switch (section) {
                    .space => if (pending[0] == .string and pending[1] == .string and pending[0].string.len <= 4)
                        try spaces.append(a, .{ .lo = hexValue(pending[0].string), .hi = hexValue(pending[1].string), .bytes = @intCast(pending[0].string.len) }),
                    .bfchar => if (pending[0] == .string and pending[1] == .string and pending[0].string.len <= 4) {
                        const code = hexValue(pending[0].string);
                        try ranges.append(a, .{ .lo = code, .hi = code, .bytes = @intCast(pending[0].string.len), .dst = try utf16Of(a, pending[1].string) });
                    },
                    .bfrange => if (pending[0] == .string and pending[1] == .string and pending[0].string.len <= 4) {
                        const lo = hexValue(pending[0].string);
                        const hi = hexValue(pending[1].string);
                        const bytes: u8 = @intCast(pending[0].string.len);
                        switch (pending[2]) {
                            .string => |d| if (hi >= lo) try ranges.append(a, .{ .lo = lo, .hi = hi, .bytes = bytes, .dst = try utf16Of(a, d) }),
                            .array => |arr| for (arr, 0..) |item, i| {
                                if (item != .string or lo + i > hi) continue;
                                try ranges.append(a, .{ .lo = @intCast(lo + i), .hi = @intCast(lo + i), .bytes = bytes, .dst = try utf16Of(a, item.string) });
                            },
                            else => {},
                        }
                    },
                    .cidchar => if (pending[0] == .string and pending[1] == .integer and pending[0].string.len <= 4) {
                        const code = hexValue(pending[0].string);
                        const dst = try a.alloc(u16, 1);
                        dst[0] = @intCast(std.math.clamp(pending[1].integer, 0, 65535));
                        try ranges.append(a, .{ .lo = code, .hi = code, .bytes = @intCast(pending[0].string.len), .dst = dst });
                    },
                    .cidrange => if (pending[0] == .string and pending[1] == .string and pending[2] == .integer and pending[0].string.len <= 4) {
                        const dst = try a.alloc(u16, 1);
                        dst[0] = @intCast(std.math.clamp(pending[2].integer, 0, 65535));
                        try ranges.append(a, .{ .lo = hexValue(pending[0].string), .hi = hexValue(pending[1].string), .bytes = @intCast(pending[0].string.len), .dst = dst });
                    },
                    .none => {},
                }
            }
            continue;
        }
        if (!object.isRegular(c)) {
            p.pos += 1;
            continue;
        }
        const start = p.pos;
        while (p.pos < p.src.len and object.isRegular(p.src[p.pos])) p.pos += 1;
        const word = p.src[start..p.pos];
        npending = 0;
        if (std.mem.eql(u8, word, "begincodespacerange")) section = .space;
        if (std.mem.eql(u8, word, "beginbfchar")) section = .bfchar;
        if (std.mem.eql(u8, word, "beginbfrange")) section = .bfrange;
        if (std.mem.eql(u8, word, "begincidchar")) section = .cidchar;
        if (std.mem.eql(u8, word, "begincidrange")) section = .cidrange;
        if (std.mem.startsWith(u8, word, "end")) section = .none;
        if (std.mem.eql(u8, word, "beginnotdefchar") or std.mem.eql(u8, word, "beginnotdefrange")) section = .none;
    }
    // A stable sort keeps definition order for equal keys; `find` prefers later ones.
    std.mem.sortUnstable(Range, ranges.items, {}, lessThan);
    return .{ .spaces = spaces.items, .ranges = ranges.items };
}

test "ToUnicode: bfchar, bfrange, array form, ligature text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\/CIDInit /ProcSet findresource begin 12 dict begin begincmap
        \\1 begincodespacerange <0000> <FFFF> endcodespacerange
        \\2 beginbfchar
        \\<0003> <0020>
        \\<0010> <00660069>
        \\endbfchar
        \\2 beginbfrange
        \\<0020> <0025> <0041>
        \\<0030> <0032> [<0058> <0059> <005A>]
        \\endbfrange
        \\endcmap
    ;
    const m = try parse(a, src);
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expect(try m.unicode(a, 3, 2, &out));
    try std.testing.expectEqualStrings(" ", out.items);
    out.clearRetainingCapacity();
    try std.testing.expect(try m.unicode(a, 0x10, 2, &out));
    try std.testing.expectEqualStrings("fi", out.items);
    out.clearRetainingCapacity();
    try std.testing.expect(try m.unicode(a, 0x22, 2, &out)); // 0x41 + 2
    try std.testing.expectEqualStrings("C", out.items);
    out.clearRetainingCapacity();
    try std.testing.expect(try m.unicode(a, 0x31, 2, &out));
    try std.testing.expectEqualStrings("Y", out.items);
    try std.testing.expect(!(try m.unicode(a, 0x99, 2, &out)));
    try std.testing.expectEqual(@as(u8, 2), m.codeLength("\x00\x03", 1));
}

test "ToUnicode: one-byte codes and non-BMP text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, "1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <D83DDE00> <42> <00E9> endbfchar");
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expect(try m.unicode(a, 0x41, 1, &out));
    try std.testing.expectEqualStrings("\u{1F600}", out.items);
    out.clearRetainingCapacity();
    try std.testing.expect(try m.unicode(a, 0x42, 1, &out));
    try std.testing.expectEqualStrings("\u{E9}", out.items);
    try std.testing.expectEqual(@as(u8, 1), m.codeLength("\x41", 2));
}

test "CID maps: cidchar and cidrange, mixed code lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a,
        \\2 begincodespacerange <00> <7F> <8000> <FFFF> endcodespacerange
        \\1 begincidchar <20> 1 endcidchar
        \\2 begincidrange <8140> <817E> 633 <8200> <8210> 1000 endcidrange
    );
    try std.testing.expectEqual(@as(?u32, 1), m.cid(0x20, 1));
    try std.testing.expectEqual(@as(?u32, 633), m.cid(0x8140, 2));
    try std.testing.expectEqual(@as(?u32, 635), m.cid(0x8142, 2));
    try std.testing.expectEqual(@as(?u32, 1005), m.cid(0x8205, 2));
    try std.testing.expectEqual(@as(?u32, null), m.cid(0x8300, 2));
    try std.testing.expectEqual(@as(u8, 1), m.codeLength("\x20\x00", 2));
    try std.testing.expectEqual(@as(u8, 2), m.codeLength("\x81\x40", 2));
}

test "later definitions override earlier ones; damaged text is tolerated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, "1 beginbfchar <41> <0058> endbfchar 1 beginbfchar <41> <0059> endbfchar");
    var out: std.ArrayList(u8) = .empty;
    _ = try m.unicode(a, 0x41, 1, &out);
    try std.testing.expect(out.items.len == 1); // one of the two; deterministic
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var buf: [200]u8 = undefined;
    for (0..300) |_| {
        for (&buf) |*b| b.* = rnd.int(u8);
        const mm = try parse(a, &buf);
        _ = mm.cid(1, 1);
        out.clearRetainingCapacity();
        _ = try mm.unicode(a, 1, 1, &out);
    }
}
