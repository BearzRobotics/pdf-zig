//! The display list: a page as a flat sequence of drawing commands with the
//! graphics state resolved (the output of `interp.zig`). A renderer walks it;
//! this library draws nothing itself.
//!
//! Coordinates are in the page's *user space* (origin bottom left, y up, units
//! of 1/72 inch). Each command that draws carries `ctm`, the matrix from the
//! space of its coordinates to default user space. `DisplayList.base` maps
//! default user space to the displayed page in points with the origin at the
//! top left and y down, with the crop box and `/Rotate` applied. So a point `p`
//! in a path lands at `p * ctm * base`, with the row-vector convention of the
//! PDF specification (`Matrix.apply`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const color = @import("color.zig");
const font_mod = @import("font.zig");

pub const Rgb = color.Rgb;

pub const Point = struct { x: f64, y: f64 };

/// A transformation matrix `[a b c d e f]` (8.3.3): `x' = a*x + c*y + e`,
/// `y' = b*x + d*y + f`.
pub const Matrix = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity: Matrix = .{};

    /// The matrix that applies `self` first and then `n` (`self × n`).
    pub fn mul(self: Matrix, n: Matrix) Matrix {
        return .{
            .a = self.a * n.a + self.b * n.c,
            .b = self.a * n.b + self.b * n.d,
            .c = self.c * n.a + self.d * n.c,
            .d = self.c * n.b + self.d * n.d,
            .e = self.e * n.a + self.f * n.c + n.e,
            .f = self.e * n.b + self.f * n.d + n.f,
        };
    }

    pub fn apply(self: Matrix, x: f64, y: f64) Point {
        return .{ .x = self.a * x + self.c * y + self.e, .y = self.b * x + self.d * y + self.f };
    }

    pub fn translate(tx: f64, ty: f64) Matrix {
        return .{ .e = tx, .f = ty };
    }

    pub fn scale(sx: f64, sy: f64) Matrix {
        return .{ .a = sx, .d = sy };
    }

    pub fn determinant(self: Matrix) f64 {
        return self.a * self.d - self.b * self.c;
    }

    /// The inverse, or null for a singular matrix.
    pub fn invert(self: Matrix) ?Matrix {
        const det = self.determinant();
        if (det == 0 or !std.math.isFinite(det)) return null;
        return .{
            .a = self.d / det,
            .b = -self.b / det,
            .c = -self.c / det,
            .d = self.a / det,
            .e = (self.c * self.f - self.d * self.e) / det,
            .f = (self.b * self.e - self.a * self.f) / det,
        };
    }

    pub fn fromArray(v: []const f64) Matrix {
        if (v.len < 6) return identity;
        return .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] };
    }
};

pub const Seg = union(enum) {
    move: Point,
    line: Point,
    curve: struct { c1: Point, c2: Point, p: Point },
    close,
};

pub const Path = []const Seg;

pub const FillRule = enum { nonzero, even_odd };
pub const Cap = enum { butt, round, square };
pub const Join = enum { miter, round, bevel };

pub const StrokeStyle = struct {
    width: f64 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f64 = 10,
    dash: []const f64 = &.{},
    dash_phase: f64 = 0,
};

/// A colour stop of a gradient.
pub const Stop = struct { offset: f64, color: Rgb };

pub const ShadingKind = enum { axial, radial };

/// An axial (type 2) or radial (type 3) shading, sampled into colour stops.
pub const Shading = struct {
    kind: ShadingKind,
    /// Axial: x0 y0 x1 y1. Radial: x0 y0 r0 x1 y1 r1.
    coords: [6]f64,
    extend_start: bool,
    extend_end: bool,
    stops: []const Stop,
    background: ?Rgb = null,
    bbox: ?[4]f64 = null,
};

/// A tiling pattern with its cell already interpreted (8.7.3).
pub const Tiling = struct {
    cell: *DisplayList,
    bbox: [4]f64,
    xstep: f64,
    ystep: f64,
    /// Pattern space to default user space.
    matrix: Matrix,
    /// The colour of an uncoloured pattern (paint type 2); null for coloured ones.
    color: ?Rgb,
};

