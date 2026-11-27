// SPDX-License-Identifier: LGPL-2.0-or-later
//! Image pixels (ISO 32000-1:2008, 8.9): samples to straight-alpha RGBA.
//!
//! `decode` turns an image from a display list into pixels when its filters
//! are the ones this library decodes (Flate, LZW, ASCII85, ASCIIHex, RunLength
//! and no filter). For DCT (JPEG), JPX, JBIG2 and CCITT streams it returns the
//! undecoded data with the codec's name; the caller decodes it with its own
//! codec and passes the samples to `fromSamples`, which applies the colour
//! space, `/Decode` array, stencil masks, colour-key masks and soft masks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const color = @import("color.zig");
const display = @import("display.zig");
const ccitt = @import("ccitt.zig");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const Dict = object.Dict;

pub const Error = error{
    /// The image is larger than `max_pixels`, or its size is nonsense.
    TooBig,
    BadImage,
} || doc_mod.Error;

pub const max_pixels: u64 = 128 * 1000 * 1000;

/// 8-bit RGBA with straight (not premultiplied) alpha, rows top to bottom.
pub const Pixels = struct {
    width: u32,
    height: u32,
    rgba: []u8,
    /// A soft or stencil mask that has not been applied because its data needs
    /// a codec this library does not have: decode it and pass the samples to
    /// `withMaskSamples`, or the image is more opaque than it should be.
    pending_mask: ?PendingMask = null,
};

pub const PendingMask = struct {
    codec: Codec,
    /// The mask image's dictionary.
    dict: Dict,
};

/// A stream that needs a codec this library does not have.
pub const Codec = struct {
    /// `DCTDecode`, `JPXDecode`, `JBIG2Decode` or `CCITTFaxDecode`.
    name: []const u8,
    /// The data as the codec expects it (earlier filters already applied).
    data: []const u8,
    parms: Dict,
};

pub const Result = union(enum) {
    pixels: Pixels,
    codec: Codec,
};

/// Decodes `img`. Allocations (the pixels and temporaries) come from `a`.
pub fn decode(doc: *Document, a: Allocator, img: display.Image) Error!Result {
    if (@as(u64, img.width) * img.height > max_pixels) return error.TooBig;
    var dec = try doc.decodeStreamIn(a, img.stream);
    if (dec.rest.len == 1 and (std.mem.eql(u8, dec.rest[0].name, "CCITTFaxDecode") or std.mem.eql(u8, dec.rest[0].name, "CCF"))) {
        // Fax data is decoded here: it needs no codec library.
        // Made first: the new value is built from the one it replaces.
        const samples = try faxSamples(doc, a, dec.data, dec.rest[0].parms, img.width, img.height);
        dec = .{ .data = samples, .rest = &.{} };
    }
    if (dec.rest.len > 0) return .{ .codec = .{ .name = dec.rest[0].name, .data = dec.data, .parms = dec.rest[0].parms } };
    const is_fax = blk: {
        const f = (doc.get(img.stream.dict, "Filter") orelse break :blk false);
        const last = switch (f) {
            .name => |n| n,
            .array => |arr| if (arr.len > 0) (doc.resolve(arr[arr.len - 1]).asName() orelse "") else "",
            else => "",
        };
        break :blk std.mem.eql(u8, last, "CCITTFaxDecode") or std.mem.eql(u8, last, "CCF");
    };
    const bpc: u8 = if (img.is_mask or is_fax) 1 else blk: {
        const b = doc.getInt(img.stream.dict, "BitsPerComponent") orelse doc.getInt(img.stream.dict, "BPC") orelse 8;
        break :blk switch (b) {
            1, 2, 4, 8, 16 => @intCast(b),
            else => return error.BadImage,
        };
    };
    return .{ .pixels = try fromSamplesBpc(doc, a, img, dec.data, img.width, img.height, @intCast(img.space.components()), bpc) };
}

