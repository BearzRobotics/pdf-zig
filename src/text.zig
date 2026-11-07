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

pub const Order = enum { reading, content };

const Item = struct {
    x0: f64,
    x1: f64,
    y: f64,
    size: f64,
    text: []const u8,
};

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
        try readingOrder(a, items.items, &out);
    } else try contentOrder(a, items.items, &out);
    return out.toOwnedSlice(a);
}

fn collect(a: Allocator, items: *std.ArrayList(Item), t: display.Text, base: display.Matrix) Allocator.Error!void {
    // Glyph space to page: text space, then user space, then the page.
    const to_page = t.tm.mul(t.ctm).mul(base);
    for (t.glyphs) |g| {
        if (g.text.len == 0) continue;
        const p0 = to_page.apply(g.x, t.rise);
        const p1 = to_page.apply(g.x + g.advance * t.size * t.h_scale, t.rise);
        // Size on the page: the vertical scale of the combined matrix times the font size.
        const vscale = @sqrt(to_page.b * to_page.b + to_page.d * to_page.d);
        try items.append(a, .{ .x0 = p0.x, .x1 = p1.x, .y = p0.y, .size = @abs(t.size * vscale), .text = g.text });
    }
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

fn endsWithSpace(s: []const u8) bool {
    return s.len > 0 and s[s.len - 1] == ' ';
}

fn contentOrder(a: Allocator, items: []const Item, out: *std.ArrayList(u8)) Allocator.Error!void {
    var prev: ?Item = null;
    for (items) |it| {
        if (prev) |p| {
            if (@abs(it.y - p.y) > 0.5 * @max(p.size, it.size)) {
                try out.append(a, '\n');
            } else if (gapNeedsSpace(p, it) and !endsWithSpace(p.text) and !startsWithSpace(it.text)) {
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

fn readingOrder(a: Allocator, items: []Item, out: *std.ArrayList(u8)) Allocator.Error!void {
    // Sort by baseline, then x; lines are runs whose baselines are close.
    std.mem.sortUnstable(Item, items, {}, struct {
        fn lt(_: void, p: Item, q: Item) bool {
            if (@abs(p.y - q.y) > 0.5 * @max(p.size, q.size, 1)) return p.y < q.y;
            return p.x0 < q.x0;
        }
    }.lt);
    var line_start: usize = 0;
    while (line_start < items.len) {
        var line_end = line_start + 1;
        const y0 = items[line_start].y;
        while (line_end < items.len and @abs(items[line_end].y - y0) <= 0.5 * @max(items[line_end].size, items[line_start].size, 1)) line_end += 1;
        const line = items[line_start..line_end];
        std.mem.sortUnstable(Item, line, {}, struct {
            fn lt(_: void, p: Item, q: Item) bool {
                return p.x0 < q.x0;
            }
        }.lt);
        var prev: ?Item = null;
        for (line) |it| {
            if (prev) |p| {
                if (gapNeedsSpace(p, it) and !endsWithSpace(p.text) and !startsWithSpace(it.text)) try out.append(a, ' ');
            }
            try appendText(a, out, it.text);
            prev = it;
        }
        try out.append(a, '\n');
        line_start = line_end;
    }
}
