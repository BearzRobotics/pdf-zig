// SPDX-License-Identifier: LGPL-2.0-or-later
//! Colour spaces (ISO 32000-1:2008, 8.6) and conversion to RGB.
//!
//! Device, CIE-based, ICC-based, Indexed, Separation, DeviceN and Pattern
//! spaces are read. CIE-based and ICC-based spaces are treated as the device
//! space with the same number of components, except Lab, which is converted
//! properly. CMYK is converted with the simple formula `R = (1-C)(1-K)`;
//! colour management is the renderer's business.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const function = @import("function.zig");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const Object = object.Object;
const Dict = object.Dict;

pub const Rgb = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,

    pub const black: Rgb = .{};
    pub const white: Rgb = .{ .r = 1, .g = 1, .b = 1 };
};

pub const Lab = struct { white: [3]f64, range: [4]f64 };
pub const Indexed = struct { base: *const Space, hival: u32, lookup: []const u8 };
pub const Tint = struct {
    n: u8,
    alt: *const Space,
    func: ?function.Function,
    /// A Separation of `None`: marks nothing on the page.
    none: bool,
};

pub const Space = union(enum) {
    gray,
    rgb,
    cmyk,
    lab: Lab,
    indexed: Indexed,
    tint: Tint,
    /// A pattern space with the space of uncoloured patterns, if any.
    pattern: ?*const Space,

    /// Whether painting in this space marks nothing (a `None` separation).
    pub fn isInvisible(self: Space) bool {
        return self == .tint and self.tint.none;
    }

    /// Number of colour components of a colour in this space.
    pub fn components(self: Space) u8 {
        return switch (self) {
            .gray => 1,
            .rgb, .lab => 3,
            .cmyk => 4,
            .indexed => 1,
            .tint => |t| t.n,
            .pattern => |p| if (p) |b| b.components() else 0,
        };
    }

    /// The initial colour of a space (8.6.3, 8.6.5.x).
    pub fn initial(self: Space, out: []f64) void {
        @memset(out, 0);
        switch (self) {
            .cmyk => if (out.len >= 4) {
                out[3] = 1;
            },
            .tint => @memset(out, 1),
            else => {},
        }
    }

    pub fn toRgb(self: Space, c: []const f64) Rgb {
        switch (self) {
            .gray => return grayRgb(at(c, 0)),
            .rgb => return .{ .r = clamp(at(c, 0)), .g = clamp(at(c, 1)), .b = clamp(at(c, 2)) },
            .cmyk => return cmykRgb(at(c, 0), at(c, 1), at(c, 2), at(c, 3)),
            .lab => |l| return labRgb(l, at(c, 0), at(c, 1), at(c, 2)),
            .indexed => |ix| {
                const n = ix.base.components();
                const i: usize = @intFromFloat(std.math.clamp(@round(at(c, 0)), 0, @as(f64, @floatFromInt(ix.hival))));
                var comp: [function.max_inputs]f64 = @splat(0);
                for (0..@min(n, comp.len)) |k| {
                    const b = if (i * n + k < ix.lookup.len) ix.lookup[i * n + k] else 0;
                    comp[k] = @as(f64, @floatFromInt(b)) / 255.0;
                }
                if (ix.base.* == .lab) {
                    // Lab components are stored scaled to their ranges.
                    const l = ix.base.lab;
                    comp[0] *= 100;
                    comp[1] = l.range[0] + comp[1] * (l.range[1] - l.range[0]);
                    comp[2] = l.range[2] + comp[2] * (l.range[3] - l.range[2]);
                }
                return ix.base.toRgb(comp[0..n]);
            },
            .tint => |t| {
                var out: [function.max_outputs]f64 = @splat(0);
                if (t.func) |f| {
                    const n = @min(f.nOutputs(), out.len);
                    f.eval(c, out[0..n]);
                    return t.alt.toRgb(out[0..n]);
                }
                // No usable tint transform: a tint of 1 is full ink, shown dark.
                return grayRgb(1 - at(c, 0));
            },
            .pattern => return Rgb.black,
        }
    }
};