/// 1-bit samples from CCITTFaxDecode data and its `/DecodeParms` (7.4.6).
fn faxSamples(doc: *Document, a: Allocator, data: []const u8, parms: Dict, width: u32, height: u32) Error![]const u8 {
    const boolOf = struct {
        fn f(d: *Document, p: Dict, k: []const u8) bool {
            const v = d.get(p, k) orelse return false;
            return v == .boolean and v.boolean;
        }
    }.f;
    const p: ccitt.Params = .{
        .k = @intCast(std.math.clamp(doc.getInt(parms, "K") orelse 0, -1, 1 << 20)),
        .columns = @intCast(std.math.clamp(doc.getInt(parms, "Columns") orelse 1728, 1, 1 << 20)),
        .rows = height,
        .black_is_1 = boolOf(doc, parms, "BlackIs1"),
        .byte_align = boolOf(doc, parms, "EncodedByteAlign"),
    };
    const raw = ccitt.decode(a, data, p, max_pixels / 8) catch |e| return switch (e) {
        error.TooLarge => error.TooBig,
        error.OutOfMemory => error.OutOfMemory,
    };
    // The image's rows are `Width` pixels wide; the fax rows are `Columns` wide.
    if (p.columns == width) return raw;
    const src_stride = (@as(usize, p.columns) + 7) / 8;
    const dst_stride = (@as(usize, width) + 7) / 8;
    const out = try a.alloc(u8, dst_stride * height);
    @memset(out, if (p.black_is_1) 0 else 0xFF);
    for (0..height) |y| {
        const n = @min(src_stride, dst_stride);
        if ((y + 1) * src_stride <= raw.len) @memcpy(out[y * dst_stride ..][0..n], raw[y * src_stride ..][0..n]);
    }
    return out;
}

/// Pixels from 8-bit samples decoded by the caller's codec (`ncomp` samples per
/// pixel, rows tightly packed). The colour space, decode array and masks of
/// `img` are applied.
pub fn fromSamples(doc: *Document, a: Allocator, img: display.Image, samples: []const u8, width: u32, height: u32, ncomp: u8) Error!Pixels {
    return fromSamplesBpc(doc, a, img, samples, width, height, ncomp, 8);
}

/// Applies the soft mask, stencil mask or colour-key mask named in the image
/// dictionary `d` to pixels the caller decoded itself (a JPEG, say).
pub fn withMasks(doc: *Document, a: Allocator, d: Dict, px: Pixels) Error!Pixels {
    return applyMasks(doc, a, d, px);
}

fn decodeArray(doc: *Document, a: Allocator, d: Dict, n: usize) Allocator.Error!?[]const f64 {
    const arr = doc.getArray(d, "Decode") orelse doc.getArray(d, "D") orelse return null;
    if (arr.len < 2 * n) return null;
    const out = try a.alloc(f64, 2 * n);
    for (0..2 * n) |i| out[i] = doc.resolve(arr[i]).asNum() orelse return null;
    return out;
}

/// The `/Decode` pair of component `c` when the image has none (8.9.5.2,
/// table 90). Indexed images, whose samples are indices, are handled apart.
fn defaultRange(space: color.Space, c: usize) [2]f64 {
    return switch (space) {
        .lab => |lab| switch (c) {
            0 => .{ 0, 100 },
            1 => lab.range[0..2].*,
            else => lab.range[2..4].*,
        },
        else => .{ 0, 1 },
    };
}

/// One sample of `bpc` bits at sample index `idx` of a row starting at `row`.
fn sampleAt(row: []const u8, idx: usize, bpc: u8) u32 {
    switch (bpc) {
        8 => return if (idx < row.len) row[idx] else 0,
        16 => return if (idx * 2 + 1 < row.len) (@as(u32, row[idx * 2]) << 8) | row[idx * 2 + 1] else 0,
        else => {
            const bit = idx * bpc;
            const byte = bit / 8;
            if (byte >= row.len) return 0;
            const shift: u3 = @intCast(8 - bpc - bit % 8);
            return (row[byte] >> shift) & ((@as(u8, 1) << @intCast(bpc)) - 1);
        },
    }
}

