// SPDX-License-Identifier: LGPL-2.0-or-later
//! Drawing page content (docs/decisions/0005-drawing-content.md). A `Canvas`
//! records paths, text and images; `compose.Builder.addPage` makes a page of
//! it, and a `Stamp` puts it on a page of an existing file.
//!
//! **Coordinates are those of the page as seen:** points, the origin at the top
//! left, y downward, as in `text.Layout` and the annotation functions.
//!
//! A canvas only ever makes valid content: a call that would not is an error and
//! adds nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const display = @import("display.zig");
const encoding = @import("encoding.zig");
const std14 = @import("std14.zig");
const serial = @import("write.zig");
const pack = @import("compose_pack.zig");
const pages = @import("pages.zig");
const interp = @import("interp.zig");
const page_edit = @import("page_edit.zig");

const Matrix = display.Matrix;
const Dict = object.Dict;

pub const Error = error{
    /// A number that is not finite or is out of range, a colour component
    /// outside 0 to 1, or text that is not one line of UTF-8.
    BadValue,
    /// `restore` without a `save`.
    UnbalancedRestore,
    /// `lineTo`, `curveTo` or `close` before `moveTo` or `rect`.
    NoCurrentPoint,
    /// Painting or clipping without a path.
    NoPath,
    /// A path is being built: only path calls may come before it is painted or
    /// used to clip (8.2).
    PathOpen,
    /// The font has no glyph for one of the characters. Nothing was drawn.
    MissingGlyph,
    /// More content than `max_content_bytes`, or `save` nested too deeply.
    TooLarge,
    OutOfMemory,
};

/// Most content one canvas holds.
pub const max_content_bytes = 64 << 20;
/// Deepest nesting of `save` (what readers can be expected to follow).
pub const max_saved = 256;
const max_value = 1e7;

pub const Color = union(enum) {
    gray: f64,
    rgb: [3]f64,
    cmyk: [4]f64,

    pub const black: Color = .{ .gray = 0 };
    pub const white: Color = .{ .gray = 1 };
};

/// The blend modes of 11.3.5.
pub const BlendMode = enum {
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    ColorDodge,
    ColorBurn,
    HardLight,
    SoftLight,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity,
};

// ---- fonts ---------------------------------------------------------------------------------

/// The twelve text fonts every reader has (9.6.2.2). They take the characters
/// of WinAnsi.
pub const Builtin = enum {
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    times_roman,
    times_bold,
    times_italic,
    times_bold_italic,

    pub fn baseFont(self: Builtin) []const u8 {
        // `std14.fonts` has them in the order of this enum.
        return std14.fonts[@backingInt(self)].name;
    }

    /// The advance of WinAnsi `code` in 1/1000 em.
    fn width(self: Builtin, code: u8) u16 {
        // A no-break space is as wide as a space.
        const u = encoding.unicodeOf(.win_ansi, if (code == 0xA0) ' ' else code);
        const widths = std14.fonts[@backingInt(self)].widths;
        for (encoding.names, 0..) |n, i| {
            if (n[1] == u and i < widths.len and widths[i] != 0) return widths[i];
        }
        return if (@backingInt(self) < 4) 600 else 500;
    }
};

pub const Font = union(enum) {
    builtin: Builtin,

    pub const courier: Font = .{ .builtin = .courier };
    pub const courier_bold: Font = .{ .builtin = .courier_bold };
    pub const courier_oblique: Font = .{ .builtin = .courier_oblique };
    pub const courier_bold_oblique: Font = .{ .builtin = .courier_bold_oblique };
    pub const helvetica: Font = .{ .builtin = .helvetica };
    pub const helvetica_bold: Font = .{ .builtin = .helvetica_bold };
    pub const helvetica_oblique: Font = .{ .builtin = .helvetica_oblique };
    pub const helvetica_bold_oblique: Font = .{ .builtin = .helvetica_bold_oblique };
    pub const times_roman: Font = .{ .builtin = .times_roman };
    pub const times_bold: Font = .{ .builtin = .times_bold };
    pub const times_italic: Font = .{ .builtin = .times_italic };
    pub const times_bold_italic: Font = .{ .builtin = .times_bold_italic };

    /// Whether every character of `text` can be drawn.
    pub fn covers(_: Font, text: []const u8) bool {
        var view = std.unicode.Utf8View.init(text) catch return false;
        var it = view.iterator();
        while (it.nextCodepoint()) |c| if (winAnsiCode(c) == null) return false;
        return true;
    }

    /// The width of `text` at `size` points.
    pub fn textWidth(self: Font, size: f64, text: []const u8) error{ BadValue, MissingGlyph }!f64 {
        var view = std.unicode.Utf8View.init(text) catch return error.BadValue;
        var it = view.iterator();
        var units: f64 = 0;
        while (it.nextCodepoint()) |c| {
            if (c < 0x20) return error.BadValue;
            units += @floatFromInt(self.builtin.width(winAnsiCode(c) orelse return error.MissingGlyph));
        }
        return units * size / 1000;
    }
};

