//! PDF functions (ISO 32000-1:2008, 7.10): sampled (type 0), exponential
//! (type 2), stitching (type 3) and PostScript calculator (type 4).
//!
//! A `Function` is parsed once from its dictionary or stream; `eval` maps
//! input values to output values. Evaluation never allocates and never fails:
//! inputs are clamped to the domain and bad data gives zeros.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const Object = object.Object;

pub const max_inputs = 8;
pub const max_outputs = 32;

pub const Kind = union(enum) {
    sampled: Sampled,
    exponential: Exponential,
    stitching: Stitching,
    calculator: []const Instr,
};

pub const Function = struct {
    domain: []const f64,
    range: []const f64,
    kind: Kind,

    pub fn nInputs(self: Function) usize {
        return @min(self.domain.len / 2, max_inputs);
    }

    pub fn nOutputs(self: Function) usize {
        return switch (self.kind) {
            .exponential => |e| @min(e.c0.len, max_outputs),
            .stitching => |s| if (s.funcs.len > 0) s.funcs[0].nOutputs() else 0,
            else => @min(self.range.len / 2, max_outputs),
        };
    }

    /// Evaluates the function. `out` must hold `nOutputs()` values.
    pub fn eval(self: Function, in: []const f64, out: []f64) void {
        @memset(out, 0);
        var x: [max_inputs]f64 = undefined;
        const n = @min(self.nInputs(), in.len);
        for (0..n) |i| x[i] = std.math.clamp(in[i], self.domain[2 * i], @max(self.domain[2 * i], self.domain[2 * i + 1]));
        switch (self.kind) {
            .sampled => |s| s.eval(x[0..n], out),
            .exponential => |e| e.eval(x[0], out),
            .stitching => |s| s.eval(self.domain, x[0], out),
            .calculator => |code| runCalculator(code, x[0..n], out),
        }
        // Clip to the range (7.10.1).
        if (self.range.len >= 2 * out.len) for (out, 0..) |*o, i| {
            o.* = std.math.clamp(o.*, self.range[2 * i], @max(self.range[2 * i], self.range[2 * i + 1]));
        };
    }
};

pub const Sampled = struct {
    size: []const u32,
    bps: u8,
    encode: []const f64,
    decode: []const f64,
    n_out: usize,
    data: []const u8,
    domain: []const f64,

    fn sample(self: Sampled, index: usize, comp: usize) f64 {
        const bit = (index * self.n_out + comp) * self.bps;
        const max_v = std.math.pow(f64, 2, @floatFromInt(self.bps)) - 1;
        var v: u64 = 0;
        var k: usize = 0;
        while (k < self.bps) : (k += 1) {
            const at = bit + k;
            const byte_i = at / 8;
            if (byte_i >= self.data.len) return 0;
            const bitv = (self.data[byte_i] >> @intCast(7 - at % 8)) & 1;
            v = (v << 1) | bitv;
        }
        return @as(f64, @floatFromInt(v)) / max_v;
    }

    /// Multilinear interpolation over the input dimensions (7.10.2).
    fn eval(self: Sampled, x: []const f64, out: []f64) void {
        const m = x.len;
        var e: [max_inputs]f64 = undefined;
        var corner0: [max_inputs]usize = undefined;
        var frac: [max_inputs]f64 = undefined;
        for (0..m) |i| {
            const d0 = self.domain[2 * i];
            const d1 = self.domain[2 * i + 1];
            const t = if (d1 == d0) 0 else (x[i] - d0) / (d1 - d0);
            const e0 = self.encode[2 * i];
            const e1 = self.encode[2 * i + 1];
            const sz: f64 = @floatFromInt(self.size[i]);
            e[i] = std.math.clamp(e0 + t * (e1 - e0), 0, sz - 1);
            const fl = @floor(e[i]);
            corner0[i] = @intFromFloat(fl);
            frac[i] = e[i] - fl;
        }
        const corners = @as(usize, 1) << @intCast(m);
        for (0..@min(out.len, self.n_out)) |c| {
            var acc: f64 = 0;
            for (0..corners) |corner| {
                var weight: f64 = 1;
                var idx: usize = 0;
                var stride: usize = 1;
                for (0..m) |i| {
                    const hi = (corner >> @intCast(i)) & 1 == 1;
                    const pos = @min(corner0[i] + @as(usize, if (hi) 1 else 0), self.size[i] - 1);
                    weight *= if (hi) frac[i] else 1 - frac[i];
                    idx += pos * stride;
                    stride *= self.size[i];
                }
                if (weight > 0) acc += weight * self.sample(idx, c);
            }
            const d0 = self.decode[2 * c];
            const d1 = self.decode[2 * c + 1];
            out[c] = d0 + acc * (d1 - d0);
        }
    }
};