fn fromSamplesBpc(doc: *Document, a: Allocator, img: display.Image, samples: []const u8, width: u32, height: u32, ncomp_in: u8, bpc: u8) Error!Pixels {
    if (width == 0 or height == 0 or @as(u64, width) * height > max_pixels) return error.TooBig;
    const d = img.stream.dict;
    const ncomp: usize = @max(1, ncomp_in);
    const rgba = try a.alloc(u8, @as(usize, width) * height * 4);
    const row_bytes = (@as(usize, width) * ncomp * bpc + 7) / 8;
    const maxv: f64 = @floatFromInt((@as(u32, 1) << @intCast(bpc)) - 1);

    if (img.is_mask) {
        // A stencil: painted where the sample is 0 (or 1 with /Decode [1 0]) (8.9.6.2).
        const dec = try decodeArray(doc, a, d, 1);
        const invert = if (dec) |dd| dd[0] > dd[1] else false;
        const rgb = switch (img.fill) {
            .color => |c| c,
            else => color.Rgb.black,
        };
        const r: u8 = @intFromFloat(rgb.r * 255 + 0.5);
        const g: u8 = @intFromFloat(rgb.g * 255 + 0.5);
        const b: u8 = @intFromFloat(rgb.b * 255 + 0.5);
        for (0..height) |y| {
            const row = if ((y + 1) * row_bytes <= samples.len) samples[y * row_bytes .. (y + 1) * row_bytes] else if (y * row_bytes < samples.len) samples[y * row_bytes ..] else samples[0..0];
            for (0..width) |x| {
                // One bit as decoded here, or a caller's wider sample, which
                // counts as 1 in its upper half.
                const s = sampleAt(row, x, bpc);
                const painted = (@as(f64, @floatFromInt(s)) < maxv / 2) != invert;
                const o = (y * width + x) * 4;
                rgba[o] = r;
                rgba[o + 1] = g;
                rgba[o + 2] = b;
                rgba[o + 3] = if (painted) 255 else 0;
            }
        }
        return .{ .width = width, .height = height, .rgba = rgba };
    }

    const space = img.space;
    const is_indexed = space == .indexed;
    const dec = try decodeArray(doc, a, d, ncomp);
    const color_key = try colorKey(doc, a, d, ncomp);

    // One-component spaces: a table of the colour of each sample value (up to 8 bits).
    var lut: ?[]color.Rgb = null;
    if (ncomp == 1 and bpc <= 8) {
        const n: usize = @as(usize, 1) << @intCast(bpc);
        const t = try a.alloc(color.Rgb, n);
        for (t, 0..) |*slot, v| {
            const val: f64 = @floatFromInt(v);
            const c = if (is_indexed) (if (dec) |dd| dd[0] + val * (dd[1] - dd[0]) / maxv else val) else (if (dec) |dd| dd[0] + val * (dd[1] - dd[0]) / maxv else val / maxv);
            slot.* = space.toRgb(&.{c});
        }
        lut = t;
    }

    var comps: [function_max]f64 = undefined;
    for (0..height) |y| {
        const start = y * row_bytes;
        const row = if (start + row_bytes <= samples.len) samples[start .. start + row_bytes] else if (start < samples.len) samples[start..] else samples[0..0];
        for (0..width) |x| {
            var rgb: color.Rgb = undefined;
            var keyed = color_key != null;
            if (lut) |t| {
                const s = sampleAt(row, x, bpc);
                rgb = t[s];
                if (color_key) |ck| keyed = s >= ck[0] and s <= ck[1];
            } else {
                for (0..@min(ncomp, function_max)) |c| {
                    const s = sampleAt(row, x * ncomp + c, bpc);
                    if (color_key) |ck| {
                        if (!(s >= ck[2 * c] and s <= ck[2 * c + 1])) keyed = false;
                    }
                    const v: f64 = @floatFromInt(s);
                    const range: [2]f64 = if (dec) |dd| dd[2 * c ..][0..2].* else defaultRange(space, c);
                    comps[c] = range[0] + v * (range[1] - range[0]) / maxv;
                }
                rgb = space.toRgb(comps[0..@min(ncomp, function_max)]);
            }
            const o = (y * width + x) * 4;
            rgba[o] = @intFromFloat(std.math.clamp(rgb.r, 0, 1) * 255 + 0.5);
            rgba[o + 1] = @intFromFloat(std.math.clamp(rgb.g, 0, 1) * 255 + 0.5);
            rgba[o + 2] = @intFromFloat(std.math.clamp(rgb.b, 0, 1) * 255 + 0.5);
            rgba[o + 3] = if (keyed) 0 else 255;
        }
    }
    var out: Pixels = .{ .width = width, .height = height, .rgba = rgba };
    out = try applyMasks(doc, a, d, out);
    return out;
}

const function_max = 32;

/// `/Mask` given as an array of ranges (colour key masking, 8.9.6.4).
fn colorKey(doc: *Document, a: Allocator, d: Dict, ncomp: usize) Allocator.Error!?[]const u32 {
    const m = doc.get(d, "Mask") orelse return null;
    const arr = m.asArray() orelse return null;
    if (arr.len < 2 * ncomp) return null;
    const out = try a.alloc(u32, 2 * ncomp);
    // No sample is wider than 16 bits.
    for (0..2 * ncomp) |i| out[i] = @intCast(std.math.clamp(doc.resolve(arr[i]).asInt() orelse return null, 0, 65535));
    return out;
}

