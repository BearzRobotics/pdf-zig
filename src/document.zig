//! A PDF file: header, cross-reference data, trailer and indirect objects
//! (ISO 32000-1:2008, clause 7.5), with repair of damaged files.
//!
//! The whole file is held in memory (a PDF is read from the end and by offset).
//! Objects are parsed when first asked for and cached in the document's arena.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const filters = @import("filters.zig");
const Object = object.Object;
const Dict = object.Dict;
const Ref = object.Ref;
const Stream = object.Stream;

pub const Options = struct {
    /// Largest accepted file.
    max_bytes: usize = 1 << 30,
    /// Largest object number accepted from a cross-reference section.
    max_objects: u32 = 8_000_000,
    /// Largest stream after decoding.
    max_stream_bytes: usize = 512 << 20,
    /// Most `/Prev` sections followed.
    max_sections: usize = 4096,
};

pub const Error = error{
    /// No `%PDF-` header and nothing that looks like an object.
    NotPdf,
    /// The file has no usable catalog even after repair.
    NoCatalog,
    /// The file is encrypted; the standard security handler is not read yet.
    Encrypted,
    /// The input is longer than `Options.max_bytes`.
    InputTooLarge,
    ReadFailed,
    TooLarge,
    UnsupportedFilter,
    OutOfMemory,
};

pub const XrefEntry = union(enum) {
    free,
    /// Offset of `N G obj` from the start of the file (after `base`).
    in_use: struct { offset: u64, gen: u16 },
    /// Stored inside object stream `stream_num` at position `index`.
    compressed: struct { stream_num: u32, index: u32 },
};

