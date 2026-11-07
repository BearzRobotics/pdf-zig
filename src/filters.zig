//! Stream filters (ISO 32000-1:2008, 7.4) and the predictors of 7.4.4.4.
//!
//! Decoded here: FlateDecode, LZWDecode, ASCII85Decode, ASCIIHexDecode and
//! RunLengthDecode. The image codecs (DCTDecode, JPXDecode, JBIG2Decode,
//! CCITTFaxDecode) are not decoded; `decode` stops at the first of them and
//! returns it in `Result.rest` with the data it would decode.
//!
//! Damaged data is tolerated the way viewers do: a Flate or LZW stream that
//! breaks in the middle yields the bytes decoded so far.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");

pub const Error = error{
    /// The decoded data would be larger than the limit.
    TooLarge,
    /// A filter name this library does not know (and is not an image codec).
    UnsupportedFilter,
    OutOfMemory,
};

/// One entry of a stream's `/Filter` list with its `/DecodeParms`.
pub const Filter = struct {
    name: []const u8,
    parms: object.Dict = .{},
};

pub const Result = struct {
    data: []const u8,
    /// Filters that were not applied: empty, or the first image codec and any
    /// filters after it.
    rest: []const Filter,
};

fn canonical(name: []const u8) []const u8 {
    const aliases = [_][2][]const u8{
        .{ "AHx", "ASCIIHexDecode" }, .{ "A85", "ASCII85Decode" },  .{ "LZW", "LZWDecode" },
        .{ "Fl", "FlateDecode" },     .{ "RL", "RunLengthDecode" }, .{ "CCF", "CCITTFaxDecode" },
        .{ "DCT", "DCTDecode" },
    };
    for (aliases) |al| if (std.mem.eql(u8, name, al[0])) return al[1];
    return name;
}

fn isImageCodec(name: []const u8) bool {
    return std.mem.eql(u8, name, "DCTDecode") or std.mem.eql(u8, name, "JPXDecode") or
        std.mem.eql(u8, name, "JBIG2Decode") or std.mem.eql(u8, name, "CCITTFaxDecode");
}

/// Applies `filters` in order. Allocations come from `a` (intermediate buffers
/// are not freed; use an arena). `max` bounds every intermediate result.
pub fn decode(a: Allocator, data: []const u8, filters: []const Filter, max: usize) Error!Result {
    var cur = data;
    for (filters, 0..) |f, i| {
        const name = canonical(f.name);
        // A `/Crypt` filter only says how the data was encrypted; the document
        // has already decrypted it (7.4.10).
        if (std.mem.eql(u8, name, "Crypt")) continue;
        if (isImageCodec(name)) return .{ .data = cur, .rest = filters[i..] };
        if (std.mem.eql(u8, name, "FlateDecode")) {
            cur = try predict(a, try flateDecode(a, cur, max), f.parms, max);
        } else if (std.mem.eql(u8, name, "LZWDecode")) {
            const early = intParm(f.parms, "EarlyChange", 1) != 0;
            cur = try predict(a, try lzwDecode(a, cur, early, max), f.parms, max);
        } else if (std.mem.eql(u8, name, "ASCII85Decode")) {
            cur = try ascii85Decode(a, cur, max);
        } else if (std.mem.eql(u8, name, "ASCIIHexDecode")) {
            cur = try asciiHexDecode(a, cur, max);
        } else if (std.mem.eql(u8, name, "RunLengthDecode")) {
            cur = try runLengthDecode(a, cur, max);
        } else return error.UnsupportedFilter;
    }
    return .{ .data = cur, .rest = &.{} };
}

fn intParm(d: object.Dict, key: []const u8, default: i64) i64 {
    const v = d.get(key) orelse return default;
    return v.asInt() orelse default;
}

// ---- Flate (7.4.4) ------------------------------------------------------------------

fn inflate(a: Allocator, data: []const u8, container: flate.Container, max: usize) Error!?[]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, container, &window);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = dec.reader.readSliceShort(&buf) catch break; // damaged: keep what we have
        if (out.items.len + n > max) return error.TooLarge;
        try out.appendSlice(a, buf[0..n]);
        if (n < buf.len) break;
    }
    return out.items;
}

fn flateDecode(a: Allocator, data: []const u8, max: usize) Error![]const u8 {
    const first = (try inflate(a, data, .zlib, max)).?;
    if (first.len > 0 or data.len < 2) return first;
    // No bytes with a zlib header: some producers write raw deflate data.
    return (try inflate(a, data, .raw, max)).?;
}

// ---- LZW (7.4.4.2) -------------------------------------------------------------------

