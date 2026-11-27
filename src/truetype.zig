// SPDX-License-Identifier: LGPL-2.0-or-later
//! TrueType fonts for embedding (OpenType 1.9.1; docs/decisions/0005). Only
//! what writing a PDF needs is read: which glyph a character has, how wide it
//! is, what a font descriptor says, and enough to cut a subset. Nothing is
//! drawn.
//!
//! A font file is untrusted: every read is checked, and what does not hold is
//! an error.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Not a TrueType font, or a damaged one.
    BadFont,
    /// A kind of font that is not read: CFF outlines (`.otf`), a collection
    /// (`.ttc`), or one without a Unicode character map.
    UnsupportedFont,
    /// The font's `fsType` does not allow it to be embedded.
    FontNotEmbeddable,
    /// Larger than `max_bytes`.
    TooLarge,
    OutOfMemory,
};

/// Largest font file taken.
pub const max_bytes = 64 << 20;
/// How deeply composite glyphs may be built from one another.
const max_component_depth = 16;

pub const Options = struct {
    /// The caller has the permission of the font's owner to embed a font whose
    /// `fsType` says "Restricted License embedding". It does not unlock fonts
    /// that allow only their bitmaps to be embedded.
    permission_obtained: bool = false,
};

/// How `fsType` of the `OS/2` table says the font may be embedded.
pub const Permission = enum {
    installable,
    editable,
    /// For viewing and printing: not for form fields, which invite editing.
    preview_and_print,
    restricted,
};