fn at(c: []const f64, i: usize) f64 {
    return if (i < c.len) c[i] else 0;
}

fn clamp(v: f64) f32 {
    return @floatCast(std.math.clamp(v, 0, 1));
}

pub fn grayRgb(g: f64) Rgb {
    const v = clamp(g);
    return .{ .r = v, .g = v, .b = v };
}

/// sRGB values of the 16 corner inks of CMYK (index bits C, M, Y, K), taken from
/// a typical SWOP press profile: pure cyan is #00AEEF, magenta #EC008C, yellow
/// #FFF200 and black #231F20. A colour is the multilinear interpolation of the
/// corners, which is how most viewers approximate CMYK on a screen.
const cmyk_corners = [16][3]f64{
    .{ 1, 1, 1 }, // 0000 paper
    .{ 0.1373, 0.1216, 0.1255 }, // K
    .{ 1, 0.9490, 0 }, // Y
    .{ 0.1098, 0.1020, 0 }, // YK
    .{ 0.9255, 0, 0.5490 }, // M
    .{ 0.1412, 0, 0 }, // MK
    .{ 0.9294, 0.1098, 0.1412 }, // MY
    .{ 0.1333, 0, 0 }, // MYK
    .{ 0, 0.6784, 0.9373 }, // C
    .{ 0, 0.0588, 0.1412 }, // CK
    .{ 0, 0.6510, 0.3137 }, // CY
    .{ 0, 0.0745, 0 }, // CYK
    .{ 0.1804, 0.1922, 0.5725 }, // CM
    .{ 0, 0, 0.0078 }, // CMK
    .{ 0.2118, 0.2119, 0.2235 }, // CMY
    .{ 0, 0, 0 }, // CMYK
};

pub fn cmykRgb(c: f64, m: f64, y: f64, k: f64) Rgb {
    const v = [4]f64{ std.math.clamp(c, 0, 1), std.math.clamp(m, 0, 1), std.math.clamp(y, 0, 1), std.math.clamp(k, 0, 1) };
    var out = [3]f64{ 0, 0, 0 };
    for (cmyk_corners, 0..) |corner, i| {
        var w: f64 = 1;
        for (0..4) |bit| {
            const on = (i >> @intCast(3 - bit)) & 1 == 1;
            w *= if (on) v[bit] else 1 - v[bit];
        }
        for (0..3) |ch| out[ch] += w * corner[ch];
    }
    return .{ .r = clamp(out[0]), .g = clamp(out[1]), .b = clamp(out[2]) };
}

/// The white point of sRGB.
const d65 = [3]f64{ 0.95047, 1.0, 1.08883 };

fn labRgb(l: Lab, ls: f64, as: f64, bs: f64) Rgb {
    // CIE L*a*b* to XYZ (8.6.5.4). L*a*b* is relative to the space's white
    // point; the XYZ is taken relative to the display's white (D65) instead,
    // which adapts one to the other, so that L* 100 is the screen's white.
    const a = std.math.clamp(as, l.range[0], l.range[1]);
    const b = std.math.clamp(bs, l.range[2], l.range[3]);
    const m = (ls + 16) / 116;
    const lx = m + a / 500;
    const lz = m - b / 200;
    const g = struct {
        fn f(x: f64) f64 {
            return if (x >= 6.0 / 29.0) x * x * x else 108.0 / 841.0 * (x - 4.0 / 29.0);
        }
    }.f;
    const x = d65[0] * g(lx);
    const y = d65[1] * g(m);
    const z = d65[2] * g(lz);
    // Linear sRGB (D65 matrix; adequate for display of a preview).
    const r = 3.2406 * x - 1.5372 * y - 0.4986 * z;
    const gg = -0.9689 * x + 1.8758 * y + 0.0415 * z;
    const bb = 0.0557 * x - 0.2040 * y + 1.0570 * z;
    const gamma = struct {
        fn f(u: f64) f64 {
            const v = std.math.clamp(u, 0, 1);
            return if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
        }
    }.f;
    return .{ .r = clamp(gamma(r)), .g = clamp(gamma(gg)), .b = clamp(gamma(bb)) };
}

