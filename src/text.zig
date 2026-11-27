// SPDX-License-Identifier: LGPL-2.0-or-later
//! Plain text from a display list.
//!
//! Glyphs are placed on the page (top left origin, y down), grouped into lines
//! by their baseline and sorted left to right; a space is inserted where the
//! gap between two glyphs is wider than a fraction of the font size. Text of
//! invisible runs (rendering mode 3, as in scanned documents with an OCR layer)
//! is included. `.content_order` instead keeps the order of the content
//! stream, which is what `pdftotext -raw` does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const display = @import("display.zig");
const font_mod = @import("font.zig");

pub const Order = enum { reading, content };

/// A glyph placed on the displayed page. Positions are measured in the frame of
/// its writing direction: `x0` to `x1` along the baseline and `y` across it,
/// downwards. For horizontal text these are page coordinates.
const Item = struct {
    /// The writing direction in whole degrees clockwise on the page, 0 to 359.
    angle: u16,
    x0: f64,
    x1: f64,
    y: f64,
    size: f64,
    text: []const u8,
    /// The glyph's box on the page.
    box: Rect,
    /// Set by `assignLines`: lines are numbered from the top.
    line: u32 = 0,
};

/// A rectangle on the displayed page: points, origin top left, y down.
pub const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Where a piece of the extracted text sits on the page. Characters the
/// extraction adds itself (spaces between words, line breaks) have no box.
pub const Box = struct {
    /// Byte range of the piece in `Layout.text`.
    start: u32,
    end: u32,
    rect: Rect,
};