pub const Paint = union(enum) {
    color: Rgb,
    /// A shading pattern (8.7.4.3) with its pattern matrix.
    shading: struct { shading: Shading, matrix: Matrix },
    tiling: Tiling,
    /// A pattern this library could not turn into one of the above: draw nothing.
    none,
};

pub const Clip = struct { path: Path, rule: FillRule, ctm: Matrix };

pub const Fill = struct { path: Path, rule: FillRule, paint: Paint, alpha: f64, ctm: Matrix, blend: []const u8 };

pub const Stroke = struct { path: Path, style: StrokeStyle, paint: Paint, alpha: f64, ctm: Matrix, blend: []const u8 };

/// One shown character.
pub const Glyph = struct {
    /// Character code as written.
    code: u32,
    /// CID (composite fonts), else the code.
    cid: u32,
    /// Offset of the glyph origin from the start of the run in text space
    /// (already multiplied by font size and horizontal scale).
    x: f64,
    /// Advance in em units.
    advance: f64,
    /// Unicode text, UTF-8, possibly empty.
    text: []const u8,
};

/// A run of text shown by one `Tj`, `TJ`, `'` or `"`.
pub const Text = struct {
    font: *const font_mod.Font,
    size: f64,
    /// Text rendering mode 0..7 (9.3.6); 3 is invisible (still extractable).
    mode: u8,
    /// Horizontal scaling (1 = 100%) and rise (9.3.2, 9.3.7).
    h_scale: f64,
    rise: f64,
    /// Text matrix at the start of the run and the CTM.
    tm: Matrix,
    ctm: Matrix,
    fill: Paint,
    stroke: Paint,
    alpha: f64,
    stroke_alpha: f64,
    glyphs: []const Glyph,
};

/// An image to draw into the unit square of `ctm` (8.9.4).
pub const Image = struct {
    /// The image dictionary (an XObject's or an inline image's) and its raw data.
    stream: object.Stream,
    width: u32,
    height: u32,
    /// Stencil mask: paint `fill` through the 1-bits (or 0-bits per /Decode).
    is_mask: bool,
    fill: Paint,
    ctm: Matrix,
    alpha: f64,
    blend: []const u8,
    /// An image XObject's object number (0 for inline images).
    num: u32,
};

pub const ShadingFill = struct { shading: Shading, ctm: Matrix, alpha: f64 };

pub const Command = union(enum) {
    save,
    restore,
    clip: Clip,
    fill: Fill,
    stroke: Stroke,
    text: Text,
    image: Image,
    shading: ShadingFill,
};

pub const DisplayList = struct {
    arena: std.heap.ArenaAllocator,
    commands: []const Command = &.{},
    /// Default user space to the displayed page (points, top left origin, y down).
    base: Matrix = .identity,
    /// Size of the displayed page in points.
    width: f64 = 0,
    height: f64 = 0,

    pub fn deinit(self: *DisplayList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "matrix algebra" {
    const t = Matrix.translate(10, 20);
    const s = Matrix.scale(2, 3);
    const p = t.mul(s).apply(1, 1); // translate first, then scale
    try std.testing.expectEqual(@as(f64, 22), p.x);
    try std.testing.expectEqual(@as(f64, 63), p.y);
    const q = s.mul(t).apply(1, 1);
    try std.testing.expectEqual(@as(f64, 12), q.x);
    const m = Matrix{ .a = 2, .b = 1, .c = -1, .d = 3, .e = 5, .f = 7 };
    const inv = m.invert().?;
    const back = m.mul(inv);
    try std.testing.expectApproxEqAbs(@as(f64, 1), back.a, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), back.b, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), back.e, 1e-12);
    try std.testing.expect((Matrix{ .a = 0, .d = 0 }).invert() == null);
}