/// The WinAnsi code of character `c`, or null when it has none.
fn winAnsiCode(c: u21) ?u8 {
    if (c >= 0x20 and c < 0x7F) return @intCast(c);
    if (c >= 0xA0 and c <= 0xFF and c != 0xAD) return @intCast(c);
    // 0x95 is the bullet; the unused codes are also read as one.
    if (c == 0x2022) return 0x95;
    var code: u16 = 0x80;
    while (code < 0xA0) : (code += 1) {
        const u = encoding.unicodeOf(.win_ansi, @intCast(code));
        if (u == c and u != 0x2022) return @intCast(code);
    }
    return null;
}

// ---- images --------------------------------------------------------------------------------

pub const ImageError = error{
    /// Not the kind of data the function takes, or damaged.
    BadImage,
    /// A kind of image that is not taken: see the function.
    UnsupportedImage,
    TooLarge,
    OutOfMemory,
};

/// Largest width or height of an image.
const max_image_side = 1 << 16;
/// Most pixels of a raw image.
const max_pixels = 1 << 28;

/// A picture ready to be placed. It owns its data, and the same picture is
/// stored once however often it is drawn.
pub const Image = struct {
    gpa: Allocator,
    width: u32,
    height: u32,
    /// 1 for gray, 3 for colour.
    components: u8,
    /// The data is a JPEG file; else samples compressed for `/FlateDecode`.
    jpeg: bool,
    data: []const u8,
    /// Alpha samples, compressed, if the image has them.
    alpha: ?[]const u8 = null,
    /// A digest of all of the above: equal images are one.
    digest: [32]u8,

    pub fn deinit(self: *Image) void {
        self.gpa.free(self.data);
        if (self.alpha) |a| self.gpa.free(a);
        self.* = undefined;
    }

    /// A JPEG file, stored as it is (7.4.8): baseline, extended or progressive
    /// with 8 bits, gray or three components. CMYK files are not taken, as they
    /// differ in whether their values are inverted.
    pub fn fromJpeg(gpa: Allocator, bytes: []const u8) ImageError!Image {
        const header = try jpegHeader(bytes);
        const data = try gpa.dupe(u8, bytes);
        return finish(.{ .gpa = gpa, .width = header.width, .height = header.height, .components = header.components, .jpeg = true, .data = data, .digest = undefined });
    }

    pub const Pixels = struct {
        width: u32,
        height: u32,
        format: enum { gray, rgb },
        /// Rows from the top, 8 bits per component, without padding.
        samples: []const u8,
        /// One byte per pixel, 255 opaque.
        alpha: ?[]const u8 = null,
    };

    pub fn fromPixels(gpa: Allocator, pixels: Pixels) ImageError!Image {
        if (pixels.width == 0 or pixels.height == 0) return error.BadImage;
        if (pixels.width > max_image_side or pixels.height > max_image_side) return error.TooLarge;
        const count = @as(u64, pixels.width) * pixels.height;
        if (count > max_pixels) return error.TooLarge;
        const components: u8 = if (pixels.format == .gray) 1 else 3;
        if (pixels.samples.len != count * components) return error.BadImage;
        if (pixels.alpha) |a| if (a.len != count) return error.BadImage;
        const data = try pack.compress(gpa, pixels.samples);
        errdefer gpa.free(data);
        const alpha = if (pixels.alpha) |a| try pack.compress(gpa, a) else null;
        return finish(.{ .gpa = gpa, .width = pixels.width, .height = pixels.height, .components = components, .jpeg = false, .data = data, .alpha = alpha, .digest = undefined });
    }

    fn finish(image: Image) Image {
        var out = image;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var head: [11]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], out.width, .little);
        std.mem.writeInt(u32, head[4..8], out.height, .little);
        head[8] = out.components;
        head[9] = @intFromBool(out.jpeg);
        head[10] = @intFromBool(out.alpha != null);
        hash.update(&head);
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, out.data.len, .little);
        hash.update(&length);
        hash.update(out.data);
        if (out.alpha) |a| hash.update(a);
        hash.final(&out.digest);
        return out;
    }

    /// An independent copy, allocated from `a`.
    fn dupe(self: Image, a: Allocator) Allocator.Error!Image {
        var out = self;
        out.gpa = a;
        out.data = try a.dupe(u8, self.data);
        errdefer a.free(out.data);
        if (self.alpha) |alpha| out.alpha = try a.dupe(u8, alpha);
        return out;
    }
};