pub const Exponential = struct {
    c0: []const f64,
    c1: []const f64,
    n: f64,

    fn eval(self: Exponential, x: f64, out: []f64) void {
        const t = if (self.n == 1) x else std.math.pow(f64, x, self.n);
        for (0..@min(out.len, self.c0.len)) |i| {
            const c1 = if (i < self.c1.len) self.c1[i] else self.c0[i];
            out[i] = self.c0[i] + t * (c1 - self.c0[i]);
        }
    }
};

pub const Stitching = struct {
    funcs: []const Function,
    bounds: []const f64,
    encode: []const f64,

    fn eval(self: Stitching, domain: []const f64, x: f64, out: []f64) void {
        if (self.funcs.len == 0) return;
        var k: usize = 0;
        while (k < self.bounds.len and k + 1 < self.funcs.len and x >= self.bounds[k]) k += 1;
        const lo = if (k == 0) domain[0] else self.bounds[k - 1];
        const hi = if (k < self.bounds.len) self.bounds[k] else domain[1];
        const e0 = if (2 * k + 1 < self.encode.len) self.encode[2 * k] else 0;
        const e1 = if (2 * k + 1 < self.encode.len) self.encode[2 * k + 1] else 1;
        const t = if (hi == lo) e0 else e0 + (x - lo) / (hi - lo) * (e1 - e0);
        var in = [1]f64{t};
        self.funcs[k].eval(&in, out);
    }
};

// ---- PostScript calculator (type 4, 7.10.5) -------------------------------------------

pub const Instr = union(enum) {
    num: f64,
    op: Op,
    /// `{ ... } if`: skip `len` instructions when the condition is false.
    jump_false: u32,
    /// Unconditional skip of `len` instructions (between the branches of ifelse).
    jump: u32,
};

pub const Op = enum {
    abs,
    add,
    @"and",
    atan,
    bitshift,
    ceiling,
    copy,
    cos,
    cvi,
    cvr,
    div,
    dup,
    eq,
    exch,
    exp,
    false,
    floor,
    ge,
    gt,
    idiv,
    index,
    le,
    ln,
    log,
    lt,
    mod,
    mul,
    ne,
    neg,
    not,
    @"or",
    pop,
    roll,
    round,
    sin,
    sqrt,
    sub,
    true,
    truncate,
    xor,
};

fn compileCalculator(a: Allocator, src: []const u8) Allocator.Error![]const Instr {
    var code: std.ArrayList(Instr) = .empty;
    // Positions of `{` blocks being compiled: the index where each block starts.
    var open: std.ArrayList(usize) = .empty;
    // The outermost braces enclose the whole program and emit nothing.
    var wrapper_seen = false;
    var it = std.mem.tokenizeAny(u8, src, " \t\r\n\x00\x0c");
    while (it.next()) |tok0| {
        var tok = tok0;
        // Braces may touch their neighbours: split them off.
        while (tok.len > 0) {
            if (tok[0] == '{') {
                tok = tok[1..];
                if (!wrapper_seen) {
                    wrapper_seen = true;
                    continue;
                }
                // Placeholder for the jump that `if` / `ifelse` will patch.
                try code.append(a, .{ .jump_false = 0 });
                try open.append(a, code.items.len - 1);
                continue;
            }
            if (tok[0] == '}') {
                tok = tok[1..];
                continue;
            }
            const end = std.mem.indexOfAny(u8, tok, "{}") orelse tok.len;
            const word = tok[0..end];
            tok = tok[end..];
            if (std.fmt.parseFloat(f64, word)) |v| {
                try code.append(a, .{ .num = v });
            } else |_| if (std.mem.eql(u8, word, "if")) {
                // `{ body } if`: the block's open marker jumps over the body when false.
                const start = open.pop() orelse continue;
                code.items[start] = .{ .jump_false = @intCast(code.items.len - start - 1) };
            } else if (std.mem.eql(u8, word, "ifelse")) {
                // `{ a } { b } ifelse`: two blocks were opened; the second block's
                // marker becomes a jump over b, the first a conditional jump over a.
                const second = open.pop() orelse continue;
                const first = open.pop() orelse continue;
                // Insert a `jump` over block b at the end of block a.
                const b_len = code.items.len - second - 1;
                code.items[second] = .{ .jump = @intCast(b_len) };
                code.items[first] = .{ .jump_false = @intCast(second - first) };
            } else if (std.meta.stringToEnum(Op, word)) |op| {
                try code.append(a, .{ .op = op });
            }
        }
    }
    return code.items;
}