fn lzwDecode(a: Allocator, data: []const u8, early: bool, max: usize) Error![]const u8 {
    const Code = struct { prefix: u16, byte: u8, len: u16 };
    var table: [4096]Code = undefined;
    var out: std.ArrayList(u8) = .empty;

    var next: u16 = 258;
    var width: u5 = 9;
    var prev: ?u16 = null;
    var acc: u32 = 0;
    var bits: u5 = 0;
    var i: usize = 0;

    while (true) {
        while (bits < width) {
            if (i >= data.len) return out.items;
            acc = (acc << 8) | data[i];
            i += 1;
            bits += 8;
        }
        const code: u16 = @intCast((acc >> (bits - width)) & ((@as(u32, 1) << width) - 1));
        bits -= width;
        acc &= (@as(u32, 1) << bits) - 1;

        if (code == 256) {
            next = 258;
            width = 9;
            prev = null;
            continue;
        }
        if (code == 257) return out.items;

        var entry_len: usize = 0;
        var first_byte: u8 = 0;
        if (code < 256) {
            entry_len = 1;
            first_byte = @intCast(code);
        } else if (code < next) {
            entry_len = table[code - 258].len;
            var c = code;
            while (c >= 258) c = table[c - 258].prefix;
            first_byte = @intCast(c);
        } else if (code == next and prev != null) {
            // KwKwK case: the new entry is prev + first byte of prev.
            var c = prev.?;
            while (c >= 258) c = table[c - 258].prefix;
            first_byte = @intCast(c);
            entry_len = (if (prev.? < 256) @as(usize, 1) else table[prev.? - 258].len) + 1;
        } else return out.items; // invalid code: stop with what we have

        if (out.items.len + entry_len > max) return error.TooLarge;
        const start = out.items.len;
        try out.resize(a, start + entry_len);
        if (code == next and prev != null) {
            // Fill: prev expansion then first_byte.
            var c = prev.?;
            var k = entry_len - 1;
            out.items[start + k] = first_byte;
            while (k > 0) {
                k -= 1;
                if (c < 256) {
                    out.items[start + k] = @intCast(c);
                } else {
                    out.items[start + k] = table[c - 258].byte;
                    c = table[c - 258].prefix;
                    continue;
                }
                break;
            }
        } else {
            var c = code;
            var k = entry_len;
            while (k > 0) {
                k -= 1;
                if (c < 256) {
                    out.items[start + k] = @intCast(c);
                    break;
                }
                out.items[start + k] = table[c - 258].byte;
                c = table[c - 258].prefix;
            }
        }

        if (prev) |p| {
            if (next < 4096) {
                const plen: u16 = if (p < 256) 1 else table[p - 258].len;
                table[next - 258] = .{ .prefix = p, .byte = first_byte, .len = plen + 1 };
                next += 1;
            }
        }
        prev = code;

        const limit: u16 = if (early) next + 1 else next;
        width = if (limit >= 2048) 12 else if (limit >= 1024) 11 else if (limit >= 512) 10 else 9;
    }
}

// ---- ASCII filters (7.4.2, 7.4.3) -----------------------------------------------------

fn asciiHexDecode(a: Allocator, data: []const u8, max: usize) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var hi: ?u8 = null;
    for (data) |c| {
        if (c == '>') break;
        const v: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue, // white space and junk are ignored
        };
        if (hi) |h| {
            if (out.items.len + 1 > max) return error.TooLarge;
            try out.append(a, h * 16 + v);
            hi = null;
        } else hi = v;
    }
    if (hi) |h| try out.append(a, h * 16);
    return out.items;
}

fn ascii85Decode(a: Allocator, data: []const u8, max: usize) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var group: [5]u8 = undefined;
    var n: usize = 0;
    var s = data;
    if (std.mem.startsWith(u8, s, "<~")) s = s[2..];
    for (s) |c| {
        if (c == '~') break;
        if (object.isWhite(c)) continue;
        if (c == 'z' and n == 0) {
            if (out.items.len + 4 > max) return error.TooLarge;
            try out.appendNTimes(a, 0, 4);
            continue;
        }
        if (c < '!' or c > 'u') continue; // not a base-85 digit
        group[n] = c - '!';
        n += 1;
        if (n == 5) {
            var v: u64 = 0;
            for (group) |d| v = v * 85 + d;
            const w: u32 = @truncate(v);
            if (out.items.len + 4 > max) return error.TooLarge;
            try out.appendSlice(a, &.{ @intCast(w >> 24), @intCast((w >> 16) & 255), @intCast((w >> 8) & 255), @intCast(w & 255) });
            n = 0;
        }
    }
    if (n > 1) {
        // A final group of n digits stands for n-1 bytes: pad with 'u'.
        var v: u64 = 0;
        for (0..5) |k| v = v * 85 + (if (k < n) group[k] else 84);
        const w: u32 = @truncate(v);
        const bytes = [4]u8{ @intCast(w >> 24), @intCast((w >> 16) & 255), @intCast((w >> 8) & 255), @intCast(w & 255) };
        try out.appendSlice(a, bytes[0 .. n - 1]);
    }
    return out.items;
}