/// The text of a page together with the position of every glyph, for
/// selecting, copying and searching on the displayed page.
pub const Layout = struct {
    /// Reading-order text, as `extract(..., .reading)` returns it.
    text: []u8,
    /// One box per glyph that has text, in the order of `text`.
    boxes: []Box,

    pub fn deinit(self: *Layout, a: Allocator) void {
        a.free(self.text);
        a.free(self.boxes);
        self.* = undefined;
    }

    /// The byte offset in `text` of the character nearest to the point
    /// (page coordinates), or null if the page has no text. A point on the
    /// left half of a glyph selects before it, on the right half after it.
    pub fn offsetAt(self: Layout, x: f64, y: f64) ?u32 {
        if (self.boxes.len == 0) return null;
        var best: usize = 0;
        var best_d: f64 = std.math.inf(f64);
        for (self.boxes, 0..) |b, i| {
            const dx = if (x < b.rect.x0) b.rect.x0 - x else if (x > b.rect.x1) x - b.rect.x1 else 0;
            const dy = if (y < b.rect.y0) b.rect.y0 - y else if (y > b.rect.y1) y - b.rect.y1 else 0;
            // A line is far more likely to be meant than a neighbour on another line.
            const d = dx * dx + 4 * dy * dy;
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        const b = self.boxes[best];
        return if (x > (b.rect.x0 + b.rect.x1) / 2) b.end else b.start;
    }

    /// The boxes of the text between byte offsets `from` and `to` (either
    /// order), merged into one rectangle per line, appended to `out`.
    pub fn rectsFor(self: Layout, a: Allocator, from: u32, to: u32, out: *std.ArrayList(Rect)) Allocator.Error!void {
        const lo = @min(from, to);
        const hi = @max(from, to);
        var cur: ?Rect = null;
        for (self.boxes) |b| {
            if (b.end <= lo or b.start >= hi) continue;
            if (cur) |*c| {
                const same_line = @abs((b.rect.y0 + b.rect.y1) - (c.y0 + c.y1)) < 0.5 * (c.y1 - c.y0);
                if (same_line) {
                    c.x0 = @min(c.x0, b.rect.x0);
                    c.x1 = @max(c.x1, b.rect.x1);
                    c.y0 = @min(c.y0, b.rect.y0);
                    c.y1 = @max(c.y1, b.rect.y1);
                    continue;
                }
                try out.append(a, c.*);
            }
            cur = b.rect;
        }
        if (cur) |c| try out.append(a, c);
    }

    /// Byte ranges of every case-insensitive (ASCII) occurrence of `needle`.
    pub fn find(self: Layout, a: Allocator, needle: []const u8, out: *std.ArrayList([2]u32)) Allocator.Error!void {
        if (needle.len == 0 or needle.len > self.text.len) return;
        var i: usize = 0;
        while (i + needle.len <= self.text.len) {
            if (std.ascii.eqlIgnoreCase(self.text[i .. i + needle.len], needle)) {
                try out.append(a, .{ @intCast(i), @intCast(i + needle.len) });
                i += needle.len;
            } else i += 1;
        }
    }
};

/// Extracts the text of `list` in reading order, with a box for each glyph.
/// Free the result with `Layout.deinit(a)`.
pub fn layout(a: Allocator, list: *const display.DisplayList) Allocator.Error!Layout {
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(a);
    for (list.commands) |cmd| switch (cmd) {
        .text => |t| try collect(a, &items, t, list.base),
        else => {},
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var boxes: std.ArrayList(Box) = .empty;
    errdefer boxes.deinit(a);
    try readingOrder(a, items.items, &out, &boxes);
    const owned = try out.toOwnedSlice(a);
    errdefer a.free(owned);
    return .{ .text = owned, .boxes = try boxes.toOwnedSlice(a) };
}

/// Extracts the text of `list`. The result is allocated from `a`.
pub fn extract(a: Allocator, list: *const display.DisplayList, order: Order) Allocator.Error![]u8 {
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(a);
    for (list.commands) |cmd| switch (cmd) {
        .text => |t| try collect(a, &items, t, list.base),
        else => {},
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (order == .reading) {
        try readingOrder(a, items.items, &out, null);
    } else try contentOrder(a, items.items, &out);
    return out.toOwnedSlice(a);
}

fn collect(a: Allocator, items: *std.ArrayList(Item), t: display.Text, base: display.Matrix) Allocator.Error!void {
    // Glyph space to page: text space, then user space, then the page.
    const to_page = t.tm.mul(t.ctm).mul(base);
    // The height of an em in text space units: the font size, except for a
    // Type 3 font, whose font matrix and bounding box say how large it is.
    const em = t.size * emScale(t.font);
    for (t.glyphs) |g| {
        if (g.text.len == 0) continue;
        const p0 = to_page.apply(g.x, t.rise);
        const p1 = to_page.apply(g.x + g.advance * t.size * t.h_scale, t.rise);
        // Size on the page: the length of the image of the unit y vector, (c, d),
        // times the font size.
        const vscale = @sqrt(to_page.c * to_page.c + to_page.d * to_page.d);
        // The box spans the advance and, vertically, a descent of 0.2 and an
        // ascent of 0.8 of the font size, which fits most fonts closely enough
        // to show a selection.
        const right = g.x + g.advance * t.size * t.h_scale;
        const low = t.rise - 0.2 * em;
        const high = t.rise + 0.8 * em;
        // All four corners: tilted or sheared, any of them can be an extreme.
        const first = to_page.apply(g.x, low);
        var box: Rect = .{ .x0 = first.x, .y0 = first.y, .x1 = first.x, .y1 = first.y };
        for ([_]display.Point{ to_page.apply(right, low), to_page.apply(right, high), to_page.apply(g.x, high) }) |corner| {
            box = .{ .x0 = @min(box.x0, corner.x), .y0 = @min(box.y0, corner.y), .x1 = @max(box.x1, corner.x), .y1 = @max(box.y1, corner.y) };
        }
        const angle = writingAngle(to_page, t.size * t.h_scale);
        // Every glyph of one direction is measured in the same frame.
        const radians = @as(f64, @floatFromInt(angle)) * std.math.pi / 180.0;
        const along: display.Point = .{ .x = @cos(radians), .y = @sin(radians) };
        const across: display.Point = .{ .x = -along.y, .y = along.x };
        try items.append(a, .{
            .angle = angle,
            .x0 = p0.x * along.x + p0.y * along.y,
            .x1 = p1.x * along.x + p1.y * along.y,
            .y = p0.x * across.x + p0.y * across.y,
            .size = @abs(em * vscale),
            .text = g.text,
            .box = box,
        });
    }
}

/// What a font size of 1 is in em heights: 1, but for a Type 3 font the height
/// of its bounding box under its font matrix, when it gives one.
fn emScale(f: *const font_mod.Font) f64 {
    if (f.subtype != .type3) return 1;
    const height = @abs((f.font_bbox[3] - f.font_bbox[1]) * f.font_matrix[3]);
    return if (height > 0 and std.math.isFinite(height)) height else 1;
}

/// The direction glyphs advance in, in whole degrees clockwise on the page.
/// `advance` is the size and horizontal scale, whose sign can reverse it.
fn writingAngle(to_page: display.Matrix, advance: f64) u16 {
    const sign: f64 = if (advance < 0) -1 else 1;
    const degrees = std.math.atan2(sign * to_page.b, sign * to_page.a) * 180.0 / std.math.pi;
    if (!std.math.isFinite(degrees)) return 0;
    return @intFromFloat(@mod(@round(degrees), 360.0));
}

/// Appends `s`, expanding the Latin ligature code points U+FB00..U+FB06 into
/// letters (as `pdftotext` does), so that "ﬁle" is found when searching "file".
fn appendText(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        // U+FB00..U+FB06 are the UTF-8 bytes EF AC 80..86.
        if (i + 2 < s.len and s[i] == 0xEF and s[i + 1] == 0xAC and s[i + 2] >= 0x80 and s[i + 2] <= 0x86) {
            const rep = switch (s[i + 2]) {
                0x80 => "ff",
                0x81 => "fi",
                0x82 => "fl",
                0x83 => "ffi",
                0x84 => "ffl",
                else => "st",
            };
            try out.appendSlice(a, rep);
            i += 3;
            continue;
        }
        try out.append(a, s[i]);
        i += 1;
    }
}

fn gapNeedsSpace(prev: Item, next: Item) bool {
    const gap = next.x0 - prev.x1;
    return gap > 0.15 * @max(prev.size, next.size);
}

/// The pen went back well before where the previous glyph started, as between
/// two words drawn out of order. Kerning and overstriking stay closer.
fn jumpsBack(prev: Item, next: Item) bool {
    return next.x0 < prev.x0 - 0.5 * @max(prev.size, next.size);
}

fn endsWithSpace(s: []const u8) bool {
    return s.len > 0 and s[s.len - 1] == ' ';
}

fn contentOrder(a: Allocator, items: []const Item, out: *std.ArrayList(u8)) Allocator.Error!void {
    var prev: ?Item = null;
    for (items) |it| {
        if (prev) |p| {
            if (it.angle != p.angle or @abs(it.y - p.y) > 0.5 * @max(p.size, it.size)) {
                try out.append(a, '\n');
            } else if ((gapNeedsSpace(p, it) or jumpsBack(p, it)) and !endsWithSpace(p.text) and !startsWithSpace(it.text)) {
                try out.append(a, ' ');
            }
        }
        try appendText(a, out, it.text);
        prev = it;
    }
    if (out.items.len > 0) try out.append(a, '\n');
}

fn startsWithSpace(s: []const u8) bool {
    return s.len > 0 and s[0] == ' ';
}

/// Glyphs that share a baseline.
const Baseline = struct {
    start: usize,
    count: usize,
    y: f64,
    /// The size most of its glyphs have: one large label that happens to
    /// share a baseline must not widen what counts as close to it.
    size: f64,
    /// For finding that size (a majority vote).
    votes: usize = 1,
    angle: u16,
    /// The baseline whose line this one belongs to; itself for a line's own.
    line: ?u32 = null,
};

/// How many neighbouring baselines are looked at for a line to join.
const nearby_baselines = 16;

/// Numbers the lines of `items`, which are sorted by direction and then
/// position across it. Lines form around the baselines with the most text; a
/// smaller piece close to one (a superscript, a part of a fraction, a drop cap)
/// joins the nearest. "Close" is only ever measured from a line's own
/// baseline, so no piece can pull two lines together.
fn assignLines(a: Allocator, items: []Item) Allocator.Error!void {
    var baselines: std.ArrayList(Baseline) = .empty;
    defer baselines.deinit(a);
    for (items, 0..) |it, i| {
        if (baselines.items.len > 0) {
            const last = &baselines.items[baselines.items.len - 1];
            if (it.angle == last.angle and @abs(it.y - last.y) <= 0.1 * @max(it.size, 1)) {
                last.count += 1;
                if (it.size == last.size) {
                    last.votes += 1;
                } else if (last.votes > 0) {
                    last.votes -= 1;
                } else {
                    last.size = it.size;
                    last.votes = 1;
                }
                continue;
            }
        }
        try baselines.append(a, .{ .start = i, .count = 1, .y = it.y, .size = it.size, .angle = it.angle });
    }
    const order = try a.alloc(u32, baselines.items.len);
    defer a.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    std.mem.sort(u32, order, baselines.items, struct {
        fn lt(all: []Baseline, x: u32, y: u32) bool {
            return if (all[x].count != all[y].count) all[x].count > all[y].count else x < y;
        }
    }.lt);
    const all = baselines.items;
    for (order) |i| {
        const this = &all[i];
        var best: ?u32 = null;
        var best_distance = std.math.inf(f64);
        for (i -| nearby_baselines..@min(all.len, i + nearby_baselines + 1)) |j| {
            const line = all[j].line orelse continue;
            const own = all[line];
            const distance = @abs(own.y - this.y);
            if (own.angle == this.angle and distance <= 0.5 * @max(this.size, own.size, 1) and distance < best_distance) {
                best = line;
                best_distance = distance;
            }
        }
        this.line = best orelse i;
    }
    for (all) |baseline| {
        for (items[baseline.start..][0..baseline.count]) |*it| it.line = baseline.line.?;
    }
}

/// A total order of coordinates: NaN, which damaged files can produce, sorts
/// after every number.
fn coordinateOrder(x: f64, y: f64) std.math.Order {
    if (std.math.isNan(x) or std.math.isNan(y)) {
        return std.math.order(@intFromBool(std.math.isNan(x)), @intFromBool(std.math.isNan(y)));
    }
    return std.math.order(x, y);
}

fn readingOrder(a: Allocator, items: []Item, out: *std.ArrayList(u8), boxes: ?*std.ArrayList(Box)) Allocator.Error!void {
    // Sort by baseline, then x; lines are runs whose baselines are close.
    // "Close" is not transitive, so it must not be part of the sort order: a
    // large letter would be close to several small lines and mix them up.
    std.mem.sort(Item, items, {}, struct {
        fn lt(_: void, p: Item, q: Item) bool {
            // Horizontal text first, then each other direction on its own.
            if (p.angle != q.angle) return p.angle < q.angle;
            return switch (coordinateOrder(p.y, q.y)) {
                .lt => true,
                .gt => false,
                .eq => coordinateOrder(p.x0, q.x0) == .lt,
            };
        }
    }.lt);
    try assignLines(a, items);
    std.mem.sort(Item, items, {}, struct {
        fn lt(_: void, p: Item, q: Item) bool {
            return if (p.line != q.line) p.line < q.line else coordinateOrder(p.x0, q.x0) == .lt;
        }
    }.lt);
    var line_start: usize = 0;
    while (line_start < items.len) {
        var line_end = line_start + 1;
        while (line_end < items.len and items[line_end].line == items[line_start].line) line_end += 1;
        const line = items[line_start..line_end];
        var prev: ?Item = null;
        for (line) |it| {
            if (prev) |p| {
                if (gapNeedsSpace(p, it) and !endsWithSpace(p.text) and !startsWithSpace(it.text)) try out.append(a, ' ');
            }
            const start = out.items.len;
            try appendText(a, out, it.text);
            if (boxes) |bl| try bl.append(a, .{ .start = @intCast(start), .end = @intCast(out.items.len), .rect = it.box });
            prev = it;
        }
        try out.append(a, '\n');
        line_start = line_end;
    }
}

test "layout: boxes follow the glyphs, selection and search map to rectangles" {
    const tests = @import("interp_tests.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try tests.render(try tests.page(arena.allocator(), "BT /F1 10 Tf 20 50 Td (Hello big world) Tj ET", "/Font << /F1 5 0 R >>", &.{"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>"}, ""));
    defer tests.done(r);
    var lay = try layout(std.testing.allocator, &r.list);
    defer lay.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello big world\n", lay.text);

    // Courier: 6 points per character at size 10, baseline y = 100 - 50 on the page.
    const first = lay.boxes[0].rect;
    try std.testing.expectApproxEqAbs(@as(f64, 20), first.x0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 26), first.x1, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 42), first.y0, 0.01); // baseline 50 minus ascent 8
    try std.testing.expectApproxEqAbs(@as(f64, 52), first.y1, 0.01); // baseline plus descent 2

    // A click in the left half of "b" (index 6) selects before it; in the right half, after it.
    try std.testing.expectEqual(@as(?u32, 6), lay.offsetAt(20 + 6 * 6 + 1, 48));
    try std.testing.expectEqual(@as(?u32, 7), lay.offsetAt(20 + 6 * 6 + 5, 48));
    // Far to the right of the line: the end of its last glyph.
    try std.testing.expectEqual(@as(?u32, 15), lay.offsetAt(500, 48));

    var found: std.ArrayList([2]u32) = .empty;
    defer found.deinit(std.testing.allocator);
    try lay.find(std.testing.allocator, "BIG", &found);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual([2]u32{ 6, 9 }, found.items[0]);

    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(std.testing.allocator);
    try lay.rectsFor(std.testing.allocator, found.items[0][0], found.items[0][1], &rects);
    try std.testing.expectEqual(@as(usize, 1), rects.items.len); // one line, one rectangle
    try std.testing.expectApproxEqAbs(@as(f64, 56), rects.items[0].x0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 74), rects.items[0].x1, 0.01);
}

test "layout frees everything when an allocation fails" {
    const tests = @import("interp_tests.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try tests.render(try tests.page(arena.allocator(), "BT /F1 10 Tf 20 50 Td (a line long enough to reallocate while it grows) Tj 0 -12 Td (and another) Tj ET", "/Font << /F1 5 0 R >>", &.{"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>"}, ""));
    defer tests.done(r);
    const Check = struct {
        fn both(a: Allocator, list: *const display.DisplayList) !void {
            var lay = try layout(a, list);
            lay.deinit(a);
            a.free(try extract(a, list, .content));
        }
    };
    // Resizing is refused, so that turning the lists into slices allocates.
    var strict = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(strict.allocator(), Check.both, .{&r.list});
}