fn runCalculator(code: []const Instr, in: []const f64, out: []f64) void {
    var st: [100]f64 = undefined;
    var sp: usize = 0;
    for (in) |v| {
        if (sp < st.len) {
            st[sp] = v;
            sp += 1;
        }
    }
    var pc: usize = 0;
    var steps: usize = 0;
    while (pc < code.len and steps < 10_000) : (steps += 1) {
        const ins = code[pc];
        pc += 1;
        switch (ins) {
            .num => |v| {
                if (sp < st.len) {
                    st[sp] = v;
                    sp += 1;
                }
            },
            .jump => |n| pc += n,
            .jump_false => |n| {
                // For `if`, the condition is on the stack; for `ifelse` the same.
                if (sp == 0) return finish(st[0..sp], out);
                sp -= 1;
                if (st[sp] == 0) pc += n;
            },
            .op => |op| calc(op, &st, &sp),
        }
    }
    finish(st[0..sp], out);
}

fn finish(stack: []const f64, out: []f64) void {
    // The outputs are the top `out.len` values of the stack.
    if (stack.len >= out.len) {
        @memcpy(out, stack[stack.len - out.len ..]);
    } else {
        @memcpy(out[out.len - stack.len ..], stack);
    }
}

fn calc(op: Op, st: *[100]f64, sp: *usize) void {
    const n = sp.*;
    const need: usize = switch (op) {
        .abs, .ceiling, .cos, .cvi, .cvr, .dup, .floor, .ln, .log, .neg, .not, .pop, .round, .sin, .sqrt, .truncate, .copy, .index => 1,
        .true, .false => 0,
        else => 2,
    };
    if (n < need) return;
    switch (op) {
        .abs => st[n - 1] = @abs(st[n - 1]),
        .add => binary(st, sp, st[n - 2] + st[n - 1]),
        .sub => binary(st, sp, st[n - 2] - st[n - 1]),
        .mul => binary(st, sp, st[n - 2] * st[n - 1]),
        .div => binary(st, sp, if (st[n - 1] == 0) 0 else st[n - 2] / st[n - 1]),
        .idiv => binary(st, sp, if (@trunc(st[n - 1]) == 0) 0 else @trunc(@trunc(st[n - 2]) / @trunc(st[n - 1]))),
        .mod => binary(st, sp, if (@trunc(st[n - 1]) == 0) 0 else @rem(@trunc(st[n - 2]), @trunc(st[n - 1]))),
        .exp => binary(st, sp, std.math.pow(f64, st[n - 2], st[n - 1])),
        .atan => {
            var deg = std.math.atan2(st[n - 2], st[n - 1]) * 180 / std.math.pi;
            if (deg < 0) deg += 360;
            binary(st, sp, deg);
        },
        .ceiling => st[n - 1] = @ceil(st[n - 1]),
        .floor => st[n - 1] = @floor(st[n - 1]),
        .round => st[n - 1] = @floor(st[n - 1] + 0.5),
        .truncate, .cvi => st[n - 1] = @trunc(st[n - 1]),
        .cvr => {},
        .cos => st[n - 1] = @cos(st[n - 1] * std.math.pi / 180),
        .sin => st[n - 1] = @sin(st[n - 1] * std.math.pi / 180),
        .ln => st[n - 1] = if (st[n - 1] > 0) @log(st[n - 1]) else 0,
        .log => st[n - 1] = if (st[n - 1] > 0) std.math.log10(st[n - 1]) else 0,
        .sqrt => st[n - 1] = if (st[n - 1] >= 0) @sqrt(st[n - 1]) else 0,
        .neg => st[n - 1] = -st[n - 1],
        .not => st[n - 1] = if (st[n - 1] == 0) 1 else if (st[n - 1] == 1) 0 else @floatFromInt(~@as(i64, @intFromFloat(@trunc(st[n - 1])))),
        .@"and" => binary(st, sp, @floatFromInt(@as(i64, @intFromFloat(@trunc(st[n - 2]))) & @as(i64, @intFromFloat(@trunc(st[n - 1]))))),
        .@"or" => binary(st, sp, @floatFromInt(@as(i64, @intFromFloat(@trunc(st[n - 2]))) | @as(i64, @intFromFloat(@trunc(st[n - 1]))))),
        .xor => binary(st, sp, @floatFromInt(@as(i64, @intFromFloat(@trunc(st[n - 2]))) ^ @as(i64, @intFromFloat(@trunc(st[n - 1]))))),
        .bitshift => {
            const v: i64 = @intFromFloat(@trunc(st[n - 2]));
            const sh: i64 = @intFromFloat(@trunc(st[n - 1]));
            const r: i64 = if (sh >= 0) (if (sh < 62) v << @intCast(sh) else 0) else (if (-sh < 62) v >> @intCast(-sh) else 0);
            binary(st, sp, @floatFromInt(r));
        },
        .eq => binary(st, sp, b(st[n - 2] == st[n - 1])),
        .ne => binary(st, sp, b(st[n - 2] != st[n - 1])),
        .ge => binary(st, sp, b(st[n - 2] >= st[n - 1])),
        .gt => binary(st, sp, b(st[n - 2] > st[n - 1])),
        .le => binary(st, sp, b(st[n - 2] <= st[n - 1])),
        .lt => binary(st, sp, b(st[n - 2] < st[n - 1])),
        .true => push(st, sp, 1),
        .false => push(st, sp, 0),
        .pop => sp.* -= 1,
        .dup => push(st, sp, st[n - 1]),
        .exch => {
            const t = st[n - 1];
            st[n - 1] = st[n - 2];
            st[n - 2] = t;
        },
        .copy => {
            const k: usize = @intFromFloat(@max(0, @trunc(st[n - 1])));
            sp.* -= 1;
            if (k > sp.* or sp.* + k > st.len) return;
            const base = sp.* - k;
            for (0..k) |i| st[sp.* + i] = st[base + i];
            sp.* += k;
        },
        .index => {
            const k: usize = @intFromFloat(@max(0, @trunc(st[n - 1])));
            sp.* -= 1;
            if (k >= sp.*) return;
            st[sp.*] = st[sp.* - 1 - k];
            sp.* += 1;
        },
        .roll => {
            const j: i64 = @intFromFloat(@trunc(st[n - 1]));
            const cnt_f = @trunc(st[n - 2]);
            sp.* -= 2;
            if (cnt_f < 0 or cnt_f > @as(f64, @floatFromInt(sp.*))) return;
            const cnt: usize = @intFromFloat(cnt_f);
            if (cnt == 0) return;
            const shift: usize = @intCast(@mod(j, @as(i64, @intCast(cnt))));
            const base = sp.* - cnt;
            var tmp: [100]f64 = undefined;
            for (0..cnt) |i| tmp[(i + shift) % cnt] = st[base + i];
            for (0..cnt) |i| st[base + i] = tmp[i];
        },
    }
}

