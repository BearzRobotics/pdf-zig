//! Font dictionaries (ISO 32000-1:2008, clause 9): encodings, widths, composite
//! fonts and the Unicode text of character codes.
//!
//! The library describes fonts; it does not draw them. `Font.program` names the
//! embedded font file for the renderer, and `glyphs` turns the bytes of a
//! text-showing operator into character codes with advances and text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const encoding = @import("encoding.zig");
const cmap_mod = @import("cmap.zig");
const std14 = @import("std14.zig");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const Object = object.Object;
const Dict = object.Dict;

pub const Subtype = enum { type1, truetype, type3, type0, unknown };

pub const ProgramKind = enum {
    none,
    /// Type 1 (FontFile).
    type1,
    /// TrueType (FontFile2).
    truetype,
    /// Bare CFF (FontFile3 /Type1C or /CIDFontType0C).
    cff,
    /// OpenType (FontFile3 /OpenType); may hold CFF or TrueType outlines.
    opentype,
};

/// The embedded font file, still encoded; `Document.streamData` decodes it.
pub const Program = struct {
    kind: ProgramKind = .none,
    stream: ?object.Stream = null,
};

const WidthRange = struct { first: u32, last: u32, w: f64 };

pub const Font = struct {
    /// Object number of the font dictionary, or 0.
    num: u32 = 0,
    subtype: Subtype = .unknown,
    /// `/BaseFont` without a subset prefix (`ABCDEF+`).
    base_font: []const u8 = "",
    /// `/Flags` of the font descriptor (9.8.2).
    flags: u32 = 0,
    program: Program = .{},

    /// Advance = width * `width_scale` (em units): 0.001, or the FontMatrix scale of a Type 3 font.
    width_scale: f64 = 0.001,

    // Simple fonts (Type1, TrueType, Type3).
    first_char: u32 = 0,
    widths: []const f64 = &.{},
    missing_width: f64 = 0,
    /// Standard 14 metrics by glyph-name index, used when `/Widths` is absent.
    std_widths: ?[]const u16 = null,
    /// Unicode of each code (0 if unknown) and its glyph name, from the encoding.
    unicode: [256]u21 = @splat(0),
    names: [256]?[]const u8 = @splat(null),
    to_unicode: ?cmap_mod.CMap = null,

    // Composite fonts (Type0).
    /// Code to CID map from an embedded CMap; null means the 2-byte identity.
    cid_map: ?cmap_mod.CMap = null,
    /// Name of a predefined CMap other than Identity (CIDs then equal the codes).
    predefined_cmap: []const u8 = "",
    vertical: bool = false,
    dw: f64 = 1000,
    cid_widths: []const WidthRange = &.{},
    /// `/CIDToGIDMap` stream data, two bytes per CID; null is the identity.
    cid_to_gid: ?object.Stream = null,
    cid_subtype: []const u8 = "",

    // Type 3.
    font_matrix: [6]f64 = .{ 0.001, 0, 0, 0.001, 0, 0 },
    char_procs: Dict = .{},
    resources: ?Dict = null,

    pub fn isComposite(self: *const Font) bool {
        return self.subtype == .type0;
    }

    /// Whether `/Flags` marks the font as symbolic (bit 3).
    pub fn isSymbolic(self: *const Font) bool {
        return self.flags & 4 != 0;
    }

    pub fn load(doc: *Document, dict: Dict, num: u32) Allocator.Error!Font {
        const a = doc.arena.allocator();
        var f: Font = .{ .num = num };
        const st = doc.getName(dict, "Subtype") orelse "";
        f.subtype = if (std.mem.eql(u8, st, "Type1") or std.mem.eql(u8, st, "MMType1")) .type1 else if (std.mem.eql(u8, st, "TrueType")) .truetype else if (std.mem.eql(u8, st, "Type3")) .type3 else if (std.mem.eql(u8, st, "Type0")) .type0 else .unknown;
        f.base_font = stripSubset(doc.getName(dict, "BaseFont") orelse "");

        if (doc.get(dict, "ToUnicode")) |tu| if (tu == .stream) {
            const data = doc.streamData(tu.stream) catch "";
            f.to_unicode = try cmap_mod.parse(a, data);
        };

        if (f.subtype == .type0) {
            try f.loadComposite(doc, dict);
        } else {
            try f.loadSimple(doc, dict);
        }
        return f;
    }

    fn stripSubset(name: []const u8) []const u8 {
        if (name.len > 7 and name[6] == '+') {
            for (name[0..6]) |c| if (c < 'A' or c > 'Z') return name;
            return name[7..];
        }
        return name;
    }

    fn loadDescriptor(self: *Font, doc: *Document, desc_obj: ?Object) void {
        const desc = (desc_obj orelse return).asDict() orelse return;
        self.flags = @intCast(@max(0, doc.getInt(desc, "Flags") orelse 0));
        if (doc.getNum(desc, "MissingWidth")) |mw| self.missing_width = mw;
        const files = [_]struct { []const u8, ProgramKind }{ .{ "FontFile", .type1 }, .{ "FontFile2", .truetype }, .{ "FontFile3", .cff } };
        for (files) |ff| {
            const s = doc.get(desc, ff[0]) orelse continue;
            if (s != .stream) continue;
            var kind = ff[1];
            if (kind == .cff) {
                const sub = doc.getName(s.stream.dict, "Subtype") orelse "";
                if (std.mem.eql(u8, sub, "OpenType")) kind = .opentype;
            }
            self.program = .{ .kind = kind, .stream = s.stream };
            return;
        }
    }

    // ---- simple fonts ------------------------------------------------------------

    fn loadSimple(self: *Font, doc: *Document, dict: Dict) Allocator.Error!void {
        const a = doc.arena.allocator();
        if (dict.get("FontDescriptor")) |fd| self.loadDescriptor(doc, doc.resolve(fd));

        // Widths (9.6.2.1).
        self.first_char = @intCast(@max(0, doc.getInt(dict, "FirstChar") orelse 0));
        if (doc.getArray(dict, "Widths")) |arr| {
            const w = try a.alloc(f64, @min(arr.len, 1024));
            for (w, 0..) |*slot, i| slot.* = doc.resolve(arr[i]).asNum() orelse 0;
            self.widths = w;
        }

        // Base encoding and differences (9.6.6).
        var base: encoding.Base = .none;
        var diffs: ?[]const Object = null;
        if (doc.get(dict, "Encoding")) |e| switch (e) {
            .name => |n| base = encoding.baseFromName(n) orelse .none,
            .dict => |d| {
                if (doc.getName(d, "BaseEncoding")) |n| base = encoding.baseFromName(n) orelse .none;
                diffs = doc.getArray(d, "Differences");
            },
            else => {},
        };
        const std_name = standard14(self.base_font);
        if (base == .none) {
            // No base encoding: nonsymbolic fonts and the standard 14 use
            // StandardEncoding; TrueType text is usually WinAnsi (9.6.6.1).
            base = if (self.subtype == .truetype) .win_ansi else .standard;
        }
        for (0..256) |c| {
            const u = encoding.unicodeOf(base, @intCast(c));
            self.unicode[c] = u;
            if (u != 0) self.names[c] = encoding.nameOfUnicode(u);
        }
        if (diffs) |ds| {
            var code: i64 = 0;
            for (ds) |item| switch (doc.resolve(item)) {
                .integer => |i| code = i,
                .name => |n| {
                    if (code >= 0 and code < 256) {
                        const c: usize = @intCast(code);
                        self.names[c] = n;
                        self.unicode[c] = encoding.unicodeOfName(n) orelse 0;
                    }
                    code += 1;
                },
                else => {},
            };
        }

        if (self.subtype == .type3) {
            self.char_procs = doc.getDict(dict, "CharProcs") orelse .{};
            self.resources = doc.getDict(dict, "Resources");
            if (doc.getArray(dict, "FontMatrix")) |m| if (m.len >= 6) {
                for (0..6) |i| self.font_matrix[i] = doc.resolve(m[i]).asNum() orelse self.font_matrix[i];
            };
            self.width_scale = self.font_matrix[0];
            // Type 3 glyph names come from the Differences only.
            if (diffs == null) for (&self.names) |*nm| {
                nm.* = null;
            };
        }

        // Standard 14 metrics when the dictionary carries no widths (9.6.2.2).
        if (self.widths.len == 0 and self.subtype != .type3) {
            if (std_name) |sn| for (std14.fonts) |f| if (std.mem.eql(u8, f.name, sn)) {
                self.std_widths = f.widths;
            };
        }
    }

    /// Name of the standard font a `/BaseFont` stands for, or null.
    fn standard14(base: []const u8) ?[]const u8 {
        const family: []const u8 = if (containsFold(base, "courier")) "Courier" else if (containsFold(base, "helvetica") or containsFold(base, "arial")) "Helvetica" else if (containsFold(base, "times")) "Times" else return null;
        const bold = containsFold(base, "bold");
        const italic = containsFold(base, "italic") or containsFold(base, "oblique");
        if (std.mem.eql(u8, family, "Times")) {
            return if (bold and italic) "Times-BoldItalic" else if (bold) "Times-Bold" else if (italic) "Times-Italic" else "Times-Roman";
        }
        const dash: []const u8 = if (std.mem.eql(u8, family, "Courier")) "Courier" else "Helvetica";
        if (bold and italic) return if (dash[0] == 'C') "Courier-BoldOblique" else "Helvetica-BoldOblique";
        if (bold) return if (dash[0] == 'C') "Courier-Bold" else "Helvetica-Bold";
        if (italic) return if (dash[0] == 'C') "Courier-Oblique" else "Helvetica-Oblique";
        return dash;
    }

    fn containsFold(hay: []const u8, needle: []const u8) bool {
        if (needle.len > hay.len) return false;
        var i: usize = 0;
        while (i + needle.len <= hay.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    // ---- composite fonts ---------------------------------------------------------

    fn loadComposite(self: *Font, doc: *Document, dict: Dict) Allocator.Error!void {
        const a = doc.arena.allocator();
        if (doc.get(dict, "Encoding")) |e| switch (e) {
            .name => |n| {
                if (!std.mem.startsWith(u8, n, "Identity")) self.predefined_cmap = n;
                self.vertical = n.len > 0 and n[n.len - 1] == 'V';
            },
            .stream => |s| {
                const data = doc.streamData(s) catch "";
                self.cid_map = try cmap_mod.parse(a, data);
                if (doc.getInt(s.dict, "WMode")) |wm| self.vertical = wm == 1;
            },
            else => {},
        };
        const desc_arr = doc.getArray(dict, "DescendantFonts") orelse return;
        if (desc_arr.len == 0) return;
        const cf = doc.resolve(desc_arr[0]).asDict() orelse return;
        self.cid_subtype = doc.getName(cf, "Subtype") orelse "";
        if (doc.getName(cf, "BaseFont")) |bf| if (self.base_font.len == 0) {
            self.base_font = stripSubset(bf);
        };
        if (cf.get("FontDescriptor")) |fd| self.loadDescriptor(doc, doc.resolve(fd));
        if (doc.getNum(cf, "DW")) |dw| self.dw = dw;
        if (doc.getArray(cf, "W")) |w| try self.parseW(doc, w);
        if (doc.get(cf, "CIDToGIDMap")) |m| if (m == .stream) {
            self.cid_to_gid = m.stream;
        };
    }

    /// `/W` (9.7.4.3): `c [w1 w2 ...]` or `c_first c_last w`.
    fn parseW(self: *Font, doc: *Document, w: []const Object) Allocator.Error!void {
        const a = doc.arena.allocator();
        var out: std.ArrayList(WidthRange) = .empty;
        var i: usize = 0;
        while (i < w.len) {
            const first = doc.resolve(w[i]).asInt() orelse {
                i += 1;
                continue;
            };
            if (i + 1 >= w.len) break;
            const next = doc.resolve(w[i + 1]);
            if (next.asArray()) |list| {
                for (list, 0..) |item, k| {
                    const wv = doc.resolve(item).asNum() orelse continue;
                    const c: u32 = @intCast(@max(0, first) + @as(i64, @intCast(k)));
                    try out.append(a, .{ .first = c, .last = c, .w = wv });
                    if (out.items.len > 200_000) break;
                }
                i += 2;
            } else if (next.asInt()) |last| {
                if (i + 2 >= w.len) break;
                const wv = doc.resolve(w[i + 2]).asNum() orelse 0;
                try out.append(a, .{ .first = @intCast(@max(0, first)), .last = @intCast(@max(0, last)), .w = wv });
                i += 3;
            } else i += 1;
        }
        std.mem.sortUnstable(WidthRange, out.items, {}, struct {
            fn lt(_: void, x: WidthRange, y: WidthRange) bool {
                return x.first < y.first;
            }
        }.lt);
        self.cid_widths = out.items;
    }

    fn cidWidth(self: *const Font, cid: u32) f64 {
        // Binary search for the last range starting at or before `cid`.
        var lo: usize = 0;
        var hi: usize = self.cid_widths.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.cid_widths[mid].first <= cid) lo = mid + 1 else hi = mid;
        }
        var i = lo;
        var steps: usize = 0;
        while (i > 0 and steps < 16) : (steps += 1) {
            i -= 1;
            const r = self.cid_widths[i];
            if (cid >= r.first and cid <= r.last) return r.w;
        }
        return self.dw;
    }

    // ---- glyphs --------------------------------------------------------------------

    /// One character code of a shown string.
    pub const Glyph = struct {
        /// The character code as written in the string.
        code: u32,
        /// Bytes the code took.
        len: u8,
        /// CID (composite fonts); equals `code` for simple fonts.
        cid: u32,
        /// Advance in em units (multiply by the font size).
        advance: f64,
        /// Code 32 in a one-byte code: word spacing applies (9.3.3).
        is_space: bool,
        /// Unicode text in UTF-8 (may be empty if unknown). Borrowed from the arena.
        text: []const u8,
    };

    /// Splits `s` into glyphs. Memory for `text` comes from `a` (use an arena).
    pub fn glyphs(self: *const Font, a: Allocator, s: []const u8, out: *std.ArrayList(Glyph)) Allocator.Error!void {
        var pos: usize = 0;
        var tmp: std.ArrayList(u8) = .empty;
        while (pos < s.len) {
            var g: Glyph = undefined;
            if (self.isComposite()) {
                const len: u8 = if (self.cid_map) |m| @max(1, m.codeLength(s[pos..], 2)) else @as(u8, @intCast(@min(2, s.len - pos)));
                var code: u32 = 0;
                for (s[pos .. pos + len]) |b| code = (code << 8) | b;
                const cid = if (self.cid_map) |m| (m.cid(code, len) orelse 0) else code;
                g = .{ .code = code, .len = len, .cid = cid, .advance = self.cidWidth(cid) * 0.001, .is_space = len == 1 and code == 32, .text = "" };
                pos += len;
            } else {
                const code: u32 = s[pos];
                g = .{ .code = code, .len = 1, .cid = code, .advance = self.simpleWidth(@intCast(code)) * self.width_scale, .is_space = code == 32, .text = "" };
                pos += 1;
            }
            tmp.clearRetainingCapacity();
            var found = false;
            if (self.to_unicode) |m| found = try m.unicode(a, g.code, g.len, &tmp);
            if (!found and !self.isComposite() and g.code < 256 and self.unicode[g.code] != 0) {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(self.unicode[g.code], &buf) catch 0;
                try tmp.appendSlice(a, buf[0..n]);
            }
            if (tmp.items.len > 0) g.text = try a.dupe(u8, tmp.items);
            try out.append(a, g);
        }
    }

    fn simpleWidth(self: *const Font, code: u8) f64 {
        if (self.widths.len > 0) {
            if (code >= self.first_char and code - self.first_char < self.widths.len) return self.widths[code - self.first_char];
            return self.missing_width;
        }
        if (self.std_widths) |sw| {
            if (self.names[code]) |nm| for (encoding.names, 0..) |n, i| {
                if (std.mem.eql(u8, n[0], nm)) return @floatFromInt(sw[i]);
            };
            return self.missing_width;
        }
        return self.missing_width;
    }

    /// The glyph index a CID selects in a CIDFontType2 font (the CIDToGIDMap).
    pub fn gidOfCid(self: *const Font, doc: *Document, cid: u32) u32 {
        const st = self.cid_to_gid orelse return cid;
        const data = doc.streamData(st) catch return cid;
        const at = @as(usize, cid) * 2;
        if (at + 1 >= data.len) return 0;
        return (@as(u32, data[at]) << 8) | data[at + 1];
    }
};

test "standard 14 matching" {
    try std.testing.expectEqualStrings("Helvetica", Font.standard14("Helvetica").?);
    try std.testing.expectEqualStrings("Helvetica-Bold", Font.standard14("Arial,Bold").?);
    try std.testing.expectEqualStrings("Times-BoldItalic", Font.standard14("TimesNewRomanPS-BoldItalicMT").?);
    try std.testing.expectEqualStrings("Courier-Oblique", Font.standard14("CourierNew,Italic").?);
    try std.testing.expect(Font.standard14("Garamond") == null);
}

test "subset prefix" {
    try std.testing.expectEqualStrings("Foo-Bold", Font.stripSubset("ABCDEF+Foo-Bold"));
    try std.testing.expectEqualStrings("abcdef+Foo", Font.stripSubset("abcdef+Foo"));
    try std.testing.expectEqualStrings("Short", Font.stripSubset("Short"));
}