/// The size and number of components that a JPEG file's frame header gives
/// (ITU-T T.81, B.2).
fn jpegHeader(bytes: []const u8) error{ BadImage, UnsupportedImage }!struct { width: u32, height: u32, components: u8 } {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return error.BadImage;
    var i: usize = 2;
    while (i + 1 < bytes.len) {
        if (bytes[i] != 0xFF) return error.BadImage;
        const marker = bytes[i + 1];
        // Fill bytes, and markers without a length.
        if (marker == 0xFF) {
            i += 1;
            continue;
        }
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
            i += 2;
            continue;
        }
        if (marker == 0xD9 or marker == 0xDA) return error.BadImage; // no frame before the data
        if (i + 4 > bytes.len) return error.BadImage;
        const length = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (length < 2 or i + 2 + length > bytes.len) return error.BadImage;
        // A frame header: 0xC0 to 0xCF, but not the table markers among them.
        if (marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
            if (marker > 0xC2) return error.UnsupportedImage;
            if (length < 8) return error.BadImage;
            const frame = bytes[i + 4 ..];
            if (frame[0] != 8) return error.UnsupportedImage;
            const height = std.mem.readInt(u16, frame[1..3], .big);
            const width = std.mem.readInt(u16, frame[3..5], .big);
            const components = frame[5];
            // A height of zero is given later in the file, which readers of
            // PDF need not follow.
            if (width == 0 or height == 0) return error.UnsupportedImage;
            if (components != 1 and components != 3) return error.UnsupportedImage;
            if (length < 8 + @as(u16, components) * 3) return error.BadImage;
            return .{ .width = width, .height = height, .components = components };
        }
        i += 2 + @as(usize, length);
    }
    return error.BadImage;
}

// ---- the canvas ----------------------------------------------------------------------------

const GraphicsState = struct { fill_alpha: f64, stroke_alpha: f64, blend: BlendMode };

pub const TextMode = enum(u8) {
    fill = 0,
    stroke = 1,
    fill_stroke = 2,
    /// Not drawn, but selected and searched: a text layer over a scan.
    invisible = 3,
};

pub const TextOptions = struct {
    mode: TextMode = .fill,
    /// Stretch or squeeze the line to this width in points.
    fit_width: ?f64 = null,
};