// ---- RunLength (7.4.5) ---------------------------------------------------------------

fn runLengthDecode(a: Allocator, data: []const u8, max: usize) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < data.len) {
        const len = data[i];
        i += 1;
        if (len == 128) break;
        if (len < 128) {
            const n = @as(usize, len) + 1;
            const avail = @min(n, data.len - i);
            if (out.items.len + avail > max) return error.TooLarge;
            try out.appendSlice(a, data[i .. i + avail]);
            i += avail;
        } else {
            if (i >= data.len) break;
            const n = 257 - @as(usize, len);
            if (out.items.len + n > max) return error.TooLarge;
            try out.appendNTimes(a, data[i], n);
            i += 1;
        }
    }
    return out.items;
}

// ---- Predictors (7.4.4.4) ------------------------------------------------------------

fn predict(a: Allocator, data: []const u8, parms: object.Dict, max: usize) Error![]const u8 {
    const predictor = intParm(parms, "Predictor", 1);
    if (predictor <= 1) return data;
    const colors: usize = @intCast(std.math.clamp(intParm(parms, "Colors", 1), 1, 32));
    const bpc: usize = @intCast(std.math.clamp(intParm(parms, "BitsPerComponent", 8), 1, 16));
    const columns: usize = @intCast(std.math.clamp(intParm(parms, "Columns", 1), 1, 1 << 24));
    const row_bytes = (colors * bpc * columns + 7) / 8;
    const bpp = @max(1, (colors * bpc + 7) / 8);

    if (predictor == 2) {
        // TIFF predictor 2: each sample is the difference from the one to its left.
        if (bpc != 8 and bpc != 16) return data; // 1, 2 and 4 bits: left as they are
        const out = try a.dupe(u8, data);
        var row: usize = 0;
        while (row * row_bytes < out.len) : (row += 1) {
            const line = out[row * row_bytes .. @min(out.len, (row + 1) * row_bytes)];
            if (bpc == 8) {
                var k: usize = colors;
                while (k < line.len) : (k += 1) line[k] +%= line[k - colors];
            } else {
                const step = colors * 2;
                var k: usize = step;
                while (k + 1 < line.len) : (k += 2) {
                    const left = (@as(u16, line[k - step]) << 8) | line[k - step + 1];
                    const cur = (@as(u16, line[k]) << 8) | line[k + 1];
                    const sum = cur +% left;
                    line[k] = @intCast(sum >> 8);
                    line[k + 1] = @intCast(sum & 255);
                }
            }
        }
        return out;
    }

    // PNG predictors (10..15): every row starts with a tag byte.
    const stride = row_bytes + 1;
    const rows = (data.len + stride - 1) / stride;
    if (rows * row_bytes > max) return error.TooLarge;
    var out = try a.alloc(u8, rows * row_bytes);
    @memset(out, 0);
    var prev_row: []const u8 = out[0..0];
    var written: usize = 0;
    for (0..rows) |r| {
        const src_start = r * stride;
        const tag = data[src_start];
        const src = data[src_start + 1 .. @min(data.len, src_start + stride)];
        const dst = out[r * row_bytes .. r * row_bytes + row_bytes];
        @memcpy(dst[0..src.len], src);
        written = r * row_bytes + src.len;
        switch (tag) {
            0 => {},
            1 => for (bpp..dst.len) |k| {
                dst[k] +%= dst[k - bpp];
            },
            2 => if (prev_row.len > 0) for (0..dst.len) |k| {
                dst[k] +%= prev_row[k];
            },
            3 => for (0..dst.len) |k| {
                const left: u16 = if (k >= bpp) dst[k - bpp] else 0;
                const up: u16 = if (prev_row.len > 0) prev_row[k] else 0;
                dst[k] +%= @intCast((left + up) / 2);
            },
            4 => for (0..dst.len) |k| {
                const left: i32 = if (k >= bpp) dst[k - bpp] else 0;
                const up: i32 = if (prev_row.len > 0) prev_row[k] else 0;
                const ul: i32 = if (k >= bpp and prev_row.len > 0) prev_row[k - bpp] else 0;
                dst[k] +%= paeth(left, up, ul);
            },
            else => {}, // unknown tag: row used as it is
        }
        prev_row = dst;
    }
    return out[0..@min(written, out.len)];
}