fn byName(name: []const u8) ?Space {
    const eq = std.mem.eql;
    if (eq(u8, name, "DeviceGray") or eq(u8, name, "G") or eq(u8, name, "CalGray")) return .gray;
    if (eq(u8, name, "DeviceRGB") or eq(u8, name, "RGB") or eq(u8, name, "CalRGB")) return .rgb;
    if (eq(u8, name, "DeviceCMYK") or eq(u8, name, "CMYK")) return .cmyk;
    if (eq(u8, name, "Pattern")) return .{ .pattern = null };
    return null;
}

pub const ParseError = Allocator.Error;

/// Reads a colour space object. `resources` supplies `/ColorSpace` names.
/// Unknown or damaged spaces become DeviceGray so that drawing can go on.
/// `obj` may be temporary (an operand, an inline image's dictionary).
pub fn parse(doc: *Document, obj: Object, resources: ?Dict, depth: u8) ParseError!Space {
    var named = false;
    return parseCached(doc, obj, resources, depth, false, &named);
}

/// `parse` for an object that is part of the document (from its resources or
/// a stream dictionary of its own), so that the result can be kept.
pub fn parseOwned(doc: *Document, obj: Object, resources: ?Dict, depth: u8) ParseError!Space {
    var named = false;
    return parseCached(doc, obj, resources, depth, true, &named);
}

/// Sets `named` if the result depends on `resources`; such a space is not kept.
fn parseCached(doc: *Document, obj: Object, resources: ?Dict, depth: u8, owned: bool, named: *bool) ParseError!Space {
    const key = if (obj == .ref or obj == .array) Document.cacheKey(obj, owned) else null;
    if (key) |k| if (doc.color_spaces.get(k)) |space| return space;
    const oom_before = doc.oom_events;
    var depends = false;
    // What a reference leads to is part of the document in any case.
    const space = try parseNew(doc, obj, resources, depth, owned or obj == .ref, &depends);
    if (depends) {
        named.* = true;
    } else if (key) |k| if (doc.oom_events == oom_before and depth <= 8) {
        try doc.color_spaces.put(doc.arena.allocator(), k, space);
    };
    return space;
}