pub const Font = struct {
    gpa: Allocator,
    /// The file.
    data: []const u8,
    digest: [32]u8,
    permission: Permission,
    /// The font does not allow subsetting: it is embedded whole.
    whole_only: bool,

    units_per_em: u16,
    num_glyphs: u16,
    num_h_metrics: u16,
    long_loca: bool,
    /// The box around all glyphs, in font units.
    bbox: [4]i16,
    ascender: i16,
    descender: i16,
    cap_height: i16,
    italic_angle: f64,
    fixed_pitch: bool,
    italic: bool,
    weight: u16,
    /// The PostScript name, cleaned for use as a PDF name.
    name: []const u8,

    glyf: []const u8,
    loca: []const u8,
    hmtx: []const u8,
    head: []const u8,
    hhea: []const u8,
    maxp: []const u8,
    /// Hinting tables, which a subset keeps.
    cvt: []const u8,
    fpgm: []const u8,
    prep: []const u8,
    /// The Unicode character map in use: its format and its bytes.
    cmap_format: u16,
    cmap: []const u8,

    /// Reads the TrueType font in `bytes`, which is copied.
    pub fn init(gpa: Allocator, bytes: []const u8, options: Options) Error!Font {
        if (bytes.len > max_bytes) return error.TooLarge;
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        var self = try parse(gpa, data, options);
        std.crypto.hash.sha2.Sha256.hash(data, &self.digest, .{});
        return self;
    }

    pub fn deinit(self: *Font) void {
        self.gpa.free(self.name);
        self.gpa.free(self.data);
        self.* = undefined;
    }

    /// An independent copy, allocated from `gpa`.
    pub fn clone(self: *const Font, gpa: Allocator) Allocator.Error!Font {
        const data = try gpa.dupe(u8, self.data);
        errdefer gpa.free(data);
        var out = self.*;
        out.gpa = gpa;
        out.data = data;
        out.name = try gpa.dupe(u8, self.name);
        // The tables are slices of the file: the same places in the copy.
        inline for (.{ "glyf", "loca", "hmtx", "head", "hhea", "maxp", "cvt", "fpgm", "prep", "cmap" }) |field| {
            const old = @field(self, field);
            @field(out, field) = if (old.len == 0) "" else data[@intFromPtr(old.ptr) - @intFromPtr(self.data.ptr) ..][0..old.len];
        }
        return out;
    }

    fn parse(gpa: Allocator, data: []const u8, options: Options) Error!Font {
        const version = try u32At(data, 0);
        // "OTTO" has CFF outlines, "ttcf" is a collection.
        if (version == 0x4F54544F or version == 0x74746366) return error.UnsupportedFont;
        if (version != 0x00010000 and version != 0x74727565) return error.BadFont;
        const head = try require(data, "head", 54);
        const hhea = try require(data, "hhea", 36);
        const maxp = try require(data, "maxp", 6);
        const hmtx = try require(data, "hmtx", 4);
        const loca = try require(data, "loca", 2);
        const glyf = try require(data, "glyf", 0);
        const cmap_table = try require(data, "cmap", 4);

        const units_per_em = try u16At(head, 18);
        if (units_per_em < 16 or units_per_em > 16384) return error.BadFont;
        const format = try u16At(head, 50);
        if (format > 1) return error.BadFont;
        const num_glyphs = try u16At(maxp, 4);
        const num_h_metrics = try u16At(hhea, 34);
        if (num_glyphs == 0 or num_h_metrics == 0 or num_h_metrics > num_glyphs) return error.BadFont;
        if (hmtx.len < @as(usize, num_h_metrics) * 4 + @as(usize, num_glyphs - num_h_metrics) * 2) return error.BadFont;
        if (loca.len < (@as(usize, num_glyphs) + 1) * @as(usize, if (format == 1) 4 else 2)) return error.BadFont;

        var self: Font = .{
            .gpa = gpa,
            .data = data,
            .digest = undefined,
            .permission = .installable,
            .whole_only = false,
            .units_per_em = units_per_em,
            .num_glyphs = num_glyphs,
            .num_h_metrics = num_h_metrics,
            .long_loca = format == 1,
            .bbox = .{ try i16At(head, 36), try i16At(head, 38), try i16At(head, 40), try i16At(head, 42) },
            .ascender = try i16At(hhea, 4),
            .descender = try i16At(hhea, 6),
            .cap_height = try i16At(hhea, 4),
            .italic_angle = 0,
            .fixed_pitch = false,
            .italic = try u16At(head, 44) & 2 != 0,
            .weight = 400,
            .name = "",
            .glyf = glyf,
            .loca = loca,
            .hmtx = hmtx,
            .head = head,
            .hhea = hhea,
            .maxp = maxp,
            .cvt = (try table(data, "cvt ")) orelse "",
            .fpgm = (try table(data, "fpgm")) orelse "",
            .prep = (try table(data, "prep")) orelse "",
            .cmap_format = 0,
            .cmap = "",
        };
        // Every glyph's place, checked once so that reading one needs no more.
        var previous: u32 = 0;
        for (0..@as(usize, num_glyphs) + 1) |i| {
            const offset = try self.glyphOffset(i);
            if (offset < previous or offset > glyf.len) return error.BadFont;
            previous = offset;
        }

        if (try table(data, "OS/2")) |os2| {
            self.weight = try u16At(os2, 4);
            const fs_type = try u16At(os2, 8);
            // Old versions allowed several bits, the most permissive counting.
            self.permission = if (fs_type & 0x000F == 0) .installable else if (fs_type & 0x0008 != 0) .editable else if (fs_type & 0x0004 != 0) .preview_and_print else if (fs_type & 0x0002 != 0) .restricted else .installable;
            self.whole_only = fs_type & 0x0100 != 0;
            // Only bitmaps may be embedded, and outlines are what is embedded.
            if (fs_type & 0x0200 != 0) return error.FontNotEmbeddable;
            if (self.permission == .restricted and !options.permission_obtained) return error.FontNotEmbeddable;
            if (try u16At(os2, 0) >= 2 and os2.len >= 90) self.cap_height = try i16At(os2, 88);
        }
        if (try table(data, "post")) |post| if (post.len >= 16) {
            self.italic_angle = @as(f64, @floatFromInt(@as(i32, @bitCast(try u32At(post, 4))))) / 65536.0;
            self.fixed_pitch = try u32At(post, 12) != 0;
        };

        try self.chooseCmap(cmap_table);
        self.name = try postScriptName(gpa, try table(data, "name"));
        return self;
    }

    /// The best Unicode subtable: the full repertoire before the basic plane.
    fn chooseCmap(self: *Font, cmap: []const u8) Error!void {
        const count = try u16At(cmap, 2);
        var best: u8 = 0;
        for (0..count) |i| {
            const platform = try u16At(cmap, 4 + i * 8);
            const encoding = try u16At(cmap, 6 + i * 8);
            const offset = try u32At(cmap, 8 + i * 8);
            const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
            if (!unicode or offset >= cmap.len) continue;
            const sub = cmap[offset..];
            const format = try u16At(sub, 0);
            const rank: u8 = switch (format) {
                12 => 2,
                4 => 1,
                else => 0,
            };
            if (rank <= best) continue;
            const length: usize = if (format == 4) try u16At(sub, 2) else try u32At(sub, 4);
            // Some fonts give format 4 a length that is too small for a large
            // table; the table then runs to the end of `cmap`.
            const bytes = if (format == 4) sub else if (length <= sub.len) sub[0..length] else return error.BadFont;
            if (format == 4) {
                const segments = try u16At(bytes, 6) / 2;
                if (segments == 0 or bytes.len < 16 + @as(usize, segments) * 8) return error.BadFont;
            } else if (bytes.len < 16 or (bytes.len - 16) / 12 < try u32At(bytes, 12)) return error.BadFont;
            best = rank;
            self.cmap_format = format;
            self.cmap = bytes;
        }
        if (best == 0) return error.UnsupportedFont;
    }

    /// The glyph for character `c`, or null when the font has none.
    pub fn glyphFor(self: *const Font, c: u21) ?u16 {
        const glyph = (if (self.cmap_format == 12) self.lookup12(c) else self.lookup4(c)) catch return null;
        return if (glyph == 0 or glyph >= self.num_glyphs) null else glyph;
    }

    fn lookup4(self: *const Font, c: u21) Error!u16 {
        if (c > 0xFFFF) return 0;
        const map = self.cmap;
        const segments: usize = try u16At(map, 6) / 2;
        const ends = 14;
        const starts = ends + segments * 2 + 2;
        const deltas = starts + segments * 2;
        const ranges = deltas + segments * 2;
        // The first segment that ends at or after `c`.
        var low: usize = 0;
        var high = segments;
        while (low < high) {
            const middle = (low + high) / 2;
            if (try u16At(map, ends + middle * 2) < c) low = middle + 1 else high = middle;
        }
        if (low == segments) return 0;
        const start = try u16At(map, starts + low * 2);
        if (c < start) return 0;
        const delta = try u16At(map, deltas + low * 2);
        const range = try u16At(map, ranges + low * 2);
        const code: u16 = @intCast(c);
        if (range == 0) return code +% delta;
        // An offset from this very entry into the array that follows.
        const glyph = try u16At(map, ranges + low * 2 + range + @as(usize, code - start) * 2);
        return if (glyph == 0) 0 else glyph +% delta;
    }

    fn lookup12(self: *const Font, c: u21) Error!u16 {
        const map = self.cmap;
        var low: usize = 0;
        var high: usize = try u32At(map, 12);
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (try u32At(map, 16 + middle * 12 + 4) < c) low = middle + 1 else high = middle;
        }
        if (low == try u32At(map, 12)) return 0;
        const start = try u32At(map, 16 + low * 12);
        if (c < start) return 0;
        const glyph = @as(u64, try u32At(map, 16 + low * 12 + 8)) + (c - start);
        return std.math.cast(u16, glyph) orelse 0;
    }

    /// The advance of `glyph` in 1/1000 em.
    pub fn width(self: *const Font, glyph: u16) f64 {
        return self.scale(self.advance(glyph));
    }

    /// `units` of the font in 1/1000 em.
    pub fn scale(self: *const Font, units: anytype) f64 {
        return @as(f64, @floatFromInt(units)) * 1000 / @as(f64, @floatFromInt(self.units_per_em));
    }

    fn advance(self: *const Font, glyph: u16) u16 {
        // The glyphs past the last full entry are as wide as it.
        const i: usize = @min(glyph, self.num_h_metrics - 1);
        return u16At(self.hmtx, i * 4) catch 0;
    }

    fn glyphOffset(self: *const Font, index: usize) Error!u32 {
        return if (self.long_loca) u32At(self.loca, index * 4) else @as(u32, try u16At(self.loca, index * 2)) * 2;
    }

    fn glyphData(self: *const Font, glyph: u16) Error![]const u8 {
        const from = try self.glyphOffset(glyph);
        const to = try self.glyphOffset(@as(usize, glyph) + 1);
        return self.glyf[from..to];
    }

    /// Marks in `keep` the glyphs that composite `glyph` is built from.
    fn addComponents(self: *const Font, keep: []bool, glyph: u16, depth: usize, budget: *usize) Error!void {
        const data = try self.glyphData(glyph);
        if (data.len == 0 or try i16At(data, 0) >= 0) return;
        if (depth >= max_component_depth) return error.BadFont;
        var at: usize = 10;
        while (true) {
            if (budget.* == 0) return error.BadFont;
            budget.* -= 1;
            const flags = try u16At(data, at);
            const part = try u16At(data, at + 2);
            if (part >= self.num_glyphs) return error.BadFont;
            if (!keep[part]) {
                keep[part] = true;
                try self.addComponents(keep, part, depth + 1, budget);
            }
            at += 4 + @as(usize, if (flags & 0x0001 != 0) 4 else 2);
            if (flags & 0x0008 != 0) at += 2 else if (flags & 0x0040 != 0) at += 4 else if (flags & 0x0080 != 0) at += 8;
            if (flags & 0x0020 == 0) return;
        }
    }

    /// A font file with only `glyphs` (and `.notdef`, and what they are built
    /// from) drawn. Glyph numbers stay as they are: the others are left empty,
    /// and the font ends after the last one kept. It has the tables an
    /// embedded `CIDFontType2` needs (9.9). Allocated from `a`.
    pub fn subset(self: *const Font, a: Allocator, glyphs: []const u16) Error![]u8 {
        const keep = try a.alloc(bool, self.num_glyphs);
        defer a.free(keep);
        @memset(keep, false);
        keep[0] = true;
        var budget: usize = 4 * @as(usize, self.num_glyphs) + 1024;
        try self.addComponents(keep, 0, 0, &budget);
        for (glyphs) |g| {
            if (g >= self.num_glyphs) return error.BadFont;
            if (keep[g]) continue;
            keep[g] = true;
            try self.addComponents(keep, g, 0, &budget);
        }
        var count: usize = 1;
        for (keep, 0..) |is_kept, i| if (is_kept) {
            count = i + 1;
        };

        var glyf: std.ArrayList(u8) = .empty;
        defer glyf.deinit(a);
        var loca: std.ArrayList(u8) = .empty;
        defer loca.deinit(a);
        for (0..count) |i| {
            try appendInt(a, &loca, u32, @intCast(glyf.items.len));
            if (!keep[i]) continue;
            const data = try self.glyphData(@intCast(i));
            // Glyphs may overlap in a damaged `loca`: they are bounded.
            if (data.len > max_bytes -| glyf.items.len) return error.TooLarge;
            try glyf.appendSlice(a, data);
            while (glyf.items.len % 4 != 0) try glyf.append(a, 0);
        }
        try appendInt(a, &loca, u32, @intCast(glyf.items.len));

        const metrics: u16 = @intCast(@min(self.num_h_metrics, count));
        var hmtx: std.ArrayList(u8) = .empty;
        defer hmtx.deinit(a);
        try hmtx.appendSlice(a, self.hmtx[0 .. @as(usize, metrics) * 4]);
        // The side bearings after the full entries.
        if (count > metrics) try hmtx.appendSlice(a, self.hmtx[@as(usize, self.num_h_metrics) * 4 ..][0 .. (count - metrics) * 2]);

        const head = try a.dupe(u8, self.head);
        defer a.free(head);
        std.mem.writeInt(u32, head[8..12], 0, .big); // checkSumAdjustment, set below
        std.mem.writeInt(u16, head[50..52], 1, .big); // long `loca`
        const hhea = try a.dupe(u8, self.hhea);
        defer a.free(hhea);
        std.mem.writeInt(u16, hhea[34..36], metrics, .big);
        const maxp = try a.dupe(u8, self.maxp);
        defer a.free(maxp);
        std.mem.writeInt(u16, maxp[4..6], @intCast(count), .big);

        // In the order of their tags.
        const Part = struct { tag: *const [4]u8, bytes: []const u8 };
        const all = [_]Part{
            .{ .tag = "cvt ", .bytes = self.cvt },   .{ .tag = "fpgm", .bytes = self.fpgm },
            .{ .tag = "glyf", .bytes = glyf.items }, .{ .tag = "head", .bytes = head },
            .{ .tag = "hhea", .bytes = hhea },       .{ .tag = "hmtx", .bytes = hmtx.items },
            .{ .tag = "loca", .bytes = loca.items }, .{ .tag = "maxp", .bytes = maxp },
            .{ .tag = "prep", .bytes = self.prep },
        };
        var parts: [all.len]Part = undefined;
        var used: usize = 0;
        for (all) |part| {
            const hint = std.mem.eql(u8, part.tag, "cvt ") or std.mem.eql(u8, part.tag, "fpgm") or std.mem.eql(u8, part.tag, "prep");
            if (hint and part.bytes.len == 0) continue;
            parts[used] = part;
            used += 1;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try appendInt(a, &out, u32, 0x00010000);
        try appendInt(a, &out, u16, @intCast(used));
        const power: u16 = @as(u16, 1) << @intCast(std.math.log2_int(usize, used));
        try appendInt(a, &out, u16, power * 16);
        try appendInt(a, &out, u16, std.math.log2_int(u16, power));
        try appendInt(a, &out, u16, @intCast(used * 16 - power * 16));
        var offset: usize = 12 + used * 16;
        var head_at: usize = 0;
        for (parts[0..used]) |part| {
            try out.appendSlice(a, part.tag);
            try appendInt(a, &out, u32, checksum(part.bytes));
            try appendInt(a, &out, u32, @intCast(offset));
            try appendInt(a, &out, u32, @intCast(part.bytes.len));
            if (std.mem.eql(u8, part.tag, "head")) head_at = offset;
            offset += std.mem.alignForward(usize, part.bytes.len, 4);
            if (offset > max_bytes) return error.TooLarge;
        }
        for (parts[0..used]) |part| {
            try out.appendSlice(a, part.bytes);
            while (out.items.len % 4 != 0) try out.append(a, 0);
        }
        std.mem.writeInt(u32, out.items[head_at + 8 ..][0..4], 0xB1B0AFBA -% checksum(out.items), .big);
        return out.toOwnedSlice(a);
    }
};