pub const Canvas = struct {
    gpa: Allocator,
    /// The size of the page in points.
    width: f64,
    height: f64,
    content: std.ArrayList(u8) = .empty,
    /// The built-in fonts the content names.
    fonts: std.EnumSet(Builtin) = .empty,
    /// The images drawn, owned copies; image `i` is `/Im{i}`.
    images: std.ArrayList(Image) = .empty,
    /// Graphics states; number `i` is `/Gs{i}`.
    states: std.ArrayList(GraphicsState) = .empty,
    /// What alpha and blend mode are in force, and what each `save` holds.
    current: GraphicsState = .{ .fill_alpha = 1, .stroke_alpha = 1, .blend = .Normal },
    saved: std.ArrayList(GraphicsState) = .empty,
    path: enum { none, open, open_without_point } = .none,

    /// A canvas for a page of `width` by `height` points.
    pub fn init(gpa: Allocator, width: f64, height: f64) Error!Canvas {
        if (!(width > 0 and height > 0 and width <= max_value and height <= max_value)) return error.BadValue;
        return .{ .gpa = gpa, .width = width, .height = height };
    }

    pub fn deinit(self: *Canvas) void {
        self.content.deinit(self.gpa);
        for (self.images.items) |*held| held.deinit();
        self.images.deinit(self.gpa);
        self.states.deinit(self.gpa);
        self.saved.deinit(self.gpa);
        self.* = undefined;
    }

    // -- writing ---------------------------------------------------------------------------

    /// Appends the numbers and then `operator`, or nothing at all.
    fn op(self: *Canvas, numbers: []const f64, operator: []const u8) Error!void {
        try check(numbers);
        const at = self.content.items.len;
        errdefer self.content.shrinkRetainingCapacity(at);
        for (numbers) |n| try self.number(n);
        try self.append(operator);
        try self.append("\n");
    }

    fn check(numbers: []const f64) Error!void {
        // False for NaN too.
        for (numbers) |n| if (!(@abs(n) <= max_value)) return error.BadValue;
    }

    fn number(self: *Canvas, n: f64) Error!void {
        var buffer: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        serial.writeObject(&w, .{ .real = n }) catch return error.BadValue;
        try self.append(w.buffered());
        try self.append(" ");
    }

    fn append(self: *Canvas, bytes: []const u8) Error!void {
        if (bytes.len > max_content_bytes -| self.content.items.len) return error.TooLarge;
        try self.content.appendSlice(self.gpa, bytes);
    }

    fn requireNoPath(self: *const Canvas) Error!void {
        if (self.path != .none) return error.PathOpen;
    }

    /// A point in PDF's space, where y goes up.
    fn flip(self: *const Canvas, y: f64) f64 {
        return self.height - y;
    }

    // -- state -----------------------------------------------------------------------------

    pub fn save(self: *Canvas) Error!void {
        try self.requireNoPath();
        if (self.saved.items.len >= max_saved) return error.TooLarge;
        try self.saved.ensureUnusedCapacity(self.gpa, 1);
        try self.op(&.{}, "q");
        self.saved.appendAssumeCapacity(self.current);
    }

    pub fn restore(self: *Canvas) Error!void {
        try self.requireNoPath();
        if (self.saved.items.len == 0) return error.UnbalancedRestore;
        try self.op(&.{}, "Q");
        self.current = self.saved.pop().?;
    }

    /// Transforms what follows: a point drawn afterwards at `p` appears at
    /// `p` mapped by `m`, in the canvas's coordinates. `restore` undoes it.
    pub fn transform(self: *Canvas, m: Matrix) Error!void {
        try self.requireNoPath();
        try check(&.{ m.a, m.b, m.c, m.d, m.e, m.f });
        // Into the canvas's space, the transformation, and back.
        const turn: Matrix = .{ .a = 1, .b = 0, .c = 0, .d = -1, .e = 0, .f = self.height };
        const c = turn.mul(m).mul(turn);
        try self.op(&.{ c.a, c.b, c.c, c.d, c.e, c.f }, "cm");
    }

    fn color(self: *Canvas, value: Color, for_stroke: bool) Error!void {
        try self.requireNoPath();
        const components: []const f64 = switch (value) {
            .gray => |*g| g[0..1],
            .rgb => |*c| c,
            .cmyk => |*c| c,
        };
        for (components) |c| if (!(c >= 0 and c <= 1)) return error.BadValue;
        try self.op(components, switch (value) {
            .gray => if (for_stroke) "G" else "g",
            .rgb => if (for_stroke) "RG" else "rg",
            .cmyk => if (for_stroke) "K" else "k",
        });
    }

    pub fn setFill(self: *Canvas, value: Color) Error!void {
        return self.color(value, false);
    }

    pub fn setStroke(self: *Canvas, value: Color) Error!void {
        return self.color(value, true);
    }

    pub fn setLineWidth(self: *Canvas, w: f64) Error!void {
        try self.requireNoPath();
        if (!(w >= 0)) return error.BadValue;
        try self.op(&.{w}, "w");
    }

    pub fn setLineCap(self: *Canvas, cap: display.Cap) Error!void {
        try self.requireNoPath();
        try self.op(&.{switch (cap) {
            .butt => 0,
            .round => 1,
            .square => 2,
        }}, "J");
    }

    pub fn setLineJoin(self: *Canvas, join: display.Join) Error!void {
        try self.requireNoPath();
        try self.op(&.{switch (join) {
            .miter => 0,
            .round => 1,
            .bevel => 2,
        }}, "j");
    }

    /// Dashes and gaps in points; an empty pattern is a solid line.
    pub fn setDash(self: *Canvas, pattern: []const f64, phase: f64) Error!void {
        try self.requireNoPath();
        if (pattern.len > 32) return error.BadValue;
        var sum: f64 = 0;
        for (pattern) |v| {
            if (!(v >= 0 and v <= max_value)) return error.BadValue;
            sum += v;
        }
        // All zeros draws nothing, and the specification does not allow it.
        if (pattern.len > 0 and sum == 0) return error.BadValue;
        if (!(phase >= 0 and phase <= max_value)) return error.BadValue;
        const at = self.content.items.len;
        errdefer self.content.shrinkRetainingCapacity(at);
        try self.append("[ ");
        for (pattern) |v| try self.number(v);
        try self.append("] ");
        try self.op(&.{phase}, "d");
    }

    fn setState(self: *Canvas, wanted: GraphicsState) Error!void {
        try self.requireNoPath();
        var index: ?usize = null;
        for (self.states.items, 0..) |s, i| if (std.meta.eql(s, wanted)) {
            index = i;
        };
        if (index == null) {
            if (self.states.items.len >= 4096) return error.TooLarge;
            try self.states.ensureUnusedCapacity(self.gpa, 1);
        }
        var name: [24]u8 = undefined;
        try self.op(&.{}, std.fmt.bufPrint(&name, "/Gs{d} gs", .{index orelse self.states.items.len}) catch unreachable);
        if (index == null) self.states.appendAssumeCapacity(wanted);
        self.current = wanted;
    }

    /// Opacity of what is filled and stroked from here on, 0 to 1.
    pub fn setAlpha(self: *Canvas, fill_alpha: f64, stroke_alpha: f64) Error!void {
        for ([_]f64{ fill_alpha, stroke_alpha }) |v| if (!(v >= 0 and v <= 1)) return error.BadValue;
        return self.setState(.{ .fill_alpha = fill_alpha, .stroke_alpha = stroke_alpha, .blend = self.current.blend });
    }

    pub fn setBlend(self: *Canvas, blend: BlendMode) Error!void {
        return self.setState(.{ .fill_alpha = self.current.fill_alpha, .stroke_alpha = self.current.stroke_alpha, .blend = blend });
    }

    // -- paths -----------------------------------------------------------------------------

    pub fn moveTo(self: *Canvas, x: f64, y: f64) Error!void {
        try self.op(&.{ x, self.flip(y) }, "m");
        self.path = .open;
    }

    fn requirePoint(self: *const Canvas) Error!void {
        if (self.path != .open) return error.NoCurrentPoint;
    }

    pub fn lineTo(self: *Canvas, x: f64, y: f64) Error!void {
        try self.requirePoint();
        try self.op(&.{ x, self.flip(y) }, "l");
    }

    /// A cubic Bezier curve to (`x`, `y`) with control points 1 and 2.
    pub fn curveTo(self: *Canvas, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) Error!void {
        try self.requirePoint();
        try self.op(&.{ x1, self.flip(y1), x2, self.flip(y2), x, self.flip(y) }, "c");
    }

    pub fn close(self: *Canvas) Error!void {
        try self.requirePoint();
        try self.op(&.{}, "h");
    }

    /// A rectangle with its top left corner at (`x`, `y`).
    pub fn rect(self: *Canvas, x: f64, y: f64, w: f64, h: f64) Error!void {
        if (!(w >= 0 and h >= 0)) return error.BadValue;
        try self.op(&.{ x, self.flip(y + h), w, h }, "re");
        self.path = .open;
    }

    fn paint(self: *Canvas, operator: []const u8) Error!void {
        if (self.path == .none) return error.NoPath;
        try self.op(&.{}, operator);
        self.path = .none;
    }

    pub fn fill(self: *Canvas, rule: display.FillRule) Error!void {
        return self.paint(if (rule == .even_odd) "f*" else "f");
    }

    pub fn stroke(self: *Canvas) Error!void {
        return self.paint("S");
    }

    pub fn fillStroke(self: *Canvas, rule: display.FillRule) Error!void {
        return self.paint(if (rule == .even_odd) "B*" else "B");
    }

    /// Limits what follows to the path, until `restore`.
    pub fn clip(self: *Canvas, rule: display.FillRule) Error!void {
        return self.paint(if (rule == .even_odd) "W* n" else "W n");
    }

    // -- text and images ---------------------------------------------------------------------

    /// One line of UTF-8 in `font` at `size` points, in the fill colour, its
    /// baseline starting at (`x`, `y`).
    pub fn text(self: *Canvas, font: Font, size: f64, x: f64, y: f64, line: []const u8) Error!void {
        return self.textWith(font, size, x, y, line, .{});
    }

    pub fn textWith(self: *Canvas, font: Font, size: f64, x: f64, y: f64, line: []const u8, options: TextOptions) Error!void {
        try self.requireNoPath();
        if (!(size > 0 and size <= max_value)) return error.BadValue;
        try check(&.{ x, y });
        const natural = try font.textWidth(size, line);
        if (line.len == 0) return;
        var stretch: f64 = 100;
        if (options.fit_width) |w| {
            if (!(w > 0 and w <= max_value) or !(natural > 0)) return error.BadValue;
            stretch = w / natural * 100;
        }
        const at = self.content.items.len;
        errdefer self.content.shrinkRetainingCapacity(at);
        // The rendering mode and the scaling outlast a text object, so both are
        // always given.
        var head: [64]u8 = undefined;
        try self.append(std.fmt.bufPrint(&head, "BT /F{d} ", .{@backingInt(font.builtin)}) catch unreachable);
        try self.number(size);
        try self.append("Tf ");
        try self.number(stretch);
        try self.append(std.fmt.bufPrint(&head, "Tz {d} Tr 1 0 0 1 ", .{@backingInt(options.mode)}) catch unreachable);
        try self.number(x);
        try self.number(self.flip(y));
        try self.append("Tm (");
        var view = std.unicode.Utf8View.initUnchecked(line);
        var it = view.iterator();
        while (it.nextCodepoint()) |c| {
            const code = winAnsiCode(c).?;
            var escaped: [4]u8 = undefined;
            try self.append(if (code == '(' or code == ')' or code == '\\')
                std.fmt.bufPrint(&escaped, "\\{c}", .{code}) catch unreachable
            else if (code >= 0x20 and code < 0x7F)
                std.fmt.bufPrint(&escaped, "{c}", .{code}) catch unreachable
            else
                std.fmt.bufPrint(&escaped, "\\{o:0>3}", .{code}) catch unreachable);
        }
        try self.append(") Tj ET\n");
        self.fonts.insert(font.builtin);
    }

    /// Draws `image` into the rectangle with its top left corner at (`x`, `y`).
    /// The canvas keeps a copy, so the image can be freed.
    pub fn image(self: *Canvas, picture: *const Image, x: f64, y: f64, w: f64, h: f64) Error!void {
        try self.requireNoPath();
        if (!(w > 0 and h > 0)) return error.BadValue;
        try check(&.{ x, y, w, h });
        var index: ?usize = null;
        for (self.images.items, 0..) |held, i| if (std.mem.eql(u8, &held.digest, &picture.digest)) {
            index = i;
        };
        var added: ?Image = null;
        errdefer if (added) |*copy| copy.deinit();
        if (index == null) {
            if (self.images.items.len >= 4096) return error.TooLarge;
            try self.images.ensureUnusedCapacity(self.gpa, 1);
            added = try picture.dupe(self.gpa);
        }
        const at = self.content.items.len;
        errdefer self.content.shrinkRetainingCapacity(at);
        var name: [32]u8 = undefined;
        try self.append("q ");
        // An image fills the unit square, its first row at the top (8.9.5).
        for ([_]f64{ w, 0, 0, h, x, self.flip(y + h) }) |n| try self.number(n);
        try self.append(std.fmt.bufPrint(&name, "cm /Im{d} Do Q\n", .{index orelse self.images.items.len}) catch unreachable);
        if (added) |copy| self.images.appendAssumeCapacity(copy);
    }

    /// The `/ExtGState` entry for graphics state `index`, allocated from `a`.
    pub fn stateDictionary(self: *const Canvas, a: Allocator, index: usize) Allocator.Error!Dict {
        const s = self.states.items[index];
        return serial.makeDict(a, &.{
            .{ "Type", .{ .name = "ExtGState" } },
            .{ "ca", .{ .real = s.fill_alpha } },
            .{ "CA", .{ .real = s.stroke_alpha } },
            .{ "BM", .{ .name = @tagName(s.blend) } },
        });
    }
};