fn parseNew(doc: *Document, obj: Object, resources: ?Dict, depth: u8, owned: bool, named_out: *bool) ParseError!Space {
    if (depth > 8) return .gray;
    const a = doc.arena.allocator();
    const o = doc.resolve(obj);
    switch (o) {
        .name => |n| {
            if (byName(n)) |s| return s;
            named_out.* = true;
            const res = resources orelse return .gray;
            const cs = doc.getDict(res, "ColorSpace") orelse return .gray;
            const named = cs.get(n) orelse return .gray;
            // A name that maps to itself would loop.
            if (named == .name and std.mem.eql(u8, named.name, n)) return .gray;
            // From a resource dictionary, so part of the document.
            return parseCached(doc, named, resources, depth + 1, true, named_out);
        },
        .array => |arr| {
            if (arr.len == 0) return .gray;
            const family = doc.resolve(arr[0]).asName() orelse return .gray;
            const eq = std.mem.eql;
            if (arr.len == 1) return byName(family) orelse .gray;
            if (eq(u8, family, "CalGray")) return .gray;
            if (eq(u8, family, "CalRGB")) return .rgb;
            if (eq(u8, family, "Lab")) {
                const d = doc.resolve(arr[1]).asDict() orelse return .gray;
                var white: [3]f64 = .{ 0.9505, 1.0, 1.089 };
                if (doc.getArray(d, "WhitePoint")) |w| if (w.len >= 3) for (0..3) |i| {
                    white[i] = doc.resolve(w[i]).asNum() orelse white[i];
                };
                var range: [4]f64 = .{ -100, 100, -100, 100 };
                if (doc.getArray(d, "Range")) |r| if (r.len >= 4) for (0..4) |i| {
                    range[i] = doc.resolve(r[i]).asNum() orelse range[i];
                };
                // Each pair must be a finite interval; otherwise the default is used.
                for (0..2) |i| {
                    const lo = range[2 * i];
                    const hi = range[2 * i + 1];
                    if (!(std.math.isFinite(lo) and std.math.isFinite(hi) and lo <= hi)) range[2 * i ..][0..2].* = .{ -100, 100 };
                }
                return .{ .lab = .{ .white = white, .range = range } };
            }
            if (eq(u8, family, "ICCBased")) {
                const s = doc.resolve(arr[1]);
                const d = s.asDict() orelse return .gray;
                const n = doc.getInt(d, "N") orelse 3;
                return switch (n) {
                    1 => .gray,
                    4 => .cmyk,
                    else => .rgb,
                };
            }
            if (eq(u8, family, "Indexed") or eq(u8, family, "I")) {
                if (arr.len < 4) return .gray;
                const base = try a.create(Space);
                base.* = try parseCached(doc, arr[1], resources, depth + 1, owned, named_out);
                const hival: u32 = @intCast(std.math.clamp(doc.resolve(arr[2]).asInt() orelse 255, 0, 255));
                const lk = doc.resolve(arr[3]);
                const lookup: []const u8 = switch (lk) {
                    .string => |s| s,
                    .stream => |st| doc.streamData(st) catch "",
                    else => "",
                };
                return .{ .indexed = .{ .base = base, .hival = hival, .lookup = lookup } };
            }
            if (eq(u8, family, "Separation") or eq(u8, family, "DeviceN")) {
                if (arr.len < 4) return .gray;
                var n: u8 = 1;
                var none = false;
                if (eq(u8, family, "DeviceN")) {
                    const names = doc.resolve(arr[1]).asArray() orelse return .gray;
                    n = @intCast(@min(names.len, function.max_inputs));
                    none = names.len > 0;
                    for (names) |nm| if (!std.mem.eql(u8, doc.resolve(nm).asName() orelse "", "None")) {
                        none = false;
                    };
                } else {
                    none = std.mem.eql(u8, doc.resolve(arr[1]).asName() orelse "", "None");
                }
                const alt = try a.create(Space);
                alt.* = try parseCached(doc, arr[2], resources, depth + 1, owned, named_out);
                const f = function.loadKept(doc, arr[3], owned) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadFunction => null,
                };
                return .{ .tint = .{ .n = @max(1, n), .alt = alt, .func = f, .none = none } };
            }
            if (eq(u8, family, "Pattern")) {
                const under = try a.create(Space);
                under.* = try parseCached(doc, arr[1], resources, depth + 1, owned, named_out);
                return .{ .pattern = under };
            }
            return byName(family) orelse .gray;
        },
        else => return .gray,
    }
}

test "an out-of-range channel is clamped in every position" {
    const nan = std.math.nan(f64);
    for (0..3) |channel| {
        for ([_]f64{ nan, -5, 5 }) |bad| {
            var c = [3]f64{ 0.5, 0.5, 0.5 };
            c[channel] = bad;
            const got = (Space{ .rgb = {} }).toRgb(&c);
            for ([_]f32{ got.r, got.g, got.b }) |v| try std.testing.expect(v >= 0 and v <= 1);
        }
    }
}

test "Lab a* and b* move the colour" {
    const lab: Space = .{ .lab = .{ .white = .{ 0.9642, 1, 0.8249 }, .range = .{ -128, 127, -128, 127 } } };
    const red = lab.toRgb(&.{ 50, 80, 0 });
    const green = lab.toRgb(&.{ 50, -80, 0 });
    const yellow = lab.toRgb(&.{ 70, 0, 80 });
    const blue = lab.toRgb(&.{ 40, 0, -80 });
    try std.testing.expect(red.r > red.g + 0.3 and green.g > green.r + 0.3);
    try std.testing.expect(yellow.r > yellow.b + 0.3 and blue.b > blue.r + 0.3);
}

