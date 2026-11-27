// SPDX-License-Identifier: LGPL-2.0-or-later
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
const crypt = @import("crypt.zig");
const color = @import("color.zig");
const function = @import("function.zig");
const font = @import("font.zig");
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
    /// Most decoded stream data (intermediate stages included) that is kept in
    /// the document itself, by `decodeStream` and what uses it: object streams,
    /// CMaps, functions and the like.
    max_retained_bytes: u64 = 2 << 30,
    /// Most `/Prev` sections followed.
    max_sections: usize = 4096,
    /// The user password of an encrypted file (the empty password opens most).
    password: []const u8 = "",
};

pub const Error = error{
    /// No `%PDF-` header and nothing that looks like an object.
    NotPdf,
    /// The file has no usable catalog even after repair.
    NoCatalog,
    /// The file is encrypted with a handler or version this library does not read.
    UnsupportedEncryption,
    /// The file is encrypted and `Options.password` does not open it.
    PasswordRequired,
    /// The input is longer than `Options.max_bytes`.
    InputTooLarge,
    ReadFailed,
    TooLarge,
    UnsupportedFilter,
    OutOfMemory,
};

/// Deepest chain of objects that need one another to be read. Real files need
/// two or three levels.
const max_load_depth = 32;

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
    /// Where the data of entry `i` must end: the next larger offset.
    ends: []const usize,
    /// The first entry with the same offset as entry `i`.
    same: []const u32,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    /// The file. Borrowed from the caller for `open`, owned for `openReader`.
    data: []const u8,
    options: Options,
    /// Offset of `%PDF-` in the file; cross-reference offsets are relative to it.
    /// Zero once the file has been repaired (the rebuilt offsets are absolute).
    base: usize = 0,
    xref: std.AutoHashMapUnmanaged(u32, XrefEntry) = .empty,
    trailer: Dict = .{},
    cache: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    objstms: std.AutoHashMapUnmanaged(u32, ?ObjStm) = .empty,
    /// Objects parsed from object streams, by stream and entry. Entries that
    /// share an offset share the object, so a stream's data is parsed once.
    objstm_objects: std.AutoHashMapUnmanaged(u64, Object) = .empty,
    /// Decoded bytes counted against `Options.max_retained_bytes`.
    retained_bytes: u64 = 0,
    repaired: bool = false,
    /// Set for an encrypted file once the key is derived.
    crypt: ?crypt.Crypt = null,
    /// The encryption dictionary, when `crypt` is set.
    encrypt_dict: Dict = .{},
    /// How many objects are being read inside one another. Reading an object can
    /// need others (a stream's `/Length`, the object stream it is stored in).
    depth: u8 = 0,
    /// Bytes read by object parses that then failed. A damaged construct can
    /// run to the end of the file, so thousands of candidates would cost the
    /// square of its length; see `parseWindow`.
    failed_bytes: usize = 0,
    /// The last search for `endstream`: nothing from `from` up to `at`.
    endstream_search: struct { from: usize = 1, at: usize = 0 } = .{},
    /// Things parsed from the document that are used again and again, kept so
    /// that using them does not grow the arena each time. See `cacheKey`.
    color_spaces: std.AutoHashMapUnmanaged(usize, color.Space) = .empty,
    functions: std.AutoHashMapUnmanaged(usize, function.Function) = .empty,
    fonts: std.AutoHashMapUnmanaged(usize, *const font.Font) = .empty,
    /// Decoded `/CIDToGIDMap` streams, by where their raw data is.
    gid_maps: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
    /// How often an allocation has failed. Reading goes through functions that
    /// answer with a value, where a failure looks like a missing object.
    /// Nothing produced while this changed is cached, and the operations that
    /// can fail report `error.OutOfMemory` if it did (`checkMemory`).
    oom_events: u64 = 0,
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
        var doc: Document = .{ .arena = std.heap.ArenaAllocator.init(gpa), .data = "", .options = options };
        // Frees through `doc.arena`, the arena that loading goes on to grow.
        errdefer doc.arena.deinit();
        doc.data = r.allocRemaining(doc.arena.allocator(), .limited(options.max_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.InputTooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
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

    /// Remembers an allocation failure that is about to be turned into a value.
    pub fn noteError(self: *Document, err: anyerror) void {
        if (err == error.OutOfMemory) self.oom_events += 1;
    }

    /// Fails if an allocation has failed since `oom_events` was `since`.
    pub fn checkMemory(self: *const Document, since: u64) Allocator.Error!void {
        if (self.oom_events != since) return error.OutOfMemory;
    }

    // ---- loading -----------------------------------------------------------------

    fn load(self: *Document) Error!void {
        // A failed allocation may surface as any error, or as none at all.
        self.loadParts() catch |err| {
            try self.checkMemory(0);
            return err;
        };
        try self.checkMemory(0);
    }

    fn loadParts(self: *Document) Error!void {
        const head_len = @min(self.data.len, 1024);
        if (std.mem.indexOf(u8, self.data[0..head_len], "%PDF-")) |i| self.base = i;

        const ok = self.readXrefChain();
        try self.checkMemory(0);
        // The key must be known before any other object is read and cached.
        if (ok) try self.setupEncryption();
        if (!ok or !self.catalogReachable()) try self.rebuild();
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
            visited.put(self.a(), off, {}) catch |err| {
                self.noteError(err);
                return false;
            };
            sections += 1;
            if (sections > self.options.max_sections) return false;
            var table_free: std.ArrayList(u32) = .empty;
            const t = self.readXrefSection(off, &table_free) orelse return false;
            trailers.append(self.a(), t) catch |err| {
                self.noteError(err);
                return false;
            };
            // Hybrid-reference files: the stream's entries come before /Prev (7.5.8.4).
            if (t.get("XRefStm")) |xs| if (xs.asInt()) |xo| if (xo >= 0 and !visited.contains(@intCast(xo))) {
                visited.put(self.a(), @intCast(xo), {}) catch |err| {
                    self.noteError(err);
                    return false;
                };
                _ = self.readXrefSection(@intCast(xo), &table_free) orelse return false;
            };
            // A hybrid file's table marks the objects hidden from old readers
            // as free; the stream above has already supplied those.
            for (table_free.items) |num| self.addEntry(num, .free);
            offset = if (t.get("Prev")) |p| (if (p.asInt()) |pi| (if (pi >= 0) @as(?u64, @intCast(pi)) else null) else null) else null;
        }
        if (trailers.items.len == 0) return false;
        self.trailer = self.mergeTrailers(trailers.items) catch |err| {
            self.noteError(err);
            return false;
        };
        return true;
    }

    /// The newest value of each trailer key that matters.
    fn mergeTrailers(self: *Document, trailers: []const Dict) Allocator.Error!Dict {
        var entries: std.ArrayList(object.Entry) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.arena.child_allocator);
        for (trailers) |t| {
            for (t.entries) |e| {
                if (std.mem.eql(u8, e.key, "Prev") or std.mem.eql(u8, e.key, "XRefStm")) continue;
                if (!(try seen.getOrPut(self.arena.child_allocator, e.key)).found_existing) try entries.append(self.a(), e);
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
    /// The free entries of a table are returned in `table_free` and not added.
    fn readXrefSection(self: *Document, offset: u64, table_free: *std.ArrayList(u32)) ?Dict {
        const pos = self.base + offset;
        if (pos >= self.data.len) return null;
        var p = object.Parser.init(self.a(), self.data, pos);
        p.skipWs();
        if (p.eatKeyword("xref")) return self.readXrefTable(&p, table_free);
        return self.readXrefStream(pos);
    }

    fn addEntry(self: *Document, num: u32, e: XrefEntry) void {
        if (num >= self.options.max_objects) return;
        const gop = self.xref.getOrPut(self.a(), num) catch |err| return self.noteError(err);
        if (!gop.found_existing) gop.value_ptr.* = e;
    }

    fn readXrefTable(self: *Document, p: *object.Parser, table_free: *std.ArrayList(u32)) ?Dict {
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
                const num = std.math.add(u32, start, i) catch return null;
                if (kind.len == 1 and kind[0] == 'n') {
                    self.addEntry(num, .{ .in_use = .{ .offset = off, .gen = @intCast(@min(gen, 65535)) } });
                } else if (kind.len == 1 and kind[0] == 'f') {
                    table_free.append(self.a(), num) catch |err| {
                        self.noteError(err);
                        return null;
                    };
                } else return null;
            }
        }
        const o = p.parseObject() catch |err| {
            self.noteError(err);
            return null;
        };
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
            for (arr) |x| index_pairs.append(self.a(), std.math.lossyCast(u32, x.asInt() orelse return null)) catch |err| {
                self.noteError(err);
                return null;
            };
        } else {
            const size = (st.dict.get("Size") orelse return null).asInt() orelse return null;
            index_pairs.appendSlice(self.a(), &.{ 0, std.math.lossyCast(u32, size) }) catch |err| {
                self.noteError(err);
                return null;
            };
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

        p.src = self.parseWindow(p.pos);
        const value = p.parseObject() catch |err| {
            self.noteError(err);
            self.failed_bytes +|= p.pos - pos;
            return null;
        };
        p.src = self.data;
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

    /// The part of the file an object starting at `pos` is parsed in. That is
    /// the whole file until failed parses have read several times its length.
    /// From then on it ends at the next `obj` or `trailer`, which cuts off only
    /// an object that has such a word inside a string.
    fn parseWindow(self: *const Document, pos: usize) []const u8 {
        if (self.failed_bytes <= 4 * self.data.len + 65536) return self.data;
        var end = pos;
        while (end < self.data.len) : (end += 1) {
            if (std.mem.startsWith(u8, self.data[end..], "obj")) return self.data[0 .. end + 3];
            if (std.mem.startsWith(u8, self.data[end..], "trailer")) break;
        }
        return self.data[0..end];
    }

    /// The position of the first `endstream` at or after `start`, or the length
    /// of the file. Remembered, so that many streams without one do not each
    /// search the rest of the file.
    fn findEndstream(self: *Document, start: usize) usize {
        const last = self.endstream_search;
        if (start >= last.from and start <= last.at) return last.at;
        const at = std.mem.indexOfPos(u8, self.data, start, "endstream") orelse self.data.len;
        self.endstream_search = .{ .from = start, .at = at };
        return at;
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
        const idx = self.findEndstream(start);
        if (idx == self.data.len) return self.data[start..];
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
        // Too deep: null for this chain only, so nothing is cached and the
        // object can still be read from nearer the top.
        if (self.depth >= max_load_depth) return .null;
        self.depth += 1;
        defer self.depth -= 1;
        const oom_before = self.oom_events;
        self.reading.put(self.a(), num, {}) catch |err| {
            self.noteError(err);
            return .null;
        };
        defer _ = self.reading.remove(num);

        var result: Object = .null;
        if (self.xref.get(num)) |entry| switch (entry) {
            .free => {},
            .in_use => |e| {
                if (self.readIndirectAt(self.base + @as(usize, @intCast(@min(e.offset, std.math.maxInt(usize) / 2))), num)) |ind| {
                    result = self.decryptObject(ind.value, num, ind.gen) catch |err| failed: {
                        self.noteError(err);
                        break :failed .null;
                    };
                } else if (self.oom_events != oom_before) {
                    // Not damage: reading failed for want of memory.
                    return .null;
                } else if (!self.repaired) {
                    self.rebuild() catch |err| {
                        self.noteError(err);
                        // Nothing changed after a lack of memory: try again later.
                        if (!self.repaired) return .null;
                    };
                    // Repair replaced the table: look again, once.
                    self.reading.clearRetainingCapacity();
                    return self.getObject(num);
                }
            },
            .compressed => |c| result = self.getCompressed(c.stream_num, c.index, num),
        };
        if (self.oom_events != oom_before) return .null;
        self.cache.put(self.a(), num, result) catch |err| self.noteError(err);
        return result;
    }

    fn getCompressed(self: *Document, stream_num: u32, index: u32, num: u32) Object {
        const stm = self.objStm(stream_num) orelse return .null;
        var i: usize = index;
        if (i >= stm.nums.len or stm.nums[i] != num) {
            // The index can be wrong in damaged files: search by number.
            i = std.mem.indexOfScalar(u32, stm.nums, num) orelse return .null;
        }
        const at = stm.first +| stm.offsets[i];
        if (at >= stm.data.len) return .null;
        const key = (@as(u64, stream_num) << 32) | stm.same[i];
        if (self.objstm_objects.get(key)) |o| return o;
        var p = object.Parser.init(self.a(), stm.data[0..@min(stm.data.len, stm.first +| stm.ends[i])], at);
        const o = p.parseObject() catch |err| failed: {
            self.noteError(err);
            if (err == error.OutOfMemory) return .null;
            break :failed .null;
        };
        self.objstm_objects.put(self.a(), key, o) catch |err| self.noteError(err);
        return o;
    }

    fn objStm(self: *Document, num: u32) ?ObjStm {
        if (self.objstms.get(num)) |cached| return cached;
        const oom_before = self.oom_events;
        const loaded = self.loadObjStm(num);
        if (self.oom_events != oom_before) return null;
        self.objstms.put(self.a(), num, loaded) catch |err| self.noteError(err);
        return loaded;
    }

    fn loadObjStm(self: *Document, num: u32) ?ObjStm {
        // An object stream is never stored in an object stream (7.5.7).
        const entry = self.xref.get(num) orelse return null;
        if (entry != .in_use) return null;
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
        // A number and an offset take at least three bytes.
        const most: usize = @min(@as(usize, @intCast(n)), data.len / 3 + 1);
        const nums = self.a().alloc(u32, most) catch |err| {
            self.noteError(err);
            return null;
        };
        const offs = self.a().alloc(usize, most) catch |err| {
            self.noteError(err);
            return null;
        };
        var count: usize = 0;
        while (count < nums.len) : (count += 1) {
            const a1 = p.parseObject() catch |err| {
                self.noteError(err);
                break;
            };
            const a2 = p.parseObject() catch |err| {
                self.noteError(err);
                break;
            };
            const on = a1.asInt() orelse break;
            const oo = a2.asInt() orelse break;
            if (on < 0 or oo < 0) break;
            nums[count] = @intCast(@min(on, std.math.maxInt(u32)));
            offs[count] = @intCast(oo);
        }
        const spans = self.objStmSpans(offs[0..count], data.len) catch |err| {
            self.noteError(err);
            return null;
        };
        return .{ .data = data, .nums = nums[0..count], .offsets = offs[0..count], .first = @intCast(first), .ends = spans.ends, .same = spans.same };
    }

    const Spans = struct { ends: []const usize, same: []const u32 };

    /// For each entry of an object stream, where its object ends and which
    /// entry stands for all those at the same offset.
    fn objStmSpans(self: *Document, offsets: []const usize, len: usize) Allocator.Error!Spans {
        const order = try self.a().alloc(u32, offsets.len);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sort(u32, order, offsets, struct {
            fn lt(offs: []const usize, x: u32, y: u32) bool {
                return if (offs[x] != offs[y]) offs[x] < offs[y] else x < y;
            }
        }.lt);
        const ends = try self.a().alloc(usize, offsets.len);
        const same = try self.a().alloc(u32, offsets.len);
        var start: usize = 0;
        while (start < order.len) {
            var next = start + 1;
            while (next < order.len and offsets[order[next]] == offsets[order[start]]) next += 1;
            const end = if (next < order.len) offsets[order[next]] else len;
            for (order[start..next]) |i| {
                ends[i] = end;
                same[i] = order[start];
            }
            start = next;
        }
        return .{ .ends = ends, .same = same };
    }

    /// The key under which something parsed from `o` may be cached, or null.
    /// A reference stands for its object. A direct array or dictionary is known
    /// by where it is, which only identifies it if it is part of the document
    /// (`owned`): memory the caller will reuse must pass false.
    pub fn cacheKey(o: Object, owned: bool) ?usize {
        return switch (o) {
            // Odd, so that it cannot be an address.
            .ref => |r| (@as(usize, r.num) << 1) | 1,
            .array => |items| if (owned and items.len > 0) @intFromPtr(items.ptr) else null,
            .dict => |d| if (owned and d.entries.len > 0) @intFromPtr(d.entries.ptr) else null,
            else => null,
        };
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

    // ---- encryption (7.6) ------------------------------------------------------------

    const Resolver = struct {
        doc: *Document,

        pub fn name(r: Resolver, d: Dict, key: []const u8) ?[]const u8 {
            return r.doc.getName(d, key);
        }
        pub fn int(r: Resolver, d: Dict, key: []const u8) ?i64 {
            return r.doc.getInt(d, key);
        }
        pub fn boolean(r: Resolver, d: Dict, key: []const u8) ?bool {
            const v = r.doc.get(d, key) orelse return null;
            return if (v == .boolean) v.boolean else null;
        }
        pub fn string(r: Resolver, d: Dict, key: []const u8) ?[]const u8 {
            const v = r.doc.get(d, key) orelse return null;
            return if (v == .string) v.string else null;
        }
        /// The method of the crypt filter named by `/StmF` or `/StrF` (7.6.5).
        pub fn cryptFilter(r: Resolver, d: Dict, key: []const u8) crypt.Method {
            const nm = r.doc.getName(d, key) orelse return .none;
            if (std.mem.eql(u8, nm, "Identity")) return .none;
            const cf = r.doc.getDict(d, "CF") orelse return .none;
            const f = r.doc.getDict(cf, nm) orelse return .none;
            const cfm = r.doc.getName(f, "CFM") orelse return .none;
            if (std.mem.eql(u8, cfm, "V2")) return .rc4;
            if (std.mem.eql(u8, cfm, "AESV2")) return .aes128;
            if (std.mem.eql(u8, cfm, "AESV3")) return .aes256;
            return .none;
        }
    };

    /// Derives the file key if the trailer names an encryption dictionary.
    fn setupEncryption(self: *Document) Error!void {
        if (self.crypt != null) return;
        const enc_ref = self.trailer.get("Encrypt") orelse return;
        const enc = self.resolve(enc_ref).asDict() orelse return error.UnsupportedEncryption;
        var id0: []const u8 = "";
        if (self.getArray(self.trailer, "ID")) |ids| if (ids.len > 0) {
            if (self.resolve(ids[0]) == .string) id0 = self.resolve(ids[0]).string;
        };
        var c = crypt.Crypt.init(enc, Resolver{ .doc = self }, id0, self.options.password) catch |err| switch (err) {
            error.UnsupportedEncryption => return error.UnsupportedEncryption,
            error.PasswordRequired => return error.PasswordRequired,
            error.OutOfMemory => return error.OutOfMemory,
        };
        c.encrypt_obj = if (enc_ref == .ref) enc_ref.ref.num else 0;
        self.crypt = c;
        // Objects read so far were not decrypted: forget them.
        self.encrypt_dict = enc;
        try self.forgetCached();
    }

    /// Empties the object caches. The encryption dictionary, which is never
    /// decrypted, goes back in.
    fn forgetCached(self: *Document) Allocator.Error!void {
        self.cache = .empty;
        self.objstms = .empty;
        self.objstm_objects = .empty;
        self.color_spaces = .empty;
        self.functions = .empty;
        self.fonts = .empty;
        if (self.crypt) |c| if (c.encrypt_obj != 0) try self.cache.put(self.a(), c.encrypt_obj, .{ .dict = self.encrypt_dict });
    }

    /// Decrypts the strings of `v` (and marks streams) for object `num gen`.
    fn decryptObject(self: *Document, v: Object, num: u32, gen: u16) Allocator.Error!Object {
        const c = self.crypt orelse return v;
        if (num == c.encrypt_obj) return v;
        switch (v) {
            .string => |s| return .{ .string = try c.decrypt(self.a(), c.string_method, num, gen, s) },
            .array => |arr| {
                const out = try self.a().alloc(Object, arr.len);
                for (arr, 0..) |item, i| out[i] = try self.decryptObject(item, num, gen);
                return .{ .array = out };
            },
            .dict => |d| return .{ .dict = try self.decryptDict(d, num, gen) },
            .stream => |st| {
                const d = try self.decryptDict(st.dict, num, gen);
                // Cross-reference streams are never encrypted; metadata may be exempt;
                // a stream with its own `/Crypt` filter of `/Identity` is left alone.
                const ty = if (st.dict.get("Type")) |t| (t.asName() orelse "") else "";
                var encrypted = !std.mem.eql(u8, ty, "XRef");
                if (std.mem.eql(u8, ty, "Metadata") and !c.encrypt_metadata) encrypted = false;
                if (hasIdentityCrypt(st.dict)) encrypted = false;
                return .{ .stream = .{ .dict = d, .data = st.data, .encrypted = encrypted, .num = num, .gen = gen } };
            },
            else => return v,
        }
    }

    fn decryptDict(self: *Document, d: Dict, num: u32, gen: u16) Allocator.Error!Dict {
        const out = try self.a().alloc(object.Entry, d.entries.len);
        for (d.entries, 0..) |e, i| out[i] = .{ .key = e.key, .value = try self.decryptObject(e.value, num, gen) };
        return .{ .entries = out };
    }

    fn hasIdentityCrypt(d: Dict) bool {
        const f = d.get("Filter") orelse return false;
        const names: []const Object = switch (f) {
            .name => &.{f},
            .array => |arr| arr,
            else => return false,
        };
        for (names) |n| if (std.mem.eql(u8, n.asName() orelse "", "Crypt")) {
            const parms = d.get("DecodeParms") orelse return true;
            const pd = if (parms.asArray()) |arr| (if (arr.len > 0) arr[0].asDict() else null) else parms.asDict();
            const nm = if (pd) |pdict| (if (pdict.get("Name")) |x| (x.asName() orelse "Identity") else "Identity") else "Identity";
            return std.mem.eql(u8, nm, "Identity");
        };
        return false;
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
            .array => |arr| if (i < arr.len) self.resolveDict(self.resolve(arr[i]).asDict() orelse .{}) else .{},
            else => .{},
        };
    }

    /// A copy of `d` whose values are resolved (so filter code sees numbers, not references).
    fn resolveDict(self: *Document, d: Dict) Dict {
        const out = self.a().alloc(object.Entry, d.entries.len) catch |err| {
            self.noteError(err);
            return d;
        };
        for (d.entries, 0..) |e, i| out[i] = .{ .key = e.key, .value = self.resolve(e.value) };
        return .{ .entries = out };
    }

    /// The stream's data with all filters applied, except image codecs: those
    /// are left in `rest`. Memory is owned by the document and lives until
    /// `deinit`; use `decodeStreamIn` for data that is needed only briefly.
    pub fn decodeStream(self: *Document, st: Stream) Error!filters.Result {
        if (self.retained_bytes > self.options.max_retained_bytes) return error.TooLarge;
        const r = try self.decodeStreamIn(self.a(), st);
        self.retained_bytes +|= r.work + (if (st.encrypted) st.data.len else 0);
        if (self.retained_bytes > self.options.max_retained_bytes) return error.TooLarge;
        return r;
    }

    /// Like `decodeStream`, but the decoded data (and intermediate buffers) are
    /// allocated from `a`, for example a scratch arena that is reset per page.
    pub fn decodeStreamIn(self: *Document, alloc: Allocator, st: Stream) Error!filters.Result {
        return self.decodeFiltered(alloc, st) catch |err| {
            self.noteError(err);
            return err;
        };
    }

    fn decodeFiltered(self: *Document, alloc: Allocator, st: Stream) Error!filters.Result {
        const oom_before = self.oom_events;
        const list = try self.filterList(st.dict);
        // A filter that could not be read must not look like no filter.
        try self.checkMemory(oom_before);
        var data = st.data;
        if (st.encrypted) if (self.crypt) |c| {
            data = try c.decrypt(alloc, c.stream_method, st.num, st.gen, data);
        };
        return filters.decode(alloc, data, list, self.options.max_stream_bytes);
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
        // If repair fails, the document stays as it was. After a lack of memory
        // it can be tried again; other failures would only repeat.
        const before = .{ .color_spaces = self.color_spaces, .functions = self.functions, .fonts = self.fonts, .xref = self.xref, .cache = self.cache, .objstms = self.objstms, .objstm_objects = self.objstm_objects, .trailer = self.trailer, .base = self.base, .repaired = self.repaired, .crypt = self.crypt, .encrypt_dict = self.encrypt_dict };
        const oom_before = self.oom_events;
        const outcome: Error!void = outcome: {
            self.rebuildTables() catch |err| break :outcome err;
            self.checkMemory(oom_before) catch |err| break :outcome err;
            if (self.xref.count() == 0) break :outcome error.NotPdf;
        };
        outcome catch |err| {
            self.noteError(err);
            self.color_spaces = before.color_spaces;
            self.functions = before.functions;
            self.fonts = before.fonts;
            self.xref = before.xref;
            self.cache = before.cache;
            self.objstms = before.objstms;
            self.objstm_objects = before.objstm_objects;
            self.trailer = before.trailer;
            self.base = before.base;
            self.repaired = before.repaired or self.oom_events == oom_before;
            self.crypt = before.crypt;
            self.encrypt_dict = before.encrypt_dict;
            self.reading = .empty;
            try self.checkMemory(oom_before);
            return err;
        };
    }

    fn rebuildTables(self: *Document) Error!void {
        self.repaired = true;
        // The scan records positions in the whole file, so that objects before
        // the `%PDF-` header are kept too.
        self.base = 0;
        self.xref = .empty;
        self.cache = .empty;
        self.objstms = .empty;
        self.reading = .empty;

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
            self.xref.put(self.a(), num, .{ .in_use = .{ .offset = j, .gen = @intCast(@min(gen, 65535)) } }) catch return error.OutOfMemory;
        }

        // Everything below that can occur more than once is ordered by where it
        // is in the file: what comes later is newer.
        var trailers: std.ArrayList(Found(Dict)) = .empty;
        var catalogs: std.ArrayList(Found(Ref)) = .empty;
        var objstm_nums: std.ArrayList(Found(u32)) = .empty;
        var encrypt_guess: ?Ref = null;

        // `trailer << ... >>`
        i = 0;
        while (std.mem.indexOfPos(u8, d, i, "trailer")) |at| {
            i = at + 7;
            var p = object.Parser.init(self.a(), self.parseWindow(at + 7), at + 7);
            const o = p.parseObject() catch {
                self.failed_bytes +|= p.pos - at;
                continue;
            };
            if (o.asDict()) |t| try trailers.append(self.a(), .{ .at = at, .value = t });
        }
        var it = self.xref.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (e != .in_use) continue;
            const at: usize = @intCast(e.in_use.offset);
            const ind = self.readIndirectAt(at, kv.key_ptr.*) orelse continue;
            const dict = ind.value.asDict() orelse continue;
            const ref: Ref = .{ .num = kv.key_ptr.*, .gen = e.in_use.gen };
            if (isEncryptDict(dict)) encrypt_guess = ref;
            const ty = dict.get("Type") orelse continue;
            const tname = ty.asName() orelse continue;
            if (std.mem.eql(u8, tname, "XRef") and dict.has("Root")) try trailers.append(self.a(), .{ .at = at, .value = try self.trailerKeys(dict) });
            if (std.mem.eql(u8, tname, "ObjStm")) try objstm_nums.append(self.a(), .{ .at = at, .value = ref.num });
            if (std.mem.eql(u8, tname, "Catalog")) try catalogs.append(self.a(), .{ .at = at, .value = ref });
        }
        Found(Dict).sort(trailers.items);
        Found(Ref).sort(catalogs.items);
        Found(u32).sort(objstm_nums.items);

        // The newest value of each trailer key.
        var newest_first: std.ArrayList(Dict) = .empty;
        var k = trailers.items.len;
        while (k > 0) {
            k -= 1;
            try newest_first.append(self.a(), trailers.items[k].value);
        }
        self.trailer = try self.mergeTrailers(newest_first.items);
        if (!self.trailer.has("Root") and catalogs.items.len > 0) {
            try self.setTrailerKey("Root", catalogs.items[catalogs.items.len - 1].value);
        }
        // An encrypted file whose trailer is lost must not be read as plain text.
        if (!self.trailer.has("Encrypt")) if (encrypt_guess) |ref| try self.setTrailerKey("Encrypt", ref);
        // The trailer is known: derive the key before reading object streams.
        try self.setupEncryption();

        // Objects inside object streams. A stream later in the file than a
        // direct definition, or than another stream, replaces it.
        var stored_at: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        for (objstm_nums.items) |found| {
            const stm = self.objStm(found.value) orelse continue;
            for (stm.nums, 0..) |on, idx| {
                if (on == found.value or on >= self.options.max_objects) continue;
                if (self.xref.get(on)) |old| switch (old) {
                    .in_use => |e| if (e.offset > found.at) continue,
                    .compressed => if ((stored_at.get(on) orelse 0) > found.at) continue,
                    .free => {},
                };
                self.xref.put(self.a(), on, .{ .compressed = .{ .stream_num = found.value, .index = @intCast(idx) } }) catch return error.OutOfMemory;
                try stored_at.put(self.a(), on, found.at);
            }
        }
        // Anything read while the table was incomplete (an indirect /Length held
        // in an object stream) may have been cached as missing.
        try self.forgetCached();

        if (!self.catalogReachable()) {
            // The trailer's /Root leads nowhere: take the newest catalog found,
            // else look inside object streams. The other trailer keys stay.
            var guess: ?Ref = if (catalogs.items.len > 0) catalogs.items[catalogs.items.len - 1].value else null;
            if (guess == null) {
                var best: u32 = 0;
                var keys = self.xref.iterator();
                var nums: std.ArrayList(u32) = .empty;
                while (keys.next()) |kv| if (kv.value_ptr.* == .compressed) try nums.append(self.a(), kv.key_ptr.*);
                for (nums.items) |n| {
                    const dd = self.getObject(n).asDict() orelse continue;
                    const tn = (dd.get("Type") orelse continue).asName() orelse continue;
                    if (std.mem.eql(u8, tn, "Catalog") and dd.has("Pages") and n >= best) {
                        best = n;
                        guess = .{ .num = n };
                    }
                }
            }
            if (guess) |ref| try self.setTrailerKey("Root", ref);
        }
    }

    /// Something found by the repair scan, and its position in the file.
    fn Found(comptime T: type) type {
        return struct {
            at: usize,
            value: T,

            const Self = @This();

            fn before(_: void, x: Self, y: Self) bool {
                return x.at < y.at;
            }

            fn sort(items: []Self) void {
                std.mem.sort(Self, items, {}, before);
            }
        };
    }

    /// The trailer entries of a cross-reference stream's dictionary.
    fn trailerKeys(self: *Document, d: Dict) Allocator.Error!Dict {
        var out: std.ArrayList(object.Entry) = .empty;
        for (d.entries) |e| for ([_][]const u8{ "Root", "Info", "ID", "Encrypt" }) |key| {
            if (std.mem.eql(u8, e.key, key)) try out.append(self.a(), e);
        };
        return .{ .entries = out.items };
    }

    /// Adds or replaces a trailer entry with a reference.
    fn setTrailerKey(self: *Document, key: []const u8, ref: Ref) Allocator.Error!void {
        var out: std.ArrayList(object.Entry) = .empty;
        for (self.trailer.entries) |e| if (!std.mem.eql(u8, e.key, key)) try out.append(self.a(), e);
        try out.append(self.a(), .{ .key = key, .value = .{ .ref = ref } });
        self.trailer = .{ .entries = out.items };
    }

    /// Whether `d` looks like the standard handler's encryption dictionary.
    fn isEncryptDict(d: Dict) bool {
        const filter = (d.get("Filter") orelse return false).asName() orelse return false;
        return std.mem.eql(u8, filter, "Standard") and d.has("O") and d.has("U") and d.has("V");
    }
};