/// The dictionary of an image XObject of `picture`'s size, with `components`
/// samples to a pixel: the picture's own, or one for its alpha.
pub fn imageDictionary(a: Allocator, picture: *const Image, components: u8, jpeg: bool) Allocator.Error!Dict {
    return serial.makeDict(a, &.{
        .{ "Type", .{ .name = "XObject" } },
        .{ "Subtype", .{ .name = "Image" } },
        .{ "Width", .{ .integer = picture.width } },
        .{ "Height", .{ .integer = picture.height } },
        .{ "ColorSpace", .{ .name = if (components == 1) "DeviceGray" else "DeviceRGB" } },
        .{ "BitsPerComponent", .{ .integer = 8 } },
        .{ "Filter", .{ .name = if (jpeg) "DCTDecode" else "FlateDecode" } },
    });
}

/// The `/Resources` of what `canvas` draws, allocated from `a`. `objects` gives
/// the object of each built-in font (`fontObject`) and image (`imageObject`).
pub fn resourcesOf(a: Allocator, canvas: *const Canvas, objects: anytype) !Dict {
    var out: std.ArrayList(object.Entry) = .empty;
    var fonts: std.ArrayList(object.Entry) = .empty;
    var it = canvas.fonts.iterator();
    while (it.next()) |font| {
        try fonts.append(a, .{ .key = try std.fmt.allocPrint(a, "F{d}", .{@backingInt(font)}), .value = .{ .ref = try objects.fontObject(a, font) } });
    }
    if (fonts.items.len > 0) try out.append(a, .{ .key = "Font", .value = .{ .dict = .{ .entries = fonts.items } } });

    const images = try a.alloc(object.Entry, canvas.images.items.len);
    for (canvas.images.items, images, 0..) |*picture, *entry, i| {
        entry.* = .{ .key = try std.fmt.allocPrint(a, "Im{d}", .{i}), .value = .{ .ref = try objects.imageObject(a, picture) } };
    }
    if (images.len > 0) try out.append(a, .{ .key = "XObject", .value = .{ .dict = .{ .entries = images } } });

    const states = try a.alloc(object.Entry, canvas.states.items.len);
    for (states, 0..) |*entry, i| entry.* = .{ .key = try std.fmt.allocPrint(a, "Gs{d}", .{i}), .value = .{ .dict = try canvas.stateDictionary(a, i) } };
    if (states.len > 0) try out.append(a, .{ .key = "ExtGState", .value = .{ .dict = .{ .entries = states } } });
    return .{ .entries = out.items };
}