test "device spaces and conversion" {
    try std.testing.expectEqual(@as(u8, 3), (Space{ .rgb = {} }).components());
    const c = (Space{ .cmyk = {} }).toRgb(&.{ 0, 0, 0, 1 }); // pure K is a soft black, #231F20
    try std.testing.expectApproxEqAbs(@as(f32, 0.1373), c.r, 1e-4);
    const cy = (Space{ .cmyk = {} }).toRgb(&.{ 1, 0, 0, 0 }); // #00AEEF
    try std.testing.expectApproxEqAbs(@as(f32, 0.6784), cy.g, 1e-4);
    const half = (Space{ .cmyk = {} }).toRgb(&.{ 0.5, 0, 0, 0 });
    try std.testing.expect(half.r > 0.4 and half.r < 0.6); // between paper and cyan
    const w = (Space{ .cmyk = {} }).toRgb(&.{ 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(f32, 1), w.g);
    const g = (Space{ .gray = {} }).toRgb(&.{0.5});
    try std.testing.expectEqual(@as(f32, 0.5), g.b);
    var init: [4]f64 = undefined;
    (Space{ .cmyk = {} }).initial(&init);
    try std.testing.expectEqual(@as(f64, 1), init[3]); // initial CMYK is black
    // Out-of-range input is clamped, never NaN.
    const bad = (Space{ .rgb = {} }).toRgb(&.{ 5, -3, std.math.nan(f64) });
    try std.testing.expectEqual(@as(f32, 1), bad.r);
    try std.testing.expectEqual(@as(f32, 0), bad.g);
}

test "Lab: white and black" {
    const sp = Space{ .lab = .{ .white = .{ 0.9505, 1.0, 1.089 }, .range = .{ -128, 127, -128, 127 } } };
    const w = sp.toRgb(&.{ 100, 0, 0 });
    try std.testing.expect(w.r > 0.98 and w.g > 0.98 and w.b > 0.98);
    const k = sp.toRgb(&.{ 0, 0, 0 });
    try std.testing.expect(k.r < 0.02 and k.g < 0.02 and k.b < 0.02);
}

test "Indexed lookup" {
    const base = Space{ .rgb = {} };
    const sp = Space{ .indexed = .{ .base = &base, .hival = 1, .lookup = &.{ 255, 0, 0, 0, 0, 255 } } };
    const c1 = sp.toRgb(&.{1});
    try std.testing.expectEqual(@as(f32, 1), c1.b);
    try std.testing.expectEqual(@as(f32, 0), c1.r);
    const c0 = sp.toRgb(&.{0});
    try std.testing.expectEqual(@as(f32, 1), c0.r);
    // An index past hival uses the last entry.
    const c9 = sp.toRgb(&.{9});
    try std.testing.expectEqual(@as(f32, 1), c9.b);
}

test "Lab white is white whatever the space's white point" {
    for ([_][3]f64{ .{ 0.9642, 1, 0.8249 }, .{ 0.9505, 1, 1.089 }, .{ 1.0985, 1, 0.3558 } }) |white| {
        const space: Space = .{ .lab = .{ .white = white, .range = .{ -128, 127, -128, 127 } } };
        const c = space.toRgb(&.{ 100, 0, 0 });
        for ([_]f32{ c.r, c.g, c.b }) |v| try std.testing.expect(v > 0.995);
        const grey = space.toRgb(&.{ 50, 0, 0 });
        try std.testing.expectApproxEqAbs(grey.r, grey.g, 0.005);
        try std.testing.expectApproxEqAbs(grey.g, grey.b, 0.005);
    }
}