const ObjStm = struct {
    data: []const u8,
    /// (object number, offset relative to First) per contained object.
    nums: []const u32,
    offsets: []const usize,
    first: usize,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    /// The file. Borrowed from the caller for `open`, owned for `openReader`.
    data: []const u8,
    options: Options,
    /// Offset of `%PDF-` in the file; cross-reference offsets are relative to it.
    base: usize = 0,
    xref: std.AutoHashMapUnmanaged(u32, XrefEntry) = .empty,
    trailer: Dict = .{},
    cache: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    objstms: std.AutoHashMapUnmanaged(u32, ?ObjStm) = .empty,
    repaired: bool = false,
    /// Guards against references that lead back to the object being read.
    reading: std.AutoHashMapUnmanaged(u32, void) = .empty,

    /// Opens a PDF held in `bytes`, which must outlive the document.
    pub fn open(gpa: Allocator, bytes: []const u8, options: Options) Error!Document {
        if (bytes.len > options.max_bytes) return error.InputTooLarge;
        var doc: Document = .{ .arena = std.heap.ArenaAllocator.init(gpa), .data = bytes, .options = options };
        errdefer doc.arena.deinit();
        try doc.load();
        return doc;
    }

    /// Reads all of `r` (up to `Options.max_bytes`) and opens it. The document
    /// owns the bytes.
    pub fn openReader(gpa: Allocator, r: *Io.Reader, options: Options) Error!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const bytes = r.allocRemaining(arena.allocator(), .limited(options.max_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.InputTooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
        var doc: Document = .{ .arena = arena, .data = bytes, .options = options };
        try doc.load();
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn a(self: *Document) Allocator {
        return self.arena.allocator();
    }

    // ---- loading -----------------------------------------------------------------

    fn load(self: *Document) Error!void {
        const head_len = @min(self.data.len, 1024);
        if (std.mem.indexOf(u8, self.data[0..head_len], "%PDF-")) |i| self.base = i;

        const ok = self.readXrefChain();
        if (!ok or !self.catalogReachable()) try self.rebuild();
        if (self.trailer.get("Encrypt") != null) return error.Encrypted;
        if (!self.catalogReachable()) return error.NoCatalog;
    }

    fn catalogReachable(self: *Document) bool {
        const root = self.trailer.get("Root") orelse return false;
        const cat = self.resolve(root).asDict() orelse return false;
        return cat.get("Pages") != null;
    }

    /// Follows `startxref` and the `/Prev` chain. Returns false if the chain is
    /// unusable, in which case the caller repairs the file.
    fn readXrefChain(self: *Document) bool {
        const start = self.findStartxref() orelse return false;
        var trailers: std.ArrayList(Dict) = .empty;
        var visited: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var offset: ?u64 = start;
        var sections: usize = 0;
        while (offset) |off| {
            if (visited.contains(off)) break;
            visited.put(self.a(), off, {}) catch return false;
            sections += 1;
            if (sections > self.options.max_sections) return false;
            const t = self.readXrefSection(off) orelse return false;
            trailers.append(self.a(), t) catch return false;
            // Hybrid-reference files: the stream's entries come before /Prev (7.5.8.4).
            if (t.get("XRefStm")) |xs| if (xs.asInt()) |xo| if (xo >= 0 and !visited.contains(@intCast(xo))) {
                visited.put(self.a(), @intCast(xo), {}) catch return false;
                _ = self.readXrefSection(@intCast(xo)) orelse return false;
            };
            offset = if (t.get("Prev")) |p| (if (p.asInt()) |pi| (if (pi >= 0) @as(?u64, @intCast(pi)) else null) else null) else null;
        }
        if (trailers.items.len == 0) return false;
        self.trailer = self.mergeTrailers(trailers.items) catch return false;
        return true;
    }

    /// The newest value of each trailer key that matters.
    fn mergeTrailers(self: *Document, trailers: []const Dict) Allocator.Error!Dict {
        var entries: std.ArrayList(object.Entry) = .empty;
        for (trailers) |t| {
            for (t.entries) |e| {
                if (std.mem.eql(u8, e.key, "Prev") or std.mem.eql(u8, e.key, "XRefStm")) continue;
                var seen = false;
                for (entries.items) |x| if (std.mem.eql(u8, x.key, e.key)) {
                    seen = true;
                };
                if (!seen) try entries.append(self.a(), e);
            }
        }
        return .{ .entries = entries.items };
    }

    fn findStartxref(self: *Document) ?u64 {
        const tail_start = self.data.len -| 2048;
        const idx = std.mem.lastIndexOf(u8, self.data[tail_start..], "startxref") orelse return null;
        var p = object.Parser.init(self.a(), self.data, tail_start + idx + "startxref".len);
        const o = p.parseObject() catch return null;
        const v = o.asInt() orelse return null;
        return if (v >= 0) @intCast(v) else null;
    }

    /// One cross-reference section (a table with its trailer, or a stream).
    /// Adds entries that are not already known (newer sections come first).
    fn readXrefSection(self: *Document, offset: u64) ?Dict {
        const pos = self.base + offset;
        if (pos >= self.data.len) return null;
        var p = object.Parser.init(self.a(), self.data, pos);
        p.skipWs();
        if (p.eatKeyword("xref")) return self.readXrefTable(&p);
        return self.readXrefStream(pos);
    }

    fn addEntry(self: *Document, num: u32, e: XrefEntry) void {
        if (num >= self.options.max_objects) return;
        const gop = self.xref.getOrPut(self.a(), num) catch return;
        if (!gop.found_existing) gop.value_ptr.* = e;
    }

    fn readXrefTable(self: *Document, p: *object.Parser) ?Dict {
        while (true) {
            const save = p.pos;
            const t1 = p.token() orelse return null;
            if (std.mem.eql(u8, t1, "trailer")) break;
            const start = std.fmt.parseInt(u32, t1, 10) catch {
                p.pos = save;
                return null;
            };
            const t2 = p.token() orelse return null;
            const count = std.fmt.parseInt(u32, t2, 10) catch return null;
            if (count > self.options.max_objects) return null;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const off_t = p.token() orelse return null;
                const gen_t = p.token() orelse return null;
                const kind = p.token() orelse return null;
                const off = std.fmt.parseInt(u64, off_t, 10) catch return null;
                const gen = std.fmt.parseInt(u32, gen_t, 10) catch return null;
                const num = start + i;
                if (kind.len == 1 and kind[0] == 'n') {
                    self.addEntry(num, .{ .in_use = .{ .offset = off, .gen = @intCast(@min(gen, 65535)) } });
                } else if (kind.len == 1 and kind[0] == 'f') {
                    self.addEntry(num, .free);
                } else return null;
            }
        }
        const o = p.parseObject() catch return null;
        return o.asDict();
    }

    fn readXrefStream(self: *Document, pos: usize) ?Dict {
        const obj = self.readIndirectAt(pos, null) orelse return null;
        const st = switch (obj.value) {
            .stream => |s| s,
            else => return null,
        };
        const ty = st.dict.get("Type") orelse return null;
        if (!std.mem.eql(u8, ty.asName() orelse "", "XRef")) return null;
        const w_arr = (st.dict.get("W") orelse return null).asArray() orelse return null;
        if (w_arr.len < 3) return null;
        var w: [3]usize = undefined;
        for (0..3) |i| {
            const v = w_arr[i].asInt() orelse return null;
            if (v < 0 or v > 8) return null;
            w[i] = @intCast(v);
        }
        const row = w[0] + w[1] + w[2];
        if (row == 0) return null;
        const data = self.streamData(st) catch return null;

        var index_pairs: std.ArrayList(u32) = .empty;
        if (st.dict.get("Index")) |ix| {
            const arr = ix.asArray() orelse return null;
            for (arr) |x| index_pairs.append(self.a(), @intCast(@max(0, x.asInt() orelse return null))) catch return null;
        } else {
            const size = (st.dict.get("Size") orelse return null).asInt() orelse return null;
            index_pairs.appendSlice(self.a(), &.{ 0, @intCast(@max(0, size)) }) catch return null;
        }

        var cursor: usize = 0;
        var k: usize = 0;
        while (k + 1 < index_pairs.items.len) : (k += 2) {
            const first = index_pairs.items[k];
            const count = index_pairs.items[k + 1];
            var j: u32 = 0;
            while (j < count) : (j += 1) {
                if (cursor + row > data.len) break;
                const f = readField(data[cursor .. cursor + w[0]]);
                const f2 = readField(data[cursor + w[0] .. cursor + w[0] + w[1]]);
                const f3 = readField(data[cursor + w[0] + w[1] .. cursor + row]);
                cursor += row;
                const kind: u64 = if (w[0] == 0) 1 else f;
                const num = first +| j;
                switch (kind) {
                    0 => self.addEntry(num, .free),
                    1 => self.addEntry(num, .{ .in_use = .{ .offset = f2, .gen = @intCast(@min(f3, 65535)) } }),
                    2 => self.addEntry(num, .{ .compressed = .{ .stream_num = @intCast(@min(f2, std.math.maxInt(u32))), .index = @intCast(@min(f3, std.math.maxInt(u32))) } }),
                    else => {},
                }
            }
        }
        return st.dict;
    }

    fn readField(bytes: []const u8) u64 {
        var v: u64 = 0;
        for (bytes) |b| v = (v << 8) | b;
        return v;
    }

    // ---- indirect objects ----------------------------------------------------------

    const Indirect = struct { num: u32, gen: u16, value: Object };

    /// Parses `N G obj ... endobj` at `pos`. If `expect` is given the object
    /// number must match. Returns null if there is no object there.
    fn readIndirectAt(self: *Document, pos: usize, expect: ?u32) ?Indirect {
        if (pos >= self.data.len) return null;
        var p = object.Parser.init(self.a(), self.data, pos);
        const t1 = p.token() orelse return null;
        const t2 = p.token() orelse return null;
        const t3 = p.token() orelse return null;
        if (!std.mem.eql(u8, t3, "obj")) return null;
        const num = std.fmt.parseInt(u32, t1, 10) catch return null;
        const gen = std.fmt.parseInt(u32, t2, 10) catch return null;
        if (expect) |e| if (e != num) return null;

        const value = p.parseObject() catch return null;
        if (value != .dict) return .{ .num = num, .gen = @intCast(@min(gen, 65535)), .value = value };

        const save = p.pos;
        if (!p.eatKeyword("stream")) {
            p.pos = save;
            return .{ .num = num, .gen = @intCast(@min(gen, 65535)), .value = value };
        }
        // The data starts after the end-of-line that follows `stream` (7.3.8.1).
        var start = p.pos;
        if (start < self.data.len and self.data[start] == '\r') start += 1;
        if (start < self.data.len and self.data[start] == '\n') start += 1;

        const dict = value.dict;
        const data = self.streamBytes(dict, start);
        return .{ .num = num, .gen = @intCast(@min(gen, 65535)), .value = .{ .stream = .{ .dict = dict, .data = data } } };
    }

    /// The raw bytes of a stream whose data begins at `start`. `/Length` is used
    /// when it is right (`endstream` follows); otherwise the data runs to the
    /// next `endstream`.
    fn streamBytes(self: *Document, dict: Dict, start: usize) []const u8 {
        if (start > self.data.len) return "";
        if (dict.get("Length")) |lv| {
            const len_obj = self.resolve(lv);
            if (len_obj.asInt()) |len| {
                if (len >= 0 and start + @as(usize, @intCast(len)) <= self.data.len) {
                    const end = start + @as(usize, @intCast(len));
                    var q = object.Parser.init(self.a(), self.data, end);
                    if (q.eatKeyword("endstream")) return self.data[start..end];
                }
            }
        }
        const idx = std.mem.indexOfPos(u8, self.data, start, "endstream") orelse return self.data[start..];
        var end = idx;
        if (end > start and self.data[end - 1] == '\n') end -= 1;
        if (end > start and self.data[end - 1] == '\r') end -= 1;
        return self.data[start..end];
    }

    /// The object `num`. A missing, free or unreadable object is `null`
    /// (7.3.9). The first unreadable object triggers one repair of the file.
    pub fn getObject(self: *Document, num: u32) Object {
        if (self.cache.get(num)) |o| return o;
        if (self.reading.contains(num)) return .null;
        self.reading.put(self.a(), num, {}) catch return .null;
        defer _ = self.reading.remove(num);

        var result: Object = .null;
        if (self.xref.get(num)) |entry| switch (entry) {
            .free => {},
            .in_use => |e| {
                if (self.readIndirectAt(self.base + @as(usize, @intCast(@min(e.offset, std.math.maxInt(usize) / 2))), num)) |ind| {
                    result = ind.value;
                } else if (!self.repaired) {
                    self.rebuild() catch {};
                    // Repair replaced the table: look again, once.
                    self.reading.clearRetainingCapacity();
                    return self.getObject(num);
                }
            },
            .compressed => |c| result = self.getCompressed(c.stream_num, c.index, num),
        };
        self.cache.put(self.a(), num, result) catch {};
        return result;
    }

    fn getCompressed(self: *Document, stream_num: u32, index: u32, num: u32) Object {
        const stm = self.objStm(stream_num) orelse return .null;
        var i: usize = index;
        if (i >= stm.nums.len or stm.nums[i] != num) {
            // The index can be wrong in damaged files: search by number.
            i = std.mem.indexOfScalar(u32, stm.nums, num) orelse return .null;
        }
        const at = stm.first + stm.offsets[i];
        if (at >= stm.data.len) return .null;
        var p = object.Parser.init(self.a(), stm.data, at);
        return p.parseObject() catch .null;
    }

    fn objStm(self: *Document, num: u32) ?ObjStm {
        if (self.objstms.get(num)) |cached| return cached;
        const loaded = self.loadObjStm(num);
        self.objstms.put(self.a(), num, loaded) catch {};
        return loaded;
    }

    fn loadObjStm(self: *Document, num: u32) ?ObjStm {
        const st = switch (self.getObject(num)) {
            .stream => |s| s,
            else => return null,
        };
        const n = (self.resolve(st.dict.get("N") orelse return null)).asInt() orelse return null;
        const first = (self.resolve(st.dict.get("First") orelse return null)).asInt() orelse return null;
        if (n < 0 or first < 0 or n > 1_000_000) return null;
        const data = self.streamData(st) catch return null;
        if (@as(usize, @intCast(first)) > data.len) return null;
        var p = object.Parser.init(self.a(), data, 0);
        const nums = self.a().alloc(u32, @intCast(n)) catch return null;
        const offs = self.a().alloc(usize, @intCast(n)) catch return null;
        var count: usize = 0;
        while (count < nums.len) : (count += 1) {
            const a1 = p.parseObject() catch break;
            const a2 = p.parseObject() catch break;
            const on = a1.asInt() orelse break;
            const oo = a2.asInt() orelse break;
            if (on < 0 or oo < 0) break;
            nums[count] = @intCast(@min(on, std.math.maxInt(u32)));
            offs[count] = @intCast(oo);
        }
        return .{ .data = data, .nums = nums[0..count], .offsets = offs[0..count], .first = @intCast(first) };
    }

    /// Follows references until a direct object (at most 32 hops).
    pub fn resolve(self: *Document, o: Object) Object {
        var cur = o;
        var hops: usize = 0;
        while (cur == .ref and hops < 32) : (hops += 1) cur = self.getObject(cur.ref.num);
        return if (cur == .ref) .null else cur;
    }

    /// `dict[key]`, resolved.
    pub fn get(self: *Document, dict: Dict, key: []const u8) ?Object {
        const v = dict.get(key) orelse return null;
        const r = self.resolve(v);
        return if (r == .null) null else r;
    }

    pub fn getInt(self: *Document, dict: Dict, key: []const u8) ?i64 {
        return (self.get(dict, key) orelse return null).asInt();
    }

    pub fn getNum(self: *Document, dict: Dict, key: []const u8) ?f64 {
        return (self.get(dict, key) orelse return null).asNum();
    }

    pub fn getName(self: *Document, dict: Dict, key: []const u8) ?[]const u8 {
        return (self.get(dict, key) orelse return null).asName();
    }

    pub fn getDict(self: *Document, dict: Dict, key: []const u8) ?Dict {
        return (self.get(dict, key) orelse return null).asDict();
    }

    pub fn getArray(self: *Document, dict: Dict, key: []const u8) ?[]const Object {
        return (self.get(dict, key) orelse return null).asArray();
    }

    /// The document catalog (the trailer's `/Root`).
    pub fn catalog(self: *Document) ?Dict {
        return self.getDict(self.trailer, "Root");
    }

    // ---- streams -------------------------------------------------------------------

    /// The `/Filter` chain of a stream with its decode parameters resolved.
    pub fn filterList(self: *Document, dict: Dict) Allocator.Error![]const filters.Filter {
        var list: std.ArrayList(filters.Filter) = .empty;
        const f = self.get(dict, "Filter") orelse self.get(dict, "F") orelse return list.items;
        const parms = self.get(dict, "DecodeParms") orelse self.get(dict, "DP");
        switch (f) {
            .name => |n| try list.append(self.a(), .{ .name = n, .parms = self.parmsAt(parms, 0) }),
            .array => |arr| for (arr, 0..) |item, i| {
                const name = self.resolve(item).asName() orelse continue;
                try list.append(self.a(), .{ .name = name, .parms = self.parmsAt(parms, i) });
            },
            else => {},
        }
        return list.items;
    }

    fn parmsAt(self: *Document, parms: ?Object, i: usize) Dict {
        const p = parms orelse return .{};
        return switch (p) {
            .dict => |d| if (i == 0) self.resolveDict(d) else .{},
            .array => |arr| if (i < arr.len) (self.resolve(arr[i]).asDict() orelse .{}) else .{},
            else => .{},
        };
    }

    /// A copy of `d` whose values are resolved (so filter code sees numbers, not references).
    fn resolveDict(self: *Document, d: Dict) Dict {
        const out = self.a().alloc(object.Entry, d.entries.len) catch return d;
        for (d.entries, 0..) |e, i| out[i] = .{ .key = e.key, .value = self.resolve(e.value) };
        return .{ .entries = out };
    }

    /// The stream's data with all filters applied, except image codecs: those
    /// are left in `rest`. Memory is owned by the document and lives until
    /// `deinit`; use `decodeStreamIn` for data that is needed only briefly.
    pub fn decodeStream(self: *Document, st: Stream) Error!filters.Result {
        return self.decodeStreamIn(self.a(), st);
    }

    /// Like `decodeStream`, but the decoded data (and intermediate buffers) are
    /// allocated from `a`, for example a scratch arena that is reset per page.
    pub fn decodeStreamIn(self: *Document, alloc: Allocator, st: Stream) Error!filters.Result {
        const list = try self.filterList(st.dict);
        return filters.decode(alloc, st.data, list, self.options.max_stream_bytes);
    }

    pub fn streamDataIn(self: *Document, alloc: Allocator, st: Stream) Error![]const u8 {
        const r = try self.decodeStreamIn(alloc, st);
        return r.data;
    }

    /// Decoded data of a stream that has no image codec in its filters.
    pub fn streamData(self: *Document, st: Stream) Error![]const u8 {
        const r = try self.decodeStream(st);
        return r.data;
    }

    // ---- repair --------------------------------------------------------------------

    /// Rebuilds the cross-reference table by scanning the file for `N G obj`
    /// and `trailer` (the usual recovery of viewers). Replaces the table.
    pub fn rebuild(self: *Document) Error!void {
        self.repaired = true;
        self.xref = .empty;
        self.cache = .empty;
        self.objstms = .empty;
        self.reading = .empty;
        var trailers: std.ArrayList(Dict) = .empty;

        var i: usize = 0;
        const d = self.data;
        while (std.mem.indexOfPos(u8, d, i, "obj")) |at| {
            i = at + 3;
            // `obj` must end the token and not be the tail of `endobj`.
            if (at + 3 < d.len and object.isRegular(d[at + 3])) continue;
            if (at == 0 or !object.isWhite(d[at - 1])) continue;
            var j = at - 1;
            while (j > 0 and object.isWhite(d[j - 1])) j -= 1;
            const gen_end = j;
            while (j > 0 and std.ascii.isDigit(d[j - 1])) j -= 1;
            if (j == gen_end) continue;
            const gen_start = j;
            if (j == 0 or !object.isWhite(d[j - 1])) continue;
            while (j > 0 and object.isWhite(d[j - 1])) j -= 1;
            const num_end = j;
            while (j > 0 and std.ascii.isDigit(d[j - 1])) j -= 1;
            if (j == num_end) continue;
            const num = std.fmt.parseInt(u32, d[j..num_end], 10) catch continue;
            const gen = std.fmt.parseInt(u32, d[gen_start..gen_end], 10) catch continue;
            if (num >= self.options.max_objects) continue;
            // Later definitions of an object replace earlier ones.
            self.xref.put(self.a(), num, .{ .in_use = .{ .offset = j - self.base, .gen = @intCast(@min(gen, 65535)) } }) catch return error.OutOfMemory;
        }

        // Trailer dictionaries: `trailer << ... >>` and the dictionaries of xref streams.
        i = 0;
        while (std.mem.indexOfPos(u8, d, i, "trailer")) |at| {
            i = at + 7;
            var p = object.Parser.init(self.a(), d, at + 7);
            const o = p.parseObject() catch continue;
            if (o.asDict()) |t| try trailers.append(self.a(), t);
        }
        var it = self.xref.iterator();
        var objstm_nums: std.ArrayList(u32) = .empty;
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (e != .in_use) continue;
            const ind = self.readIndirectAt(self.base + @as(usize, @intCast(e.in_use.offset)), kv.key_ptr.*) orelse continue;
            const dict = ind.value.asDict() orelse continue;
            const ty = dict.get("Type") orelse continue;
            const tname = ty.asName() orelse continue;
            if (std.mem.eql(u8, tname, "XRef") and dict.has("Root")) try trailers.append(self.a(), dict);
            if (std.mem.eql(u8, tname, "ObjStm")) try objstm_nums.append(self.a(), kv.key_ptr.*);
            if (std.mem.eql(u8, tname, "Catalog") and !hasRoot(trailers.items)) {
                const entries = try self.a().alloc(object.Entry, 1);
                entries[0] = .{ .key = "Root", .value = .{ .ref = .{ .num = kv.key_ptr.*, .gen = e.in_use.gen } } };
                try trailers.append(self.a(), .{ .entries = entries });
            }
        }
        // Objects inside object streams, where no direct definition exists.
        std.mem.sort(u32, objstm_nums.items, {}, std.sort.asc(u32));
        for (objstm_nums.items) |sn| {
            const stm = self.objStm(sn) orelse continue;
            for (stm.nums, 0..) |on, idx| {
                if (self.xref.contains(on) or on >= self.options.max_objects) continue;
                self.xref.put(self.a(), on, .{ .compressed = .{ .stream_num = sn, .index = @intCast(idx) } }) catch return error.OutOfMemory;
            }
        }

        // Prefer the last trailer that names a Root, then merge the rest under it.
        var ordered: std.ArrayList(Dict) = .empty;
        var k = trailers.items.len;
        while (k > 0) {
            k -= 1;
            try ordered.append(self.a(), trailers.items[k]);
        }
        self.trailer = try self.mergeTrailers(ordered.items);
        if (!self.catalogReachable()) {
            // The catalog may live in an object stream, found only now.
            var it2 = self.xref.iterator();
            while (it2.next()) |kv| {
                const o = self.getObject(kv.key_ptr.*);
                const dd = o.asDict() orelse continue;
                const tn = (dd.get("Type") orelse continue).asName() orelse continue;
                if (std.mem.eql(u8, tn, "Catalog") and dd.has("Pages")) {
                    const entries = try self.a().alloc(object.Entry, 1);
                    entries[0] = .{ .key = "Root", .value = .{ .ref = .{ .num = kv.key_ptr.* } } };
                    self.trailer = .{ .entries = entries };
                    break;
                }
            }
        }
        if (self.xref.count() == 0) return error.NotPdf;
    }

    fn hasRoot(ts: []const Dict) bool {
        for (ts) |t| if (t.has("Root")) return true;
        return false;
    }
};