/// The font dictionary of a built-in font.
pub fn fontDictionary(a: Allocator, font: Builtin) Allocator.Error!Dict {
    return serial.makeDict(a, &.{
        .{ "Type", .{ .name = "Font" } },
        .{ "Subtype", .{ .name = "Type1" } },
        .{ "BaseFont", .{ .name = font.baseFont() } },
        .{ "Encoding", .{ .name = "WinAnsiEncoding" } },
    });
}

/// The canvas's content, with the saved states still open closed, compressed
/// for `/FlateDecode`.
pub fn compressedContent(a: Allocator, canvas: *const Canvas) Allocator.Error![]const u8 {
    var all: std.ArrayList(u8) = .empty;
    try all.appendSlice(a, canvas.content.items);
    for (canvas.saved.items) |_| try all.appendSlice(a, "Q\n");
    return pack.compress(a, all.items);
}

// ---- onto existing pages -------------------------------------------------------------------

pub const StampError = page_edit.Error || error{
    /// The page is written directly in the page tree and cannot be changed.
    DirectPage,
    /// A canvas whose path was neither painted nor used to clip.
    PathOpen,
};

pub const Layer = enum {
    /// On top of what the page shows.
    over,
    /// Behind it. A page that paints its whole area, as a scan does, hides it.
    under,
};

