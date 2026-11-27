// SPDX-License-Identifier: LGPL-2.0-or-later
//! The content-stream interpreter (ISO 32000-1:2008, clauses 8 and 9): turns a
//! page into a `display.DisplayList`.
//!
//! Handled: graphics state, paths, painting and clipping, colour (device,
//! CIE/ICC as device, Indexed, Separation, DeviceN, Lab), text including Type 3
//! fonts, form and image XObjects, inline images, axial and radial shadings,
//! shading and tiling patterns, optional content (layers), and annotation
//! appearance streams.
//!
//! Not handled (silently skipped, see docs/architecture.md): mesh and
//! function-based shadings, soft masks, blend modes beyond naming them,
//! vertical writing, text clipping modes, `d1` colour suppression in Type 3.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const doc_mod = @import("document.zig");
const content = @import("content.zig");
const display = @import("display.zig");
const color = @import("color.zig");
const function = @import("function.zig");
const font_mod = @import("font.zig");
const pages = @import("pages.zig");
const Document = doc_mod.Document;
const Object = object.Object;
const Dict = object.Dict;
const Matrix = display.Matrix;
const Point = display.Point;

pub const Options = struct {
    /// Most operators executed for one page (including forms and patterns).
    max_ops: usize = 8_000_000,
    /// Most commands for one page, those of pattern cells included.
    max_commands: usize = 4_000_000,
    /// Most glyphs and path segments in the commands of one page. A repeated
    /// form can produce any number of them with few commands.
    max_glyphs: usize = 4_000_000,
    max_path_segments: usize = 8_000_000,
    /// Most bytes of content interpreted for one page. A form, pattern cell or
    /// Type 3 glyph counts every time it is run, so this bounds repeated use of
    /// streams that execute few or no operators.
    max_content_bytes: usize = 512 << 20,
    /// Deepest nesting of forms, patterns and Type 3 glyphs.
    max_depth: u8 = 12,
    /// Build paths, images, shadings and Type 3 glyph drawings. Turn this off
    /// to get only the text runs, which is several times faster and needs far
    /// less memory (text extraction, search).
    graphics: bool = true,
};

pub const Error = Allocator.Error || doc_mod.Error || error{LimitExceeded};

/// Renders pages of one document. Fonts are cached in the document.
pub const Renderer = struct {
    doc: *Document,
    options: Options,
    /// Object numbers of optional content groups that are off in the default configuration.
    ocg_off: std.AutoHashMapUnmanaged(u32, void) = .empty,
    ocg_loaded: bool = false,
    /// Decoded content streams and operands: reset after every page, so that
    /// rendering many pages does not keep every page's content in memory.
    scratch: ?std.heap.ArenaAllocator = null,
    /// Streams already decoded for the current page, keyed by where their raw
    /// data is. The values live in `scratch`.
    decoded: std.AutoHashMapUnmanaged(StreamKey, []const u8) = .empty,

    /// What the current page's display list and pattern cells hold so far.
    produced: struct { commands: usize = 0, glyphs: usize = 0, segments: usize = 0 } = .{},

    const StreamKey = struct { ptr: usize, len: usize };

    pub fn init(doc: *Document, options: Options) Renderer {
        return .{ .doc = doc, .options = options };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.scratch) |*s| s.deinit();
    }

    /// Interprets page `p`. The result is owned by the caller (`DisplayList.deinit`);
    /// fonts it points to belong to the document.
    pub fn render(self: *Renderer, gpa: Allocator, p: pages.Page) Error!display.DisplayList {
        var list: display.DisplayList = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer list.arena.deinit();
        const size = p.displaySize();
        list.width = size.w;
        list.height = size.h;
        list.base = baseMatrix(p);

        // Kept between pages, so it comes from the document's allocator: `gpa`
        // only has to live as long as the list it is used for.
        if (self.scratch == null) self.scratch = std.heap.ArenaAllocator.init(self.doc.arena.child_allocator);
        self.decoded = .empty;
        self.produced = .{};
        defer {
            self.decoded = .empty;
            _ = self.scratch.?.reset(.{ .retain_with_limit = 4 << 20 });
        }
        const scratch = self.scratch.?.allocator();
        const oom_before = self.doc.oom_events;
        var run: Run = .{ .r = self, .a = list.arena.allocator(), .scratch = scratch };
        const data = try pages.contents(self.doc, scratch, p);
        run.gs = .{};
        try run.interpret(data, p.resources, .identity);
        try run.annotations(p);
        // Missing content must not pass for success.
        try self.doc.checkMemory(oom_before);
        list.commands = run.commands.items;
        return list;
    }

    fn loadOcgs(self: *Renderer) void {
        if (self.ocg_loaded) return;
        self.ocg_loaded = true;
        const doc = self.doc;
        const a = doc.arena.allocator();
        const oom_before = doc.oom_events;
        // Read again next time if it could not be read completely now.
        defer if (doc.oom_events != oom_before) {
            self.ocg_loaded = false;
        };
        const cat = doc.catalog() orelse return;
        const props = doc.getDict(cat, "OCProperties") orelse return;
        const d = doc.getDict(props, "D") orelse return;
        const base_off = if (doc.getName(d, "BaseState")) |b| std.mem.eql(u8, b, "OFF") else false;
        if (base_off) {
            if (doc.getArray(props, "OCGs")) |all| for (all) |g| if (g == .ref) {
                self.ocg_off.put(a, g.ref.num, {}) catch |err| doc.noteError(err);
            };
            if (doc.getArray(d, "ON")) |on| for (on) |g| if (g == .ref) {
                _ = self.ocg_off.remove(g.ref.num);
            };
        } else if (doc.getArray(d, "OFF")) |off| for (off) |g| if (g == .ref) {
            self.ocg_off.put(a, g.ref.num, {}) catch |err| doc.noteError(err);
        };
    }

    /// True if the optional-content entry `oc` (an OCG or OCMD) hides content.
    fn hidden(self: *Renderer, oc: Object) bool {
        self.loadOcgs();
        const doc = self.doc;
        if (oc == .ref) if (self.ocg_off.contains(oc.ref.num)) return true;
        const d = doc.resolve(oc).asDict() orelse return false;
        const ty = doc.getName(d, "Type") orelse return false;
        if (!std.mem.eql(u8, ty, "OCMD")) return false;
        var groups = d.get("OCGs") orelse return false;
        // `/OCGs` is one group or an array of them, either of which may be
        // given by reference.
        if (doc.resolve(groups) == .array) groups = doc.resolve(groups);
        var any_on = false;
        var any_off = false;
        var all_on = true;
        var count: usize = 0;
        const check = struct {
            fn one(rr: *Renderer, g: Object, on: *bool, off: *bool, all: *bool, n: *usize) void {
                n.* += 1;
                const is_off = g == .ref and rr.ocg_off.contains(g.ref.num);
                if (is_off) {
                    off.* = true;
                    all.* = false;
                } else on.* = true;
            }
        }.one;
        switch (groups) {
            .ref => check(self, groups, &any_on, &any_off, &all_on, &count),
            .array => |arr| for (arr) |g| check(self, g, &any_on, &any_off, &all_on, &count),
            else => {},
        }
        if (count == 0) return false;
        const policy = doc.getName(d, "P") orelse "AnyOn";
        const visible = if (std.mem.eql(u8, policy, "AllOn")) all_on else if (std.mem.eql(u8, policy, "AnyOff")) any_off else if (std.mem.eql(u8, policy, "AllOff")) !any_on else any_on;
        return !visible;
    }

    /// `dict_obj` must be part of the document (from a resource dictionary).
    fn font(self: *Renderer, dict_obj: Object) Allocator.Error!?*const font_mod.Font {
        const doc = self.doc;
        const num: u32 = if (dict_obj == .ref) dict_obj.ref.num else 0;
        const key = Document.cacheKey(dict_obj, true);
        if (key) |k| if (doc.fonts.get(k)) |f| return f;
        const d = doc.resolve(dict_obj).asDict() orelse return null;
        const a = doc.arena.allocator();
        const f = try a.create(font_mod.Font);
        const oom_before = doc.oom_events;
        f.* = try font_mod.Font.load(doc, d, num);
        try doc.checkMemory(oom_before);
        if (key) |k| try doc.fonts.put(a, k, f);
        return f;
    }
};