/// The sum of the big endian words of `bytes`, padded with zeros.
pub fn checksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        var word: [4]u8 = @splat(0);
        const n = @min(4, bytes.len - i);
        @memcpy(word[0..n], bytes[i..][0..n]);
        sum +%= std.mem.readInt(u32, &word, .big);
    }
    return sum;
}

fn appendInt(a: Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, v, .big);
    try out.appendSlice(a, &bytes);
}

fn u16At(bytes: []const u8, at: usize) Error!u16 {
    if (bytes.len < 2 or at > bytes.len - 2) return error.BadFont;
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}

fn i16At(bytes: []const u8, at: usize) Error!i16 {
    return @bitCast(try u16At(bytes, at));
}

fn u32At(bytes: []const u8, at: usize) Error!u32 {
    if (bytes.len < 4 or at > bytes.len - 4) return error.BadFont;
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}

/// The bytes of table `tag`, or null when the font has none.
fn table(data: []const u8, tag: *const [4]u8) Error!?[]const u8 {
    const count = try u16At(data, 4);
    for (0..count) |i| {
        const record = 12 + i * 16;
        if (record + 16 > data.len) return error.BadFont;
        if (!std.mem.eql(u8, data[record..][0..4], tag)) continue;
        const offset = try u32At(data, record + 8);
        const length = try u32At(data, record + 12);
        if (offset > data.len or length > data.len - offset) return error.BadFont;
        return data[offset..][0..length];
    }
    return null;
}