/// Puts canvases on pages of an existing file, in one `write.Update`. A canvas
/// placed on many pages is stored once, and so are its fonts and images. Call
/// `finish` before the update is written. Encrypted and repaired files are
/// refused when the update is made.
///
/// The canvas lies on the page as it is seen, its top left on the page's top
/// left, upright whatever the page's rotation and `/UserUnit`. Make it the
/// size of `page.displaySize()` to cover the page; drawing outside the canvas
/// is cut off.
pub const Stamp = struct {
    upd: *serial.Update,
    /// What has been added to the update, so that it is added once. They live
    /// in the update's memory.
    fonts: std.EnumArray(Builtin, u32) = .initFill(0),
    images: std.AutoArrayHashMapUnmanaged([32]u8, u32) = .empty,
    forms: std.AutoArrayHashMapUnmanaged([32]u8, u32) = .empty,

    pub fn init(upd: *serial.Update) Stamp {
        return .{ .upd = upd };
    }

    /// Writes what is written once for all pages. With only built-in fonts
    /// there is nothing left to write; embedded fonts will be written here.
    pub fn finish(self: *Stamp) StampError!void {
        _ = self;
    }

    /// Draws `canvas` on `page`. The canvas can be changed or freed afterwards.
    /// A call that fails leaves the page as it was.
    pub fn place(self: *Stamp, page: pages.Page, canvas: *const Canvas, layer: Layer) StampError!void {
        if (canvas.path != .none) return error.PathOpen;
        if (page.num == 0) return error.DirectPage;
        const upd = self.upd;
        const a = upd.allocator();
        var page_dict = upd.get(page.num).asDict() orelse return error.DirectPage;

        // From the canvas's space, y up, to the page as seen, and from there
        // into the page's user space.
        const turn: Matrix = .{ .a = 1, .b = 0, .c = 0, .d = -1, .e = 0, .f = canvas.height };
        const m = turn.mul(interp.baseMatrix(page).invert() orelse return error.UnreadableContent);

        const form = try self.formOf(canvas);
        var resources: page_edit.Resources = .of(upd, page, page_dict);
        const name = try resources.add(upd, .{ .num = form });
        const drawing = try std.fmt.allocPrint(a, "q {d} {d} {d} {d} {d} {d} cm /{s} Do Q\n", .{ m.a, m.b, m.c, m.d, m.e, m.f, name });
        page_dict = try resources.applyTo(upd, page_dict);
        const old = page_dict.get("Contents");
        const contents = switch (layer) {
            .over => try page_edit.drawOver(upd, old, drawing),
            .under => try page_edit.drawUnder(upd, old, drawing),
        };
        page_dict = try serial.dictWith(a, page_dict, "Contents", contents);
        try upd.set(page.num, .{ .dict = page_dict });
    }

    /// The form XObject with what `canvas` draws, made once.
    fn formOf(self: *Stamp, canvas: *const Canvas) StampError!u32 {
        const a = self.upd.allocator();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_]f64{ canvas.width, canvas.height }) |v| hash.update(std.mem.asBytes(&v));
        var counts: [8]u8 = undefined;
        std.mem.writeInt(u64, &counts, canvas.saved.items.len, .little);
        hash.update(&counts);
        std.mem.writeInt(u64, &counts, canvas.content.items.len, .little);
        hash.update(&counts);
        hash.update(canvas.content.items);
        for (canvas.images.items) |picture| hash.update(&picture.digest);
        for (canvas.states.items) |s| {
            hash.update(std.mem.asBytes(&s.fill_alpha));
            hash.update(std.mem.asBytes(&s.stroke_alpha));
            hash.update(@tagName(s.blend));
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        if (self.forms.get(digest)) |num| return num;

        const dict = try serial.makeDict(a, &.{
            .{ "Type", .{ .name = "XObject" } },
            .{ "Subtype", .{ .name = "Form" } },
            .{ "BBox", try serial.numbers(a, &.{ 0, 0, canvas.width, canvas.height }) },
            .{ "Resources", .{ .dict = try resourcesOf(a, canvas, self) } },
            .{ "Filter", .{ .name = "FlateDecode" } },
        });
        const ref = try self.upd.add(.{ .stream = .{ .dict = dict, .data = try compressedContent(a, canvas) } });
        try self.forms.put(a, digest, ref.num);
        return ref.num;
    }

    pub fn fontObject(self: *Stamp, a: Allocator, font: Builtin) !object.Ref {
        if (self.fonts.get(font) == 0) {
            const ref = try self.upd.add(.{ .dict = try fontDictionary(a, font) });
            self.fonts.set(font, ref.num);
        }
        return .{ .num = self.fonts.get(font) };
    }

    pub fn imageObject(self: *Stamp, a: Allocator, picture: *const Image) !object.Ref {
        if (self.images.get(picture.digest)) |num| return .{ .num = num };
        // The update outlives the canvas, so it keeps copies of the data.
        var entries: std.ArrayList(object.Entry) = .empty;
        try entries.appendSlice(a, (try imageDictionary(a, picture, picture.components, picture.jpeg)).entries);
        if (picture.alpha) |alpha| {
            const mask = try self.upd.add(.{ .stream = .{ .dict = try imageDictionary(a, picture, 1, false), .data = try a.dupe(u8, alpha) } });
            try entries.append(a, .{ .key = "SMask", .value = .{ .ref = mask } });
        }
        const ref = try self.upd.add(.{ .stream = .{ .dict = .{ .entries = entries.items }, .data = try a.dupe(u8, picture.data) } });
        try self.images.put(a, picture.digest, ref.num);
        return ref;
    }
};

// Tests live in draw_tests.zig.