fn b(v: bool) f64 {
    return if (v) 1 else 0;
}

fn binary(st: *[100]f64, sp: *usize, v: f64) void {
    st[sp.* - 2] = v;
    sp.* -= 1;
}

fn push(st: *[100]f64, sp: *usize, v: f64) void {
    if (sp.* < st.len) {
        st[sp.*] = v;
        sp.* += 1;
    }
}

// ---- loading --------------------------------------------------------------------------

fn numArray(doc: *Document, o: ?Object) Allocator.Error![]const f64 {
    const arr = (doc.resolve(o orelse return &.{})).asArray() orelse return &.{};
    const out = try doc.arena.allocator().alloc(f64, arr.len);
    for (arr, 0..) |item, i| out[i] = doc.resolve(item).asNum() orelse 0;
    return out;
}

pub const LoadError = Allocator.Error || error{BadFunction};

/// Parses a function object (dictionary or stream), at most `depth` deep.
pub fn load(doc: *Document, obj: Object, depth: u8) LoadError!Function {
    if (depth > 8) return error.BadFunction;
    const a = doc.arena.allocator();
    const o = doc.resolve(obj);
    const d = o.asDict() orelse return error.BadFunction;
    const ftype = doc.getInt(d, "FunctionType") orelse return error.BadFunction;
    const domain = try numArray(doc, d.get("Domain"));
    const range = try numArray(doc, d.get("Range"));
    if (domain.len < 2 or domain.len > 2 * max_inputs) return error.BadFunction;

    switch (ftype) {
        0 => {
            if (o != .stream or range.len < 2) return error.BadFunction;
            const size_f = try numArray(doc, d.get("Size"));
            if (size_f.len != domain.len / 2) return error.BadFunction;
            const size = try a.alloc(u32, size_f.len);
            var total: usize = 1;
            for (size_f, 0..) |s, i| {
                size[i] = @intFromFloat(std.math.clamp(s, 1, 1 << 16));
                total = std.math.mul(usize, total, size[i]) catch return error.BadFunction;
            }
            const n_out = range.len / 2;
            if (total > (1 << 24) or n_out > max_outputs) return error.BadFunction;
            const bps: u8 = @intCast(std.math.clamp(doc.getInt(d, "BitsPerSample") orelse 8, 1, 32));
            var encode = try numArray(doc, d.get("Encode"));
            if (encode.len < domain.len) {
                const e = try a.alloc(f64, domain.len);
                for (0..size.len) |i| {
                    e[2 * i] = 0;
                    e[2 * i + 1] = @floatFromInt(size[i] - 1);
                }
                encode = e;
            }
            var decode = try numArray(doc, d.get("Decode"));
            if (decode.len < range.len) decode = range;
            const data = doc.streamData(o.stream) catch return error.BadFunction;
            return .{ .domain = domain, .range = range, .kind = .{ .sampled = .{
                .size = size,
                .bps = bps,
                .encode = encode,
                .decode = decode,
                .n_out = n_out,
                .data = data,
                .domain = domain,
            } } };
        },
        2 => {
            var c0 = try numArray(doc, d.get("C0"));
            var c1 = try numArray(doc, d.get("C1"));
            if (c0.len == 0) {
                const z = try a.alloc(f64, 1);
                z[0] = 0;
                c0 = z;
            }
            if (c1.len == 0) {
                const z = try a.alloc(f64, 1);
                z[0] = 1;
                c1 = z;
            }
            return .{ .domain = domain, .range = range, .kind = .{ .exponential = .{ .c0 = c0, .c1 = c1, .n = doc.getNum(d, "N") orelse 1 } } };
        },
        3 => {
            const fa = doc.getArray(d, "Functions") orelse return error.BadFunction;
            if (fa.len == 0 or fa.len > 256) return error.BadFunction;
            const funcs = try a.alloc(Function, fa.len);
            for (fa, 0..) |fo, i| funcs[i] = try load(doc, fo, depth + 1);
            return .{ .domain = domain, .range = range, .kind = .{ .stitching = .{
                .funcs = funcs,
                .bounds = try numArray(doc, d.get("Bounds")),
                .encode = try numArray(doc, d.get("Encode")),
            } } };
        },
        4 => {
            if (o != .stream or range.len < 2) return error.BadFunction;
            const text = doc.streamData(o.stream) catch return error.BadFunction;
            return .{ .domain = domain, .range = range, .kind = .{ .calculator = try compileCalculator(a, text) } };
        },
        else => return error.BadFunction,
    }
}