fn require(data: []const u8, tag: *const [4]u8, least: usize) Error![]const u8 {
    const bytes = try table(data, tag) orelse return error.BadFont;
    if (bytes.len < least) return error.BadFont;
    return bytes;
}

/// Name 6 of the `name` table, keeping what a PDF name can hold without
/// escapes; "Font" when there is none.
fn postScriptName(gpa: Allocator, name_table: ?[]const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (name_table) |names| if (names.len >= 6) {
        const count = try u16At(names, 2);
        const strings = try u16At(names, 4);
        for (0..count) |i| {
            const record = 6 + i * 12;
            if (record + 12 > names.len) break;
            if (try u16At(names, record + 6) != 6) continue;
            const platform = try u16At(names, record);
            const length = try u16At(names, record + 8);
            const offset = @as(usize, strings) + try u16At(names, record + 10);
            if (offset > names.len or length > names.len - offset) continue;
            const text = names[offset..][0..length];
            // Windows and Unicode strings are UTF-16, others one byte each.
            const step: usize = if (platform == 0 or platform == 3) 2 else 1;
            var j: usize = step - 1;
            while (j < text.len and out.items.len < 63) : (j += step) {
                const c = text[j];
                if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ',') try out.append(gpa, c);
            }
            if (out.items.len > 0) break;
        }
    };
    if (out.items.len == 0) try out.appendSlice(gpa, "Font");
    return out.toOwnedSlice(gpa);
}

// Tests live in truetype_tests.zig.