/// Maps default user space to the displayed page for `p` (see `display`).
pub fn baseMatrix(p: pages.Page) Matrix {
    const c = p.crop_box;
    return switch (p.rotate) {
        90 => .{ .a = 0, .b = 1, .c = 1, .d = 0, .e = -c.y0, .f = -c.x0 },
        180 => .{ .a = -1, .b = 0, .c = 0, .d = 1, .e = c.x1, .f = -c.y0 },
        270 => .{ .a = 0, .b = -1, .c = -1, .d = 0, .e = c.y1, .f = c.x1 },
        else => .{ .a = 1, .b = 0, .c = 0, .d = -1, .e = -c.x0, .f = c.y1 },
    };
}

const Paint = display.Paint;

const ColorState = struct {
    space: color.Space = .gray,
    comps: [function.max_outputs]f64 = @splat(0),
    paint: Paint = .{ .color = color.Rgb.black },
};

const GState = struct {
    ctm: Matrix = .identity,
    fill: ColorState = .{},
    stroke: ColorState = .{},
    line: display.StrokeStyle = .{},
    fill_alpha: f64 = 1,
    stroke_alpha: f64 = 1,
    blend: []const u8 = "Normal",
    // Text state (9.3).
    font: ?*const font_mod.Font = null,
    size: f64 = 0,
    tc: f64 = 0,
    tw: f64 = 0,
    th: f64 = 1,
    tl: f64 = 0,
    mode: u8 = 0,
    rise: f64 = 0,
};

const Opn = enum {
    q,
    Q,
    cm,
    w,
    J,
    j,
    M,
    d,
    ri,
    i,
    gs,
    m,
    l,
    c,
    v,
    y,
    h,
    re,
    S,
    s,
    f,
    F,
    @"f*",
    B,
    @"B*",
    b,
    @"b*",
    n,
    W,
    @"W*",
    BT,
    ET,
    Tc,
    Tw,
    Tz,
    TL,
    Tf,
    Tr,
    Ts,
    Td,
    TD,
    Tm,
    @"T*",
    Tj,
    TJ,
    @"'",
    @"\"",
    d0,
    d1,
    CS,
    cs,
    SC,
    SCN,
    sc,
    scn,
    G,
    g,
    RG,
    rg,
    K,
    k,
    sh,
    BI,
    Do,
    MP,
    DP,
    BMC,
    BDC,
    EMC,
    BX,
    EX,
};

const max_gs_depth = 256;