fn paeth(a: i32, b: i32, c: i32) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);
    return @intCast(c);
}

// ---- tests ----------------------------------------------------------------------------

fn run(a: Allocator, name: []const u8, data: []const u8) ![]const u8 {
    const r = try decode(a, data, &.{.{ .name = name }}, 1 << 20);
    return r.data;
}

test "ASCIIHexDecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Nov", try run(a, "ASCIIHexDecode", "4E 6f\n76>junk"));
    try std.testing.expectEqualStrings("\x70", try run(a, "AHx", "7>")); // odd digit count pads with 0
}

test "ASCII85Decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Man ", try run(a, "ASCII85Decode", "9jqo^~>"));
    try std.testing.expectEqualStrings("Man ", try run(a, "A85", "<~9jqo^~>"));
    try std.testing.expectEqualStrings("Ma", try run(a, "ASCII85Decode", "9jn~>")); // partial group
    try std.testing.expectEqualStrings("\x00\x00\x00\x00", try run(a, "ASCII85Decode", "z~>"));
}

test "RunLengthDecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("abcxxx", try run(a, "RunLengthDecode", "\x02abc\xfex\x80ignored"));
    try std.testing.expectEqualStrings("ab", try run(a, "RL", "\x05ab")); // truncated literal run
}

test "LZWDecode: the example of 7.4.4.2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enc = [_]u8{ 0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01 };
    const want = [_]u8{ 45, 45, 45, 45, 45, 65, 45, 45, 45, 66 };
    try std.testing.expectEqualSlices(u8, &want, try run(a, "LZWDecode", &enc));
}

test "FlateDecode, raw deflate, truncated data and the size limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x27, 0x01, 0x68, 0x03, 0x08, 0xb1 };
    try std.testing.expectEqualStrings("hello hello hello hello", try run(a, "FlateDecode", &z));
    // Damaged tail: the part before the damage is still returned (no crash).
    _ = try run(a, "Fl", z[0..9]);
    try std.testing.expectError(error.TooLarge, decode(a, &z, &.{.{ .name = "FlateDecode" }}, 5));
    try std.testing.expectError(error.UnsupportedFilter, run(a, "NoSuchDecode", "x"));
}

test "image codecs are left for the caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try decode(a, "6162", &.{ .{ .name = "ASCIIHexDecode" }, .{ .name = "DCTDecode" } }, 100);
    try std.testing.expectEqualStrings("ab", r.data);
    try std.testing.expectEqual(@as(usize, 1), r.rest.len);
    try std.testing.expectEqualStrings("DCTDecode", r.rest[0].name);
}

fn pngParms(a: Allocator, columns: i64) !object.Dict {
    const entries = try a.alloc(object.Entry, 2);
    entries[0] = .{ .key = "Predictor", .value = .{ .integer = 12 } };
    entries[1] = .{ .key = "Columns", .value = .{ .integer = columns } };
    return .{ .entries = entries };
}

test "PNG predictors: Sub, Up, Average, Paeth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 3 columns, 1 byte per pixel. Row 1 Sub, row 2 Up, row 3 Average, row 4 Paeth.
    const raw = [_]u8{
        1, 1, 2, 3, // Sub:     1 3 6
        2, 1, 1, 1, // Up:      2 4 7
        3, 2, 2, 2, // Average: 2+(0+2)/2=3, 2+(3+4)/2=5, 2+(5+7)/2=8
        4, 1, 1, 1, // Paeth
    };
    const out = try predict(a, &raw, try pngParms(a, 3), 1 << 16);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 6, 2, 4, 7, 3, 5, 8 }, out[0..9]);
    try std.testing.expectEqual(@as(usize, 12), out.len);
    // Paeth, row 4: the first byte is predicted from the byte above (3): 1+3=4.
    try std.testing.expectEqual(@as(u8, 4), out[9]);
}

test "TIFF predictor 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(object.Entry, 3);
    entries[0] = .{ .key = "Predictor", .value = .{ .integer = 2 } };
    entries[1] = .{ .key = "Columns", .value = .{ .integer = 3 } };
    entries[2] = .{ .key = "Colors", .value = .{ .integer = 1 } };
    const out = try predict(a, &.{ 5, 1, 1, 10, 255, 2 }, .{ .entries = entries }, 1 << 16);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 10, 9, 11 }, out);
}

test "predictor limits and short data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A last row shorter than a full row does not read out of bounds.
    const out = try predict(a, &.{ 0, 9, 9, 9, 1, 4 }, try pngParms(a, 3), 1 << 16);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 4 }, out);
    try std.testing.expectError(error.TooLarge, predict(a, &.{ 0, 1, 2, 3 }, try pngParms(a, 3), 2));
}