/// `/SMask` (soft mask, 11.6.5.3) or `/Mask` as a stencil image (8.9.6.3):
/// becomes the alpha channel. A mask of another size is resampled by taking
/// the nearest pixel; if it is larger than the image, the image is enlarged to
/// its size so no mask detail is lost.
fn applyMasks(doc: *Document, a: Allocator, d: Dict, px: Pixels) Error!Pixels {
    const sm = doc.get(d, "SMask");
    const hm = doc.get(d, "Mask");
    const mask_obj = if (sm != null and sm.? == .stream) sm else if (hm != null and hm.? == .stream) hm else return px;
    const mst = mask_obj.?.stream;
    const mw: u32 = @intCast(std.math.clamp(doc.getInt(mst.dict, "Width") orelse return px, 1, 1 << 20));
    const mh: u32 = @intCast(std.math.clamp(doc.getInt(mst.dict, "Height") orelse return px, 1, 1 << 20));
    if (@as(u64, mw) * mh > max_pixels) return px;
    var dec = doc.decodeStreamIn(a, mst) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return px, // a damaged mask
    };
    var is_fax = false;
    if (dec.rest.len == 1 and (std.mem.eql(u8, dec.rest[0].name, "CCITTFaxDecode") or std.mem.eql(u8, dec.rest[0].name, "CCF"))) {
        // Made first: the new value is built from the one it replaces.
        const samples = try faxSamples(doc, a, dec.data, dec.rest[0].parms, mw, mh);
        dec = .{ .data = samples, .rest = &.{} };
        is_fax = true;
    }
    if (dec.rest.len > 0) {
        var out = px;
        out.pending_mask = .{ .codec = .{ .name = dec.rest[0].name, .data = dec.data, .parms = dec.rest[0].parms }, .dict = mst.dict };
        return out;
    }
    const is_stencil = isStencil(doc, mst.dict);
    const bpc: u8 = if (is_stencil or is_fax) 1 else blk: {
        const b = doc.getInt(mst.dict, "BitsPerComponent") orelse 8;
        break :blk switch (b) {
            1, 2, 4, 8, 16 => @intCast(b),
            else => 8,
        };
    };
    return applyAlpha(doc, a, mst.dict, px, dec.data, mw, mh, bpc);
}

fn isStencil(doc: *Document, mask_dict: Dict) bool {
    const v = doc.get(mask_dict, "ImageMask") orelse return false;
    return v == .boolean and v.boolean;
}

/// Applies a mask the caller decoded (`Pixels.pending_mask`): `samples` has one
/// byte per pixel of the `width` x `height` mask, rows tightly packed.
pub fn withMaskSamples(doc: *Document, a: Allocator, px: Pixels, mask: PendingMask, samples: []const u8, width: u32, height: u32) Error!Pixels {
    if (width == 0 or height == 0 or @as(u64, width) * height > max_pixels) return error.TooBig;
    var out = try applyAlpha(doc, a, mask.dict, px, samples, width, height, 8);
    out.pending_mask = null;
    return out;
}

/// `px` with the alpha channel taken from the mask samples.
fn applyAlpha(doc: *Document, a: Allocator, mask_dict: Dict, px: Pixels, data: []const u8, mw: u32, mh: u32, bpc: u8) Error!Pixels {
    const is_stencil = isStencil(doc, mask_dict);
    const mdec = try decodeArray(doc, a, mask_dict, 1);
    const invert = if (mdec) |dd| dd[0] > dd[1] else false;
    const maxv: f64 = @floatFromInt((@as(u32, 1) << @intCast(bpc)) - 1);
    const row_bytes = (@as(usize, mw) * bpc + 7) / 8;

    const tw = @max(px.width, mw);
    const th = @max(px.height, mh);
    if (@as(u64, tw) * th > max_pixels) return px;
    const out = try a.alloc(u8, @as(usize, tw) * th * 4);
    for (0..th) |y| {
        const sy = y * px.height / th;
        const my = y * mh / th;
        const mstart = my * row_bytes;
        const mrow = if (mstart + row_bytes <= data.len) data[mstart .. mstart + row_bytes] else if (mstart < data.len) data[mstart..] else data[0..0];
        for (0..tw) |x| {
            const sx = x * px.width / tw;
            const mx = x * mw / tw;
            const s = sampleAt(mrow, mx, bpc);
            const o = (y * tw + x) * 4;
            const src = (sy * px.width + sx) * 4;
            @memcpy(out[o .. o + 3], px.rgba[src .. src + 3]);
            var alpha: f64 = @as(f64, @floatFromInt(s)) / maxv;
            if (is_stencil) {
                // For a stencil, 1 means "masked out" unless Decode says otherwise.
                alpha = if ((alpha > 0.5) != invert) 0 else 1;
            } else if (invert) alpha = 1 - alpha;
            out[o + 3] = @intFromFloat(std.math.clamp(alpha, 0, 1) * 255 + 0.5);
        }
    }
    return .{ .width = tw, .height = th, .rgba = out };
}