const Run = struct {
    r: *Renderer,
    /// Allocator for the results (the display list's arena).
    a: Allocator,
    /// Allocator for data needed only while the page is interpreted.
    scratch: Allocator,
    commands: std.ArrayList(display.Command) = .empty,
    gs: GState = .{},
    stack: std.ArrayList(GState) = .empty,
    path: std.ArrayList(display.Seg) = .empty,
    cur: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    pending_clip: ?display.FillRule = null,
    tm: Matrix = .identity,
    tlm: Matrix = .identity,
    /// CTM at the start of the current content stream: patterns are relative to it.
    base_ctm: Matrix = .identity,
    resources: Dict = .{},
    /// `q` levels below this belong to the callers of the current content
    /// stream, which its `Q` operators must not pop.
    floor: usize = 0,
    /// The same for marked content: sections below this are the callers'.
    mc_floor: usize = 0,
    ops: usize = 0,
    content_bytes: usize = 0,
    depth: u8 = 0,
    /// Marked-content nesting: how many open sections hide their content.
    hidden_depth: u32 = 0,
    mc_stack: std.ArrayList(bool) = .empty,
    active_forms: std.AutoHashMapUnmanaged(u32, void) = .empty,
    tiling_cache: std.AutoHashMapUnmanaged(u64, *display.DisplayList) = .empty,
    type3: bool = false,

    fn doc(self: *Run) *Document {
        return self.r.doc;
    }

    fn emit(self: *Run, c: display.Command) Error!void {
        if (!self.r.options.graphics) switch (c) {
            .text => {},
            else => return,
        };
        // Hidden content makes no marks, but still changes the graphics state,
        // clipping included.
        if (self.hidden_depth > 0) switch (c) {
            .save, .restore, .clip => {},
            else => return,
        };
        if (self.r.produced.commands >= self.r.options.max_commands) return error.LimitExceeded;
        self.r.produced.commands += 1;
        try self.commands.append(self.a, c);
    }

    // ---- the operator loop ------------------------------------------------------------

    fn interpret(self: *Run, data: []const u8, resources: Dict, base: Matrix) Error!void {
        const saved_res = self.resources;
        const saved_base = self.base_ctm;
        const saved_depth = self.stack.items.len;
        const saved_floor = self.floor;
        self.floor = saved_depth;
        defer self.floor = saved_floor;
        const saved_mc_floor = self.mc_floor;
        self.mc_floor = self.mc_stack.items.len;
        defer {
            // Sections left open end with their stream.
            while (self.mc_stack.items.len > self.mc_floor) self.endMarked();
            self.mc_floor = saved_mc_floor;
        }
        self.resources = resources;
        self.base_ctm = base;
        defer {
            self.resources = saved_res;
            self.base_ctm = saved_base;
        }
        if (data.len > self.r.options.max_content_bytes -| self.content_bytes) return error.LimitExceeded;
        self.content_bytes += data.len;
        var sc = content.Scanner.init(self.scratch, data);
        while (try sc.next()) |op| {
            self.ops += 1;
            if (self.ops > self.r.options.max_ops) return error.LimitExceeded;
            try self.execute(op);
        }
        // A stream that leaves `q` open must not leak state into its parent.
        while (self.stack.items.len > saved_depth) try self.restore();
    }

    /// The decoded data of a stream run as content, decoded once per page.
    fn contentData(self: *Run, st: object.Stream) doc_mod.Error![]const u8 {
        const key: Renderer.StreamKey = .{ .ptr = @intFromPtr(st.data.ptr), .len = st.data.len };
        if (self.r.decoded.get(key)) |data| return data;
        const data = try self.doc().streamDataIn(self.scratch, st);
        try self.r.decoded.put(self.scratch, key, data);
        return data;
    }

    fn num(op: content.Op, i: usize) f64 {
        return if (i < op.operands.len) (op.operands[i].asNum() orelse 0) else 0;
    }

    /// Operand `i` truncated to an integer within [lo, hi]. The range is applied
    /// before the conversion: the operand may be any number, infinity included.
    fn intInRange(op: content.Op, i: usize, lo: i8, hi: i8) i8 {
        const v = num(op, i);
        if (std.math.isNan(v)) return 0;
        return @intFromFloat(std.math.clamp(@trunc(v), @as(f64, @floatFromInt(lo)), @as(f64, @floatFromInt(hi))));
    }

    /// Ends the innermost marked-content section.
    fn endMarked(self: *Run) void {
        const hide = self.mc_stack.pop() orelse return;
        if (hide and self.hidden_depth > 0) self.hidden_depth -= 1;
    }

    fn save(self: *Run) Error!void {
        if (self.stack.items.len >= max_gs_depth) return;
        try self.stack.append(self.a, self.gs);
        try self.emit(.save);
    }

    fn restore(self: *Run) Error!void {
        const prev = self.stack.pop() orelse return;
        self.gs = prev;
        try self.emit(.restore);
    }

    fn execute(self: *Run, op: content.Op) Error!void {
        const which = std.meta.stringToEnum(Opn, op.name) orelse return;
        switch (which) {
            .q => try self.save(),
            .Q => if (self.stack.items.len > self.floor) try self.restore(),
            .cm => {
                const m = Matrix{ .a = num(op, 0), .b = num(op, 1), .c = num(op, 2), .d = num(op, 3), .e = num(op, 4), .f = num(op, 5) };
                self.gs.ctm = m.mul(self.gs.ctm);
            },
            .w => self.gs.line.width = @abs(num(op, 0)),
            .J => self.gs.line.cap = switch (intInRange(op, 0, 0, 3)) {
                1 => .round,
                2 => .square,
                else => .butt,
            },
            .j => self.gs.line.join = switch (intInRange(op, 0, 0, 3)) {
                1 => .round,
                2 => .bevel,
                else => .miter,
            },
            .M => self.gs.line.miter_limit = num(op, 0),
            .d => {
                if (op.operands.len >= 2) if (op.operands[0].asArray()) |arr| {
                    const dash = try self.a.alloc(f64, arr.len);
                    var sum: f64 = 0;
                    for (arr, 0..) |x, k| {
                        dash[k] = @abs(x.asNum() orelse 0);
                        sum += dash[k];
                    }
                    self.gs.line.dash = if (sum > 0) dash else &.{};
                    self.gs.line.dash_phase = num(op, 1);
                };
            },
            .ri, .i, .MP, .DP, .BX, .EX, .d0 => {},
            .d1 => {},
            .gs => try self.extGState(op),

            .m => {
                self.cur = .{ .x = num(op, 0), .y = num(op, 1) };
                self.start = self.cur;
                try self.addSeg(.{ .move = self.cur });
            },
            .l => {
                self.cur = .{ .x = num(op, 0), .y = num(op, 1) };
                try self.addSeg(.{ .line = self.cur });
            },
            .c => {
                const p = Point{ .x = num(op, 4), .y = num(op, 5) };
                try self.addSeg(.{ .curve = .{ .c1 = .{ .x = num(op, 0), .y = num(op, 1) }, .c2 = .{ .x = num(op, 2), .y = num(op, 3) }, .p = p } });
                self.cur = p;
            },
            .v => {
                const p = Point{ .x = num(op, 2), .y = num(op, 3) };
                try self.addSeg(.{ .curve = .{ .c1 = self.cur, .c2 = .{ .x = num(op, 0), .y = num(op, 1) }, .p = p } });
                self.cur = p;
            },
            .y => {
                const p = Point{ .x = num(op, 2), .y = num(op, 3) };
                try self.addSeg(.{ .curve = .{ .c1 = .{ .x = num(op, 0), .y = num(op, 1) }, .c2 = p, .p = p } });
                self.cur = p;
            },
            .h => {
                try self.addSeg(.close);
                self.cur = self.start;
            },
            .re => {
                const x = num(op, 0);
                const y = num(op, 1);
                const w = num(op, 2);
                const h = num(op, 3);
                try self.addSeg(.{ .move = .{ .x = x, .y = y } });
                try self.addSeg(.{ .line = .{ .x = x + w, .y = y } });
                try self.addSeg(.{ .line = .{ .x = x + w, .y = y + h } });
                try self.addSeg(.{ .line = .{ .x = x, .y = y + h } });
                try self.addSeg(.close);
                self.start = .{ .x = x, .y = y };
                self.cur = self.start;
            },

            .S => try self.paint(false, true, .nonzero, false),
            .s => try self.paint(false, true, .nonzero, true),
            .f, .F => try self.paint(true, false, .nonzero, false),
            .@"f*" => try self.paint(true, false, .even_odd, false),
            .B => try self.paint(true, true, .nonzero, false),
            .@"B*" => try self.paint(true, true, .even_odd, false),
            .b => try self.paint(true, true, .nonzero, true),
            .@"b*" => try self.paint(true, true, .even_odd, true),
            .n => try self.paint(false, false, .nonzero, false),
            .W => self.pending_clip = .nonzero,
            .@"W*" => self.pending_clip = .even_odd,

            .BT => {
                self.tm = .identity;
                self.tlm = .identity;
            },
            .ET => {},
            .Tc => self.gs.tc = num(op, 0),
            .Tw => self.gs.tw = num(op, 0),
            .Tz => self.gs.th = num(op, 0) / 100.0,
            .TL => self.gs.tl = num(op, 0),
            .Tf => try self.setFont(op),
            .Tr => self.gs.mode = @intCast(intInRange(op, 0, 0, 7)),
            .Ts => self.gs.rise = num(op, 0),
            .Td => self.moveText(num(op, 0), num(op, 1)),
            .TD => {
                self.gs.tl = -num(op, 1);
                self.moveText(num(op, 0), num(op, 1));
            },
            .Tm => {
                self.tm = .{ .a = num(op, 0), .b = num(op, 1), .c = num(op, 2), .d = num(op, 3), .e = num(op, 4), .f = num(op, 5) };
                self.tlm = self.tm;
            },
            .@"T*" => self.moveText(0, -self.gs.tl),
            .Tj => try self.showOperands(op.operands),
            .TJ => if (op.operands.len > 0) if (op.operands[0].asArray()) |arr| try self.showOperands(arr),
            .@"'" => {
                self.moveText(0, -self.gs.tl);
                try self.showOperands(op.operands);
            },
            .@"\"" => {
                if (op.operands.len >= 3) {
                    self.gs.tw = num(op, 0);
                    self.gs.tc = num(op, 1);
                    self.moveText(0, -self.gs.tl);
                    try self.showOperands(op.operands[2..]);
                }
            },

            .CS => try self.setSpace(op, false),
            .cs => try self.setSpace(op, true),
            .SC, .SCN => try self.setColor(op, false),
            .sc, .scn => try self.setColor(op, true),
            .G => try self.setDevice(.gray, op, false),
            .g => try self.setDevice(.gray, op, true),
            .RG => try self.setDevice(.rgb, op, false),
            .rg => try self.setDevice(.rgb, op, true),
            .K => try self.setDevice(.cmyk, op, false),
            .k => try self.setDevice(.cmyk, op, true),

            .sh => try self.shadingOp(op),
            .BI => if (op.image) |im| try self.inlineImage(im),
            .Do => try self.doXObject(op),

            .BMC => try self.mc_stack.append(self.a, false),
            .BDC => {
                var hide = false;
                if (op.operands.len >= 2) {
                    const tag = op.operands[0].asName() orelse "";
                    if (std.mem.eql(u8, tag, "OC")) {
                        const props: ?Object = switch (op.operands[1]) {
                            .name => |n| blk: {
                                const pd = self.doc().getDict(self.resources, "Properties") orelse break :blk null;
                                break :blk pd.get(n);
                            },
                            else => op.operands[1],
                        };
                        if (props) |pr| hide = self.r.hidden(pr);
                    }
                }
                try self.mc_stack.append(self.a, hide);
                if (hide) self.hidden_depth += 1;
            },
            .EMC => if (self.mc_stack.items.len > self.mc_floor) self.endMarked(),
        }
    }

    // ---- paths ----------------------------------------------------------------------------

    fn addSeg(self: *Run, s: display.Seg) Error!void {
        if (!self.r.options.graphics) return;
        if (self.path.items.len > 5_000_000) return error.LimitExceeded;
        try self.path.append(self.a, s);
    }

    /// Counts and copies the current path into the list.
    fn keepPath(self: *Run) Error!display.Path {
        if (self.path.items.len > self.r.options.max_path_segments -| self.r.produced.segments) return error.LimitExceeded;
        self.r.produced.segments += self.path.items.len;
        return self.a.dupe(display.Seg, self.path.items);
    }

    fn paint(self: *Run, do_fill: bool, do_stroke: bool, rule: display.FillRule, close: bool) Error!void {
        defer {
            self.path.clearRetainingCapacity();
            self.pending_clip = null;
        }
        if (!self.r.options.graphics) return;
        if (close and self.path.items.len > 0) try self.addSeg(.close);
        if (self.path.items.len == 0) return;
        // A hidden path that does not clip leaves nothing in the list.
        if (self.hidden_depth > 0 and self.pending_clip == null) return;
        const p = try self.keepPath();
        if (do_fill) try self.emit(.{ .fill = .{ .path = p, .rule = rule, .paint = self.gs.fill.paint, .alpha = self.gs.fill_alpha, .ctm = self.gs.ctm, .blend = self.gs.blend } });
        if (do_stroke) try self.emit(.{ .stroke = .{ .path = p, .style = self.gs.line, .paint = self.gs.stroke.paint, .alpha = self.gs.stroke_alpha, .ctm = self.gs.ctm, .blend = self.gs.blend } });
        if (self.pending_clip) |cr| try self.emit(.{ .clip = .{ .path = p, .rule = cr, .ctm = self.gs.ctm } });
    }

    fn extGState(self: *Run, op: content.Op) Error!void {
        const name = (if (op.operands.len > 0) op.operands[0].asName() else null) orelse return;
        const egs = self.doc().getDict(self.resources, "ExtGState") orelse return;
        const d = self.doc().getDict(egs, name) orelse return;
        const doc_ = self.doc();
        if (doc_.getNum(d, "LW")) |v| self.gs.line.width = @abs(v);
        if (doc_.getInt(d, "LC")) |v| self.gs.line.cap = switch (v) {
            1 => .round,
            2 => .square,
            else => .butt,
        };
        if (doc_.getInt(d, "LJ")) |v| self.gs.line.join = switch (v) {
            1 => .round,
            2 => .bevel,
            else => .miter,
        };
        if (doc_.getNum(d, "ML")) |v| self.gs.line.miter_limit = v;
        if (doc_.getNum(d, "CA")) |v| self.gs.stroke_alpha = std.math.clamp(v, 0, 1);
        if (doc_.getNum(d, "ca")) |v| self.gs.fill_alpha = std.math.clamp(v, 0, 1);
        if (doc_.get(d, "BM")) |bm| switch (bm) {
            .name => |n| self.gs.blend = try self.a.dupe(u8, n),
            .array => |arr| if (arr.len > 0) {
                if (doc_.resolve(arr[0]).asName()) |n| self.gs.blend = try self.a.dupe(u8, n);
            },
            else => {},
        };
        if (doc_.getArray(d, "D")) |da| if (da.len >= 2) if (doc_.resolve(da[0]).asArray()) |arr| {
            const dash = try self.a.alloc(f64, arr.len);
            var sum: f64 = 0;
            for (arr, 0..) |x, k| {
                dash[k] = @abs(doc_.resolve(x).asNum() orelse 0);
                sum += dash[k];
            }
            self.gs.line.dash = if (sum > 0) dash else &.{};
            self.gs.line.dash_phase = doc_.resolve(da[1]).asNum() orelse 0;
        };
        if (doc_.getArray(d, "Font")) |fa| if (fa.len >= 2) {
            if (try self.r.font(fa[0])) |f| {
                self.gs.font = f;
                self.gs.size = doc_.resolve(fa[1]).asNum() orelse self.gs.size;
            }
        };
    }

    // ---- colour ---------------------------------------------------------------------------

    fn setDevice(self: *Run, space: color.Space, op: content.Op, is_fill: bool) Error!void {
        const cs: *ColorState = if (is_fill) &self.gs.fill else &self.gs.stroke;
        cs.space = space;
        const n = space.components();
        cs.comps = @splat(0);
        for (0..n) |i| cs.comps[i] = num(op, i);
        cs.paint = .{ .color = space.toRgb(cs.comps[0..n]) };
    }

    fn setSpace(self: *Run, op: content.Op, is_fill: bool) Error!void {
        if (op.operands.len == 0) return;
        const cs: *ColorState = if (is_fill) &self.gs.fill else &self.gs.stroke;
        cs.space = try color.parse(self.doc(), op.operands[0], self.resources, 0);
        cs.comps = @splat(0);
        const n = cs.space.components();
        cs.space.initial(cs.comps[0..n]);
        cs.paint = if (cs.space == .pattern) .none else .{ .color = cs.space.toRgb(cs.comps[0..n]) };
    }

    fn setColor(self: *Run, op: content.Op, is_fill: bool) Error!void {
        const cs: *ColorState = if (is_fill) &self.gs.fill else &self.gs.stroke;
        if (cs.space == .pattern) {
            // The last operand is the pattern name; the others are the colour of an uncoloured pattern.
            const last = if (op.operands.len > 0) op.operands[op.operands.len - 1] else return;
            const pname = last.asName() orelse return;
            var rgb: ?color.Rgb = null;
            if (cs.space.pattern) |under| {
                var comps: [function.max_outputs]f64 = @splat(0);
                const n = @min(op.operands.len - 1, comps.len);
                for (0..n) |i| comps[i] = op.operands[i].asNum() orelse 0;
                rgb = under.toRgb(comps[0..n]);
            }
            cs.paint = try self.patternPaint(pname, rgb);
            return;
        }
        const n = cs.space.components();
        cs.comps = @splat(0);
        for (0..@min(n, op.operands.len)) |i| cs.comps[i] = op.operands[i].asNum() orelse 0;
        cs.paint = .{ .color = cs.space.toRgb(cs.comps[0..n]) };
    }

    // ---- patterns and shadings -------------------------------------------------------------

    fn patternPaint(self: *Run, name: []const u8, rgb: ?color.Rgb) Error!Paint {
        if (!self.r.options.graphics) return .none;
        const doc_ = self.doc();
        const pats = doc_.getDict(self.resources, "Pattern") orelse return .none;
        const po = doc_.get(pats, name) orelse return .none;
        const pd = po.asDict() orelse return .none;
        const ptype = doc_.getInt(pd, "PatternType") orelse return .none;
        const num_id: u32 = if (pats.get(name)) |r| (if (r == .ref) r.ref.num else 0) else 0;
        const m = self.matrixOf(pd, "Matrix").mul(self.base_ctm);
        if (ptype == 2) {
            const sh = doc_.get(pd, "Shading") orelse return .none;
            const shading = (try self.buildShading(sh)) orelse return .none;
            return .{ .shading = .{ .shading = shading, .matrix = m } };
        }
        if (ptype != 1 or po != .stream) return .none;
        if (self.depth >= self.r.options.max_depth) return .none;
        const key: u64 = (@as(u64, num_id) << 32) | (if (rgb) |c| (@as(u64, @intFromFloat(c.r * 255)) << 16 | @as(u64, @intFromFloat(c.g * 255)) << 8 | @as(u64, @intFromFloat(c.b * 255)) | (1 << 24)) else 0);
        const bbox = self.rectOf(pd, "BBox") orelse return .none;
        const xstep = doc_.getNum(pd, "XStep") orelse (bbox[2] - bbox[0]);
        const ystep = doc_.getNum(pd, "YStep") orelse (bbox[3] - bbox[1]);
        if (num_id != 0) if (self.tiling_cache.get(key)) |cell| {
            return .{ .tiling = .{ .cell = cell, .bbox = bbox, .xstep = xstep, .ystep = ystep, .matrix = m, .color = rgb } };
        };
        const cell = try self.a.create(display.DisplayList);
        cell.* = .{ .arena = std.heap.ArenaAllocator.init(self.a) };
        var sub: Run = .{ .r = self.r, .a = cell.arena.allocator(), .scratch = self.scratch, .depth = self.depth + 1 };
        sub.ops = self.ops;
        sub.content_bytes = self.content_bytes;
        sub.gs = .{};
        if (rgb) |c| {
            sub.gs.fill.paint = .{ .color = c };
            sub.gs.stroke.paint = .{ .color = c };
        }
        const res = doc_.getDict(pd, "Resources") orelse self.resources;
        const data = self.contentData(po.stream) catch "";
        try sub.interpret(data, res, .identity);
        self.ops = sub.ops;
        self.content_bytes = sub.content_bytes;
        cell.commands = sub.commands.items;
        cell.width = bbox[2] - bbox[0];
        cell.height = bbox[3] - bbox[1];
        if (num_id != 0) try self.tiling_cache.put(self.a, key, cell);
        return .{ .tiling = .{ .cell = cell, .bbox = bbox, .xstep = xstep, .ystep = ystep, .matrix = m, .color = rgb } };
    }

    fn matrixOf(self: *Run, d: Dict, key: []const u8) Matrix {
        const arr = self.doc().getArray(d, key) orelse return .identity;
        if (arr.len < 6) return .identity;
        var v: [6]f64 = undefined;
        for (0..6) |i| v[i] = self.doc().resolve(arr[i]).asNum() orelse 0;
        return Matrix.fromArray(&v);
    }

    fn rectOf(self: *Run, d: Dict, key: []const u8) ?[4]f64 {
        const arr = self.doc().getArray(d, key) orelse return null;
        if (arr.len < 4) return null;
        var v: [4]f64 = undefined;
        for (0..4) |i| v[i] = self.doc().resolve(arr[i]).asNum() orelse return null;
        return .{ @min(v[0], v[2]), @min(v[1], v[3]), @max(v[0], v[2]), @max(v[1], v[3]) };
    }

    /// Samples an axial or radial shading into colour stops (8.7.4.5.3, 8.7.4.5.4).
    fn buildShading(self: *Run, obj: Object) Error!?display.Shading {
        const doc_ = self.doc();
        const sd = obj.asDict() orelse return null;
        const st = doc_.getInt(sd, "ShadingType") orelse return null;
        if (st != 2 and st != 3) return null;
        const space = try color.parseOwned(doc_, sd.get("ColorSpace") orelse return null, self.resources, 0);
        const coords_arr = doc_.getArray(sd, "Coords") orelse return null;
        const need: usize = if (st == 2) 4 else 6;
        if (coords_arr.len < need) return null;
        var coords: [6]f64 = @splat(0);
        for (0..need) |i| coords[i] = doc_.resolve(coords_arr[i]).asNum() orelse 0;
        var t0: f64 = 0;
        var t1: f64 = 1;
        if (doc_.getArray(sd, "Domain")) |dm| if (dm.len >= 2) {
            t0 = doc_.resolve(dm[0]).asNum() orelse 0;
            t1 = doc_.resolve(dm[1]).asNum() orelse 1;
        };
        var ext = [2]bool{ false, false };
        if (doc_.getArray(sd, "Extend")) |ea| if (ea.len >= 2) for (0..2) |i| {
            ext[i] = if (doc_.resolve(ea[i]) == .boolean) doc_.resolve(ea[i]).boolean else false;
        };
        // One function with n outputs, or an array of n one-output functions.
        const fobj = doc_.get(sd, "Function");
        var funcs: std.ArrayList(function.Function) = .empty;
        if (fobj) |fo| switch (fo) {
            .array => |arr| for (arr) |item| {
                const fn_ = function.loadKept(doc_, item, true) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadFunction => continue,
                };
                try funcs.append(self.a, fn_);
            },
            else => if (function.loadKept(doc_, sd.get("Function").?, true)) |f1| try funcs.append(self.a, f1) else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadFunction => {},
            },
        };
        const n_stops = 64;
        const stops = try self.a.alloc(display.Stop, n_stops);
        for (0..n_stops) |i| {
            const t = t0 + (t1 - t0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_stops - 1));
            var comps: [function.max_outputs]f64 = @splat(0);
            var n: usize = 0;
            if (funcs.items.len == 1) {
                n = @min(funcs.items[0].nOutputs(), comps.len);
                funcs.items[0].eval(&.{t}, comps[0..n]);
            } else for (funcs.items) |f| {
                if (n >= comps.len) break;
                var one: [1]f64 = undefined;
                f.eval(&.{t}, &one);
                comps[n] = one[0];
                n += 1;
            }
            if (funcs.items.len == 0) {
                n = space.components();
                if (n > 0) comps[0] = t;
            }
            stops[i] = .{ .offset = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_stops - 1)), .color = space.toRgb(comps[0..n]) };
        }
        var bg: ?color.Rgb = null;
        if (doc_.getArray(sd, "Background")) |ba| {
            var comps: [function.max_outputs]f64 = @splat(0);
            for (ba, 0..) |x, i| if (i < comps.len) {
                comps[i] = doc_.resolve(x).asNum() orelse 0;
            };
            bg = space.toRgb(comps[0..@min(ba.len, comps.len)]);
        }
        return .{ .kind = if (st == 2) .axial else .radial, .coords = coords, .extend_start = ext[0], .extend_end = ext[1], .stops = stops, .background = bg, .bbox = self.rectOf(sd, "BBox") };
    }

    fn shadingOp(self: *Run, op: content.Op) Error!void {
        if (!self.r.options.graphics) return;
        const name = (if (op.operands.len > 0) op.operands[0].asName() else null) orelse return;
        const shs = self.doc().getDict(self.resources, "Shading") orelse return;
        const so = self.doc().get(shs, name) orelse return;
        const sh = (try self.buildShading(so)) orelse return;
        try self.emit(.{ .shading = .{ .shading = sh, .ctm = self.gs.ctm, .alpha = self.gs.fill_alpha } });
    }

    // ---- text -----------------------------------------------------------------------------

    fn moveText(self: *Run, tx: f64, ty: f64) void {
        self.tlm = Matrix.translate(tx, ty).mul(self.tlm);
        self.tm = self.tlm;
    }

    fn setFont(self: *Run, op: content.Op) Error!void {
        if (op.operands.len < 2) return;
        const name = op.operands[0].asName() orelse return;
        self.gs.size = op.operands[1].asNum() orelse 0;
        const fonts = self.doc().getDict(self.resources, "Font") orelse {
            self.gs.font = null;
            return;
        };
        const fo = fonts.get(name) orelse {
            self.gs.font = null;
            return;
        };
        self.gs.font = try self.r.font(fo);
    }

    fn showOperands(self: *Run, items: []const Object) Error!void {
        const f = self.gs.font orelse return;
        const size = self.gs.size;
        var glyphs: std.ArrayList(display.Glyph) = .empty;
        var tmp: std.ArrayList(font_mod.Font.Glyph) = .empty;
        var x: f64 = 0;
        for (items) |item| switch (item) {
            .string => |s| {
                tmp.clearRetainingCapacity();
                try f.glyphs(self.a, s, &tmp);
                if (tmp.items.len > self.r.options.max_glyphs -| self.r.produced.glyphs) return error.LimitExceeded;
                self.r.produced.glyphs += tmp.items.len;
                for (tmp.items) |g| {
                    try glyphs.append(self.a, .{ .code = g.code, .cid = g.cid, .x = x, .advance = g.advance, .text = g.text });
                    x += (g.advance * size + self.gs.tc + (if (g.is_space) self.gs.tw else 0)) * self.gs.th;
                }
            },
            .integer, .real => x -= (item.asNum() orelse 0) / 1000.0 * size * self.gs.th,
            else => {},
        };
        if (glyphs.items.len == 0) {
            // Numbers in a TJ array move the position even without strings.
            self.tm = Matrix.translate(x, 0).mul(self.tm);
            return;
        }
        const run_tm = self.tm;
        // A Type 3 font draws its glyphs as the paths of their procedures
        // (`type3Run`). The run is also emitted as invisible text (mode 3) so
        // that the characters can be extracted and searched.
        {
            try self.emit(.{ .text = .{
                .font = f,
                .size = size,
                .mode = if (f.subtype == .type3) 3 else self.gs.mode,
                .h_scale = self.gs.th,
                .rise = self.gs.rise,
                .tm = run_tm,
                .ctm = self.gs.ctm,
                .fill = self.gs.fill.paint,
                .stroke = self.gs.stroke.paint,
                .alpha = self.gs.fill_alpha,
                .stroke_alpha = self.gs.stroke_alpha,
                .glyphs = glyphs.items,
            } });
        }
        // Modes 3 and 7 neither fill nor stroke (table 106).
        if (f.subtype == .type3 and self.r.options.graphics and self.gs.mode != 3 and self.gs.mode != 7) try self.type3Run(f, glyphs.items, run_tm);
        self.tm = Matrix.translate(x, 0).mul(self.tm);
    }

    /// Type 3 glyphs are content streams run with the font matrix (9.6.5).
    fn type3Run(self: *Run, f: *const font_mod.Font, glyphs: []const display.Glyph, run_tm: Matrix) Error!void {
        if (self.depth >= self.r.options.max_depth) return;
        const doc_ = self.doc();
        for (glyphs) |g| {
            if (g.code >= 256) continue;
            const gname = f.names[g.code] orelse continue;
            const proc = doc_.get(f.char_procs, gname) orelse continue;
            if (proc != .stream) continue;
            const data = self.contentData(proc.stream) catch continue;
            // Glyph space to user space: FontMatrix, then size, scaling and rise, then Tm and CTM.
            const trm = Matrix{ .a = self.gs.size * self.gs.th, .d = self.gs.size, .f = self.gs.rise };
            // The glyph's offset is already in text space (9.4.4): it comes after
            // the size and scale, not before.
            const m = trm.mul(Matrix.translate(g.x, 0)).mul(run_tm);
            const glyph_ctm = Matrix.fromArray(&f.font_matrix).mul(m).mul(self.gs.ctm);
            try self.save();
            self.gs.ctm = glyph_ctm;
            const res = f.resources orelse self.resources;
            const saved_depth = self.depth;
            self.depth += 1;
            defer self.depth = saved_depth;
            // What q and Q do not cover: the glyph has its own path and text
            // position, and must leave the page's as they were.
            const saved = .{ .path = self.path, .clip = self.pending_clip, .tm = self.tm, .tlm = self.tlm, .cur = self.cur, .start = self.start };
            self.path = .empty;
            self.pending_clip = null;
            try self.interpret(data, res, glyph_ctm);
            self.path = saved.path;
            self.pending_clip = saved.clip;
            self.tm = saved.tm;
            self.tlm = saved.tlm;
            self.cur = saved.cur;
            self.start = saved.start;
            try self.restore();
        }
    }

    // ---- XObjects and images ------------------------------------------------------------------

    fn doXObject(self: *Run, op: content.Op) Error!void {
        const name = (if (op.operands.len > 0) op.operands[0].asName() else null) orelse return;
        const xo = self.doc().getDict(self.resources, "XObject") orelse return;
        const raw = xo.get(name) orelse return;
        const o = self.doc().resolve(raw);
        if (o != .stream) return;
        const st = o.stream;
        if (self.doc().get(st.dict, "OC")) |_| {
            if (st.dict.get("OC")) |oc| if (self.r.hidden(oc)) return;
        }
        const num_id: u32 = if (raw == .ref) raw.ref.num else 0;
        const sub = self.doc().getName(st.dict, "Subtype") orelse "";
        if (std.mem.eql(u8, sub, "Image")) {
            try self.imageOp(st, num_id, false);
        } else if (std.mem.eql(u8, sub, "Form")) {
            try self.formOp(st, num_id);
        }
    }

    fn imageOp(self: *Run, st: object.Stream, num_id: u32, inline_image: bool) Error!void {
        if (!self.r.options.graphics) return;
        const doc_ = self.doc();
        const w = doc_.getInt(st.dict, "Width") orelse doc_.getInt(st.dict, "W") orelse return;
        const h = doc_.getInt(st.dict, "Height") orelse doc_.getInt(st.dict, "H") orelse return;
        if (w <= 0 or h <= 0 or w > 1 << 20 or h > 1 << 20) return;
        const is_mask = if (doc_.get(st.dict, "ImageMask")) |m| (m == .boolean and m.boolean) else false;
        const space: color.Space = if (is_mask) .gray else if (st.dict.get("ColorSpace") orelse st.dict.get("CS")) |cs|
            // An inline image's dictionary is a copy made for this list.
            if (inline_image) try color.parse(doc_, cs, self.resources, 0) else try color.parseOwned(doc_, cs, self.resources, 0)
        else
            .gray;
        try self.emit(.{ .image = .{
            .stream = st,
            .width = @intCast(w),
            .height = @intCast(h),
            .is_mask = is_mask,
            .space = space,
            .fill = self.gs.fill.paint,
            .ctm = self.gs.ctm,
            .alpha = self.gs.fill_alpha,
            .blend = self.gs.blend,
            .num = num_id,
        } });
    }

    fn inlineImage(self: *Run, im: content.InlineImage) Error!void {
        if (!self.r.options.graphics) return;
        // The scanner's strings and the data live in scratch memory that is
        // reset when the page is done; the display list keeps its own copy.
        const dict = try object.dupeDict(self.a, im.dict);
        try self.imageOp(.{ .dict = dict, .data = try self.a.dupe(u8, im.data) }, 0, true);
    }

    fn formOp(self: *Run, st: object.Stream, num_id: u32) Error!void {
        if (self.depth >= self.r.options.max_depth) return;
        if (num_id != 0) {
            if (self.active_forms.contains(num_id)) return; // a form that draws itself
            try self.active_forms.put(self.a, num_id, {});
        }
        defer if (num_id != 0) {
            _ = self.active_forms.remove(num_id);
        };
        const doc_ = self.doc();
        const data = self.contentData(st) catch return;
        const res = doc_.getDict(st.dict, "Resources") orelse self.resources;
        const m = self.matrixOf(st.dict, "Matrix");
        try self.save();
        self.gs.ctm = m.mul(self.gs.ctm);
        if (if (self.r.options.graphics) self.rectOf(st.dict, "BBox") else null) |b| {
            const clip_path = try self.a.alloc(display.Seg, 5);
            clip_path[0] = .{ .move = .{ .x = b[0], .y = b[1] } };
            clip_path[1] = .{ .line = .{ .x = b[2], .y = b[1] } };
            clip_path[2] = .{ .line = .{ .x = b[2], .y = b[3] } };
            clip_path[3] = .{ .line = .{ .x = b[0], .y = b[3] } };
            clip_path[4] = .close;
            try self.emit(.{ .clip = .{ .path = clip_path, .rule = .nonzero, .ctm = self.gs.ctm } });
        }
        const saved_depth = self.depth;
        self.depth += 1;
        defer self.depth = saved_depth;
        const saved_path = self.path;
        const saved_clip = self.pending_clip;
        self.path = .empty;
        self.pending_clip = null;
        const saved_tm = self.tm;
        const saved_tlm = self.tlm;
        try self.interpret(data, res, self.gs.ctm);
        self.tm = saved_tm;
        self.tlm = saved_tlm;
        self.path = saved_path;
        self.pending_clip = saved_clip;
        try self.restore();
    }

    // ---- annotations ----------------------------------------------------------------------------

    /// Draws the normal appearance of each visible annotation (12.5.5).
    fn annotations(self: *Run, p: pages.Page) Error!void {
        const doc_ = self.doc();
        const annots = doc_.getArray(p.dict, "Annots") orelse return;
        for (annots) |item| {
            const ad = doc_.resolve(item).asDict() orelse continue;
            const flags = doc_.getInt(ad, "F") orelse 0;
            if (flags & (2 | 32) != 0) continue; // Hidden, NoView
            const sub = doc_.getName(ad, "Subtype") orelse "";
            if (std.mem.eql(u8, sub, "Popup")) continue;
            if (ad.get("OC")) |oc| if (self.r.hidden(oc)) continue;
            const ap = doc_.getDict(ad, "AP") orelse continue;
            var n = doc_.get(ap, "N") orelse continue;
            if (n == .dict) {
                const state = doc_.getName(ad, "AS") orelse continue;
                n = doc_.get(n.dict, state) orelse continue;
            }
            if (n != .stream) continue;
            const rect = self.rectOf(ad, "Rect") orelse continue;
            const bbox = self.rectOf(n.stream.dict, "BBox") orelse continue;
            const fm = self.matrixOf(n.stream.dict, "Matrix");
            // Transformed appearance box (the bounding box of the matrix applied to BBox).
            const pts = [4]Point{ fm.apply(bbox[0], bbox[1]), fm.apply(bbox[2], bbox[1]), fm.apply(bbox[2], bbox[3]), fm.apply(bbox[0], bbox[3]) };
            var tx0 = pts[0].x;
            var ty0 = pts[0].y;
            var tx1 = pts[0].x;
            var ty1 = pts[0].y;
            for (pts[1..]) |q| {
                tx0 = @min(tx0, q.x);
                ty0 = @min(ty0, q.y);
                tx1 = @max(tx1, q.x);
                ty1 = @max(ty1, q.y);
            }
            const sx = if (tx1 - tx0 == 0) 1 else (rect[2] - rect[0]) / (tx1 - tx0);
            const sy = if (ty1 - ty0 == 0) 1 else (rect[3] - rect[1]) / (ty1 - ty0);
            const a_m = Matrix{ .a = sx, .d = sy, .e = rect[0] - tx0 * sx, .f = rect[1] - ty0 * sy };
            const num_id: u32 = if (ap.get("N")) |nn| (if (nn == .ref) nn.ref.num else 0) else 0;
            self.gs = .{};
            self.gs.ctm = a_m;
            try self.formOp(n.stream, num_id);
        }
    }
};

// Tests live in interp_tests.zig.