// ---- tests ----------------------------------------------------------------------------

fn calcTest(src: []const u8, in: []const f64, out: []f64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileCalculator(arena.allocator(), src);
    runCalculator(code, in, out);
}

test "calculator: arithmetic and stack operators" {
    var out: [1]f64 = undefined;
    try calcTest("{ 2 mul 1 add }", &.{3}, &out);
    try std.testing.expectEqual(@as(f64, 7), out[0]);
    try calcTest("{ dup mul }", &.{4}, &out);
    try std.testing.expectEqual(@as(f64, 16), out[0]);
    try calcTest("{ 10 exch sub }", &.{4}, &out);
    try std.testing.expectEqual(@as(f64, 6), out[0]);
    var two: [2]f64 = undefined;
    try calcTest("{ exch }", &.{ 1, 2 }, &two);
    try std.testing.expectEqualSlices(f64, &.{ 2, 1 }, &two);
    var three: [3]f64 = undefined;
    try calcTest("{ 3 1 roll }", &.{ 1, 2, 3 }, &three);
    try std.testing.expectEqualSlices(f64, &.{ 3, 1, 2 }, &three);
    var four: [4]f64 = undefined;
    try calcTest("{ 2 copy }", &.{ 5, 6 }, &four);
    try std.testing.expectEqualSlices(f64, &.{ 5, 6, 5, 6 }, &four);
}

test "calculator: if and ifelse" {
    var out: [1]f64 = undefined;
    try calcTest("{ dup 0.5 gt { pop 1 } { pop 0 } ifelse }", &.{0.9}, &out);
    try std.testing.expectEqual(@as(f64, 1), out[0]);
    try calcTest("{ dup 0.5 gt { pop 1 } { pop 0 } ifelse }", &.{0.1}, &out);
    try std.testing.expectEqual(@as(f64, 0), out[0]);
    try calcTest("{ dup 0 lt { neg } if }", &.{-3}, &out);
    try std.testing.expectEqual(@as(f64, 3), out[0]);
    try calcTest("{ dup 0 lt { neg } if }", &.{3}, &out);
    try std.testing.expectEqual(@as(f64, 3), out[0]);
}

test "calculator: damaged programs terminate" {
    var out: [3]f64 = undefined;
    try calcTest("{ pop pop pop pop add mul }", &.{1}, &out);
    try calcTest("{ { { ifelse }", &.{1}, &out);
    try calcTest("}}}{{{ if if ifelse 1000000 1000000 roll", &.{1}, &out);
    try calcTest("", &.{1}, &out);
}

test "exponential and stitching evaluation" {
    const f = Function{ .domain = &.{ 0, 1 }, .range = &.{}, .kind = .{ .exponential = .{ .c0 = &.{ 0, 1 }, .c1 = &.{ 1, 0 }, .n = 1 } } };
    var out: [2]f64 = undefined;
    f.eval(&.{0.25}, &out);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), out[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), out[1], 1e-9);
    f.eval(&.{5}, &out); // clamped to the domain
    try std.testing.expectApproxEqAbs(@as(f64, 1), out[0], 1e-9);

    const f1 = Function{ .domain = &.{ 0, 1 }, .range = &.{}, .kind = .{ .exponential = .{ .c0 = &.{0}, .c1 = &.{10}, .n = 1 } } };
    const f2 = Function{ .domain = &.{ 0, 1 }, .range = &.{}, .kind = .{ .exponential = .{ .c0 = &.{100}, .c1 = &.{200}, .n = 1 } } };
    const st = Function{ .domain = &.{ 0, 1 }, .range = &.{}, .kind = .{ .stitching = .{ .funcs = &.{ f1, f2 }, .bounds = &.{0.5}, .encode = &.{ 0, 1, 0, 1 } } } };
    var one: [1]f64 = undefined;
    st.eval(&.{0.25}, &one);
    try std.testing.expectApproxEqAbs(@as(f64, 5), one[0], 1e-9);
    st.eval(&.{0.75}, &one);
    try std.testing.expectApproxEqAbs(@as(f64, 150), one[0], 1e-9);
}
