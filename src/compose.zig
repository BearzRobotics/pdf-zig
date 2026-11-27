// SPDX-License-Identifier: LGPL-2.0-or-later
//! Building a new document from blank pages and pages of other documents, and
//! writing it as a complete file (docs/decisions/0003-writing-new-documents.md).
//! This is how pages are created, deleted, reordered, merged and split. To
//! change a file by appending to it, see `write.zig`.
//!
//! Only what the imported pages refer to is copied. **This is not redaction:**
//! pages often share one resource dictionary, so an image or font used only by
//! a page that was left out can still be in the new file.
//!
//! Carried from a source: page contents and resources, annotations, links to
//! pages imported in the same call, URI and named actions, and which layers are
//! off by default. Not carried: bookmarks, the form (widgets keep their
//! appearance but are not fields), document information and metadata, page
//! labels, attachments of the document, structure, and every other action.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const outline = @import("outline.zig");
const interp = @import("interp.zig");
const serial = @import("write.zig");

const Object = object.Object;
const Dict = object.Dict;
const Entry = object.Entry;
const Document = document.Document;

pub const Options = struct {
    /// Largest file the builder makes. What it holds in memory is about this at
    /// most. The default is what `Document.open` accepts.
    max_bytes: usize = 1 << 30,
    /// Most objects in the file.
    max_objects: u32 = 8_000_000,
};

pub const ImportOptions = struct {
    /// Import from an encrypted document. The new file is **not** encrypted
    /// (pdf-zig cannot encrypt), so this removes the source's protection.
    allow_decrypted_output: bool = false,
};

pub const Error = error{
    /// The source is encrypted and `ImportOptions.allow_decrypted_output` is off.
    Encrypted,
    /// A page index that the document or the builder does not have.
    NoSuchPage,
    /// One call named the same page twice. Two calls can.
    DuplicatePage,
    /// A page size that is not usable, or a rotation that is not a multiple of 90.
    BadGeometry,
    /// A document without pages cannot be written.
    NoPages,
    /// The file would be larger than `Options.max_bytes`.
    TooLarge,
    /// More objects than `Options.max_objects`.
    TooManyObjects,
    /// A stream's encryption method is not one that is read.
    UnsupportedFilter,
    OutOfMemory,
    WriteFailed,
};

/// Object numbers of the catalog and the root of the page tree, written last.
const catalog_num = 1;
const tree_num = 2;
const first_free_num = 3;
/// Marks an object number whose object is not in `body` (a page).
const not_in_body = std.math.maxInt(usize);

const PageRec = struct {
    num: u32,
    /// The page dictionary in `page_bytes`, without `/Parent` and `/Rotate`:
    /// they are added when the file is written.
    start: usize,
    len: usize,
    rotate: u16,
};

const Layer = struct { num: u32, off: bool };

pub const Builder = struct {
    gpa: Allocator,
    options: Options,
    /// The page dictionaries, serialized.
    page_bytes: std.ArrayList(u8) = .empty,
    /// Every other object, serialized.
    body: std.ArrayList(u8) = .empty,
    /// Where object `first_free_num + i` starts in `body`.
    offsets: std.ArrayList(usize) = .empty,
    page_list: std.ArrayList(PageRec) = .empty,
    layers: std.ArrayList(Layer) = .empty,
    /// A source was PDF 2.0.
    version2: bool = false,

    pub fn init(gpa: Allocator, options: Options) Builder {
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(self: *Builder) void {
        self.body.deinit(self.gpa);
        self.offsets.deinit(self.gpa);
        self.page_list.deinit(self.gpa);
        self.layers.deinit(self.gpa);
        self.page_bytes.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn pageCount(self: *const Builder) usize {
        return self.page_list.items.len;
    }

    /// Appends an empty page of `width` by `height` points.
    pub fn addBlankPage(self: *Builder, width: f64, height: f64) Error!void {
        for ([_]f64{ width, height }) |v| if (!(v > 0 and v <= 1e7)) return error.BadGeometry;
        const mark = self.snapshot();
        errdefer self.restore(mark);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const dict = try serial.makeDict(a, &.{
            .{ "Type", .{ .name = "Page" } },
            .{ "MediaBox", try serial.numbers(a, &.{ 0, 0, width, height }) },
            .{ "Resources", .{ .dict = .{} } },
        });
        try self.addPage(try self.newNumber(), dict, 0);
    }

    fn addPage(self: *Builder, num: u32, dict: Dict, rotate: u16) Error!void {
        const start = self.page_bytes.items.len;
        {
            var out: Io.Writer.Allocating = .fromArrayList(self.gpa, &self.page_bytes);
            defer self.page_bytes = out.toArrayList();
            serial.writeObject(&out.writer, .{ .dict = dict }) catch return error.OutOfMemory;
        }
        if (self.size() > self.options.max_bytes) return error.TooLarge;
        try self.page_list.append(self.gpa, .{ .num = num, .start = start, .len = self.page_bytes.items.len - start, .rotate = rotate });
    }

    /// The bytes held for the new file so far.
    fn size(self: *const Builder) usize {
        return self.body.items.len + self.page_bytes.items.len;
    }

    /// Turns page `index` of the new document: the clockwise rotation it is
    /// displayed with, a multiple of 90 degrees (it replaces the page's own).
    pub fn setRotation(self: *Builder, index: usize, degrees: i32) Error!void {
        if (index >= self.page_list.items.len) return error.NoSuchPage;
        if (@rem(degrees, 90) != 0) return error.BadGeometry;
        self.page_list.items[index].rotate = @intCast(@mod(degrees, 360));
    }

    /// Appends the pages of `doc` at `indices` (0-based), in that order. Pass
    /// all pages wanted from a document in one call: objects they share, fonts
    /// for one, are then copied once, and links between them keep working.
    /// `doc` can be closed afterwards. A call that fails adds nothing.
    pub fn importPages(self: *Builder, doc: *Document, indices: []const usize, options: ImportOptions) Error!void {
        if (doc.crypt != null and !options.allow_decrypted_output) return error.Encrypted;
        while (true) {
            const mark = self.snapshot();
            errdefer self.restore(mark);
            const oom_before = doc.oom_events;
            const repaired_before = doc.repaired;
            try self.importOnce(doc, indices);
            // An object that could not be read for want of memory was copied as null.
            try doc.checkMemory(oom_before);
            if (doc.repaired == repaired_before) return;
            // A damaged entry was met and the file rebuilt, so what was read
            // before that may differ: copy it all again. This happens once.
            self.restore(mark);
        }
    }

    const Snapshot = struct { body: usize, page_bytes: usize, offsets: usize, pages: usize, layers: usize, version2: bool };

    fn snapshot(self: *const Builder) Snapshot {
        return .{ .body = self.body.items.len, .page_bytes = self.page_bytes.items.len, .offsets = self.offsets.items.len, .pages = self.page_list.items.len, .layers = self.layers.items.len, .version2 = self.version2 };
    }

    fn restore(self: *Builder, s: Snapshot) void {
        self.body.shrinkRetainingCapacity(s.body);
        self.page_bytes.shrinkRetainingCapacity(s.page_bytes);
        self.offsets.shrinkRetainingCapacity(s.offsets);
        self.page_list.shrinkRetainingCapacity(s.pages);
        self.layers.shrinkRetainingCapacity(s.layers);
        self.version2 = s.version2;
    }

    fn newNumber(self: *Builder) Error!u32 {
        const num = first_free_num + self.offsets.items.len;
        // One more is left for the cross-reference table's free entry.
        if (num + 1 >= self.options.max_objects) return error.TooManyObjects;
        try self.offsets.append(self.gpa, not_in_body);
        return @intCast(num);
    }

    fn importOnce(self: *Builder, doc: *Document, indices: []const usize) Error!void {
        var memory = std.heap.ArenaAllocator.init(self.gpa);
        defer memory.deinit();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        var copy: Copy = .{ .builder = self, .doc = doc, .a = memory.allocator() };

        const list = try pages.PageList.build(doc);
        for (list.entries) |e| if (e.num != 0) try copy.source_pages.put(copy.a, e.num, {});

        // Pages get their numbers first, so that links between them resolve.
        const chosen = try copy.a.alloc(pages.Page, indices.len);
        const nums = try copy.a.alloc(u32, indices.len);
        var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
        for (indices, 0..) |index, i| {
            chosen[i] = pages.page(doc, list, index) orelse return error.NoSuchPage;
            if ((try seen.getOrPut(copy.a, index)).found_existing) return error.DuplicatePage;
            nums[i] = try self.newNumber();
            if (chosen[i].num != 0) try copy.map.put(copy.a, chosen[i].num, nums[i]);
        }

        // Then the annotations that are objects: they are rewritten, wherever
        // they are referred to from.
        var annots: std.ArrayList(Annot) = .empty;
        for (chosen, nums) |p, page_num| {
            for (doc.getArray(p.dict, "Annots") orelse &.{}) |item| {
                if (item != .ref) continue;
                const d = doc.resolve(item).asDict() orelse continue;
                if (isDocumentNode(doc, d)) continue;
                const gop = try copy.map.getOrPut(copy.a, item.ref.num);
                if (gop.found_existing) continue;
                gop.value_ptr.* = try self.newNumber();
                try annots.append(copy.a, .{ .source = item.ref.num, .num = gop.value_ptr.*, .page = page_num });
            }
        }
        var work: outline.Work = .{ .lookups = outline.max_outline_lookup_nodes };
        for (annots.items) |an| {
            _ = scratch.reset(.retain_capacity);
            const d = doc.getObject(an.source).asDict() orelse Dict{};
            try self.emit(an.num, .{ .dict = try copy.annotation(scratch.allocator(), d, an.page, &work) });
        }

        // Each page is serialized as soon as it is made, so that many pages
        // naming the same large objects cannot hold more than the limit.
        for (chosen, indices, nums) |p, index, page_num| {
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            var items: std.ArrayList(Object) = .empty;
            var direct_bytes: usize = 0;
            for (doc.getArray(p.dict, "Annots") orelse &.{}) |item| {
                const d = doc.resolve(item).asDict() orelse continue;
                if (isDocumentNode(doc, d)) continue;
                if (item == .ref) {
                    const num = copy.map.get(item.ref.num) orelse continue;
                    if (num != excluded) try items.append(a, .{ .ref = .{ .num = num } });
                } else {
                    // A direct dictionary stays direct.
                    const rewritten = try copy.annotation(a, d, page_num, &work);
                    direct_bytes +|= rewritten.entries.len * @sizeOf(Entry);
                    if (direct_bytes > self.options.max_bytes) return error.TooLarge;
                    try items.append(a, .{ .dict = rewritten });
                }
            }
            try self.addPage(page_num, try copy.page(a, p, list.entries[index].inh.resources, items.items), p.rotate);
        }

        // Everything referred to, and what that refers to, until nothing is left.
        var done: usize = 0;
        while (done < copy.queue.items.len) : (done += 1) {
            _ = scratch.reset(.retain_capacity);
            const next = copy.queue.items[done];
            try self.emit(next.num, try copy.indirect(scratch.allocator(), next.source));
        }

        try self.addLayers(&copy);
        if (isVersion2(doc)) self.version2 = true;
    }

    /// Serializes `o` as object `num`.
    fn emit(self: *Builder, num: u32, o: Object) Error!void {
        const data_len = if (o == .stream) o.stream.data.len else 0;
        if (data_len > self.options.max_bytes -| self.size()) return error.TooLarge;
        var out: Io.Writer.Allocating = .fromArrayList(self.gpa, &self.body);
        defer self.body = out.toArrayList();
        const at = out.written().len;
        try putObject(&out.writer, num, o);
        if (out.written().len + self.page_bytes.items.len > self.options.max_bytes) return error.TooLarge;
        self.offsets.items[num - first_free_num] = at;
    }

    /// The source's layers that were copied, and whether each starts off.
    fn addLayers(self: *Builder, copy: *Copy) Error!void {
        const doc = copy.doc;
        const cat = doc.catalog() orelse return;
        const props = doc.getDict(cat, "OCProperties") orelse return;
        const all = doc.getArray(props, "OCGs") orelse return;
        var renderer = interp.Renderer.init(doc, .{});
        defer renderer.deinit();
        renderer.loadOcgs();
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (all) |g| {
            if (g != .ref) continue;
            const num = copy.map.get(g.ref.num) orelse continue;
            if (num == excluded or (try seen.getOrPut(copy.a, num)).found_existing) continue;
            try self.layers.append(self.gpa, .{ .num = num, .off = renderer.ocg_off.contains(g.ref.num) });
        }
    }

    /// Writes the new document. The builder is unchanged and can go on.
    pub fn write(self: *const Builder, w: *Io.Writer) Error!void {
        if (self.page_list.items.len == 0) return error.NoPages;
        // The comment's high bytes say that the file is binary (7.5.2).
        const header = if (self.version2) "%PDF-2.0\n%\xe2\xe3\xcf\xd3\n" else "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n";
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        // Where each object is in the file, by number.
        const count = first_free_num + self.offsets.items.len;
        const at = try a.alloc(usize, count);
        @memset(at, not_in_body);
        for (self.offsets.items, first_free_num..) |offset, num| {
            if (offset != not_in_body) at[num] = header.len + offset;
        }

        // What follows the body: the pages, their tree, the catalog and the
        // cross-reference data.
        var tail: Io.Writer.Allocating = .init(self.gpa);
        defer tail.deinit();
        const before_tail = header.len + self.body.items.len;
        const kids = try a.alloc(Object, self.page_list.items.len);
        for (self.page_list.items, kids) |rec, *kid| {
            kid.* = .{ .ref = .{ .num = rec.num } };
            at[rec.num] = before_tail + tail.written().len;
            // The stored dictionary, reopened before its closing `>>`.
            const dict = self.page_bytes.items[rec.start..][0..rec.len];
            tail.writer.print("{d} 0 obj\n{s} /Parent {d} 0 R /Rotate {d} >>\nendobj\n", .{ rec.num, dict[0 .. dict.len - " >>".len], tree_num, rec.rotate }) catch return error.OutOfMemory;
        }
        at[tree_num] = before_tail + tail.written().len;
        try putObject(&tail.writer, tree_num, .{ .dict = try serial.makeDict(a, &.{
            .{ "Type", .{ .name = "Pages" } },
            .{ "Kids", .{ .array = kids } },
            .{ "Count", .{ .integer = @intCast(kids.len) } },
        }) });
        var catalog = try serial.makeDict(a, &.{
            .{ "Type", .{ .name = "Catalog" } },
            .{ "Pages", .{ .ref = .{ .num = tree_num } } },
        });
        if (self.layers.items.len > 0) catalog = try serial.dictWith(a, catalog, "OCProperties", .{ .dict = try self.layerProperties(a) });
        at[catalog_num] = before_tail + tail.written().len;
        try putObject(&tail.writer, catalog_num, .{ .dict = catalog });

        const xref_at = before_tail + tail.written().len;
        const t = &tail.writer;
        t.print("xref\n0 {d}\n0000000000 65535 f \n", .{count}) catch return error.OutOfMemory;
        for (at[1..]) |offset| {
            std.debug.assert(offset != not_in_body);
            t.print("{d:0>10} 00000 n \n", .{offset}) catch return error.OutOfMemory;
        }
        // Both file identifiers are a digest of the content (14.4).
        var hash = std.crypto.hash.Md5.init(.{});
        hash.update(self.body.items);
        hash.update(tail.written());
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        const id: Object = .{ .string = &digest };
        t.writeAll("trailer\n") catch return error.OutOfMemory;
        serial.writeObject(t, .{ .dict = try serial.makeDict(a, &.{
            .{ "Size", .{ .integer = @intCast(count) } },
            .{ "Root", .{ .ref = .{ .num = catalog_num } } },
            .{ "ID", .{ .array = &.{ id, id } } },
        }) }) catch return error.OutOfMemory;
        t.print("\nstartxref\n{d}\n%%EOF\n", .{xref_at}) catch return error.OutOfMemory;

        if (before_tail + tail.written().len > self.options.max_bytes) return error.TooLarge;
        w.writeAll(header) catch return error.WriteFailed;
        w.writeAll(self.body.items) catch return error.WriteFailed;
        w.writeAll(tail.written()) catch return error.WriteFailed;
    }

    /// `/OCProperties` for the copied layers (8.11.4.2). `/Order` lets a viewer
    /// list them.
    fn layerProperties(self: *const Builder, a: Allocator) Allocator.Error!Dict {
        const all = try a.alloc(Object, self.layers.items.len);
        var off: std.ArrayList(Object) = .empty;
        for (self.layers.items, all) |layer, *entry| {
            entry.* = .{ .ref = .{ .num = layer.num } };
            if (layer.off) try off.append(a, entry.*);
        }
        const config = try serial.makeDict(a, &.{
            .{ "Order", .{ .array = all } },
            .{ "OFF", .{ .array = off.items } },
        });
        return serial.makeDict(a, &.{
            .{ "OCGs", .{ .array = all } },
            .{ "D", .{ .dict = config } },
        });
    }
};

const Annot = struct {
    /// The object number in the source, and in the new document.
    source: u32,
    num: u32,
    /// The new number of its page.
    page: u32,
};

/// Object `num` as it appears in the file. `w` grows in memory, so it only fails
/// for want of it.
fn putObject(w: *Io.Writer, num: u32, o: Object) error{OutOfMemory}!void {
    w.print("{d} 0 obj\n", .{num}) catch return error.OutOfMemory;
    serial.writeObject(w, o) catch return error.OutOfMemory;
    w.writeAll("\nendobj\n") catch return error.OutOfMemory;
}

/// Name-tree nodes each annotation adds to what looking up destinations may visit.
const lookups_per_annotation = 256;

/// In `Copy.map`: an object that is not copied, so references to it are null.
const excluded = 0;

/// Whether `d` is part of the source's document structure, which is never
/// copied: reaching a page this way would bring in a page that was left out.
fn isDocumentNode(doc: *Document, d: Dict) bool {
    const ty = doc.getName(d, "Type") orelse return false;
    for ([_][]const u8{ "Catalog", "Pages", "Page", "StructTreeRoot", "StructElem", "Outlines" }) |name| {
        if (std.mem.eql(u8, ty, name)) return true;
    }
    return false;
}

fn isOneOf(key: []const u8, keys: []const []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, key, k)) return true;
    return false;
}

fn isVersion2(doc: *Document) bool {
    const header = doc.data[@min(doc.base, doc.data.len)..];
    if (std.mem.startsWith(u8, header, "%PDF-2")) return true;
    const version = doc.getName(doc.catalog() orelse return false, "Version") orelse return false;
    return std.mem.startsWith(u8, version, "2");
}

/// One call's copying from one document.
const Copy = struct {
    builder: *Builder,
    doc: *Document,
    /// Lives as long as the call.
    a: Allocator,
    /// Source object number to new number, or `excluded`.
    map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    source_pages: std.AutoHashMapUnmanaged(u32, void) = .empty,
    queue: std.ArrayList(struct { source: u32, num: u32 }) = .empty,

    /// What a reference to source object `num` becomes. An object met for the
    /// first time is numbered and queued.
    fn reference(self: *Copy, num: u32) Error!Object {
        const gop = try self.map.getOrPut(self.a, num);
        if (!gop.found_existing) {
            gop.value_ptr.* = excluded;
            const target = self.doc.getObject(num);
            const left_out = target == .null or self.source_pages.contains(num) or
                (if (target.asDict()) |d| isDocumentNode(self.doc, d) else false);
            if (!left_out) {
                gop.value_ptr.* = try self.builder.newNumber();
                try self.queue.append(self.a, .{ .source = num, .num = gop.value_ptr.* });
            }
        }
        // `gop` is stale if anything above grew the map, so look again.
        const new = self.map.get(num).?;
        return if (new == excluded) .null else .{ .ref = .{ .num = new } };
    }

    /// A direct value with its references renumbered. Nesting is bounded by the
    /// parser; references are queued, not followed.
    fn value(self: *Copy, a: Allocator, v: Object) Error!Object {
        switch (v) {
            .ref => |r| return self.reference(r.num),
            .array => |arr| {
                const out = try a.alloc(Object, arr.len);
                for (arr, 0..) |item, i| out[i] = try self.value(a, item);
                return .{ .array = out };
            },
            .dict => |d| return .{ .dict = try self.dictionary(a, d, &.{}) },
            // A stream is always an object of its own.
            .stream => return .null,
            else => return v,
        }
    }

    /// `d` copied, without the keys in `without`.
    fn dictionary(self: *Copy, a: Allocator, d: Dict, without: []const []const u8) Error!Dict {
        var out: std.ArrayList(Entry) = .empty;
        for (d.entries) |e| {
            if (isOneOf(e.key, without)) continue;
            try out.append(a, .{ .key = e.key, .value = try self.value(a, e.value) });
        }
        return .{ .entries = out.items };
    }

    /// The new value of queued object `num`.
    fn indirect(self: *Copy, a: Allocator, num: u32) Error!Object {
        const source = self.doc.getObject(num);
        if (source != .stream) return self.value(a, source);
        return .{ .stream = try self.stream(a, source.stream) };
    }

    fn stream(self: *Copy, a: Allocator, st: object.Stream) Error!object.Stream {
        const doc = self.doc;
        // A crypt filter of their own for attachments (`/EFF`) is not read, so
        // their data cannot be decrypted correctly.
        if (st.encrypted and std.mem.eql(u8, doc.getName(st.dict, "Type") orelse "", "EmbeddedFile")) {
            if (doc.getName(doc.encrypt_dict, "EFF")) |eff| {
                if (!std.mem.eql(u8, eff, doc.getName(doc.encrypt_dict, "StmF") orelse "Identity")) return error.UnsupportedFilter;
            }
        }
        // `/Filter /Crypt` says how the source was encrypted, which the copy is not.
        const data = doc.storedStreamData(a, st) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.TooLarge,
            else => return error.UnsupportedFilter,
        };
        const dict = try withoutCrypt(a, doc, st.dict) orelse st.dict;
        // The writer gives the length. `/F` would make the data an external file.
        return .{ .dict = try self.dictionary(a, dict, &.{ "Length", "F", "FFilter", "FDecodeParms" }), .data = data };
    }

    /// An annotation of a page being imported. Links and actions are reduced to
    /// what the new document can honour.
    fn annotation(self: *Copy, a: Allocator, d: Dict, page_num: u32, work: *outline.Work) Error!Dict {
        const doc = self.doc;
        // The budget for looking names up grows with the number of annotations,
        // so that a long document does not run out of it partway.
        work.lookups +|= lookups_per_annotation;
        const widget = std.mem.eql(u8, doc.getName(d, "Subtype") orelse "", "Widget");
        // A widget's `/Parent` is its field, whose other widgets may be on
        // pages left out; there is no form in the new document yet.
        const without: []const []const u8 = if (widget)
            &.{ "A", "AA", "PA", "Dest", "P", "StructParent", "Parent" }
        else
            &.{ "A", "AA", "PA", "Dest", "P", "StructParent" };
        var out: std.ArrayList(Entry) = .empty;
        try out.appendSlice(a, (try self.dictionary(a, d, without)).entries);
        if (d.has("P")) try out.append(a, .{ .key = "P", .value = .{ .ref = .{ .num = page_num } } });

        if (d.get("Dest")) |dest| {
            if (try self.destination(a, dest, work)) |v| try out.append(a, .{ .key = "Dest", .value = v });
            return .{ .entries = out.items };
        }
        const action = doc.getDict(d, "A") orelse return .{ .entries = out.items };
        const kind = doc.getName(action, "S") orelse "";
        if (std.mem.eql(u8, kind, "GoTo")) {
            if (action.get("D")) |dest| if (try self.destination(a, dest, work)) |v| try out.append(a, .{ .key = "Dest", .value = v });
        } else if (std.mem.eql(u8, kind, "URI")) {
            const uri = doc.get(action, "URI") orelse return .{ .entries = out.items };
            if (uri != .string) return .{ .entries = out.items };
            var entries: std.ArrayList(Entry) = .empty;
            try entries.append(a, .{ .key = "S", .value = .{ .name = "URI" } });
            try entries.append(a, .{ .key = "URI", .value = uri });
            if (doc.get(action, "IsMap")) |v| if (v == .boolean) try entries.append(a, .{ .key = "IsMap", .value = v });
            try out.append(a, .{ .key = "A", .value = .{ .dict = .{ .entries = entries.items } } });
        } else if (std.mem.eql(u8, kind, "Named")) {
            const name = doc.getName(action, "N") orelse return .{ .entries = out.items };
            try out.append(a, .{ .key = "A", .value = .{ .dict = try serial.makeDict(a, &.{
                .{ "S", .{ .name = "Named" } },
                .{ "N", .{ .name = name } },
            }) } });
        }
        return .{ .entries = out.items };
    }

    /// A destination as an explicit array to a page imported in this call, or
    /// null. Names are looked up now: the name table is not copied.
    fn destination(self: *Copy, a: Allocator, dest: Object, work: *outline.Work) Error!?Object {
        const arr = outline.destinationArray(self.doc, dest, 0, work) orelse return null;
        // `[page /Kind numbers...]`, at most four numbers (table 151).
        if (arr.len == 0 or arr.len > 6 or arr[0] != .ref) return null;
        if (!self.source_pages.contains(arr[0].ref.num)) return null;
        const page_num = self.map.get(arr[0].ref.num) orelse return null;
        if (page_num == excluded) return null;
        const out = try a.alloc(Object, arr.len);
        out[0] = .{ .ref = .{ .num = page_num } };
        for (arr[1..], 1..) |item, i| {
            const v = self.doc.resolve(item);
            // Names are copied out by `dupe` or serialized before the source goes.
            out[i] = switch (v) {
                .integer, .real, .name => v,
                else => .null,
            };
        }
        return .{ .array = out };
    }

    /// The page dictionary: inherited attributes written out (7.7.3.4), and
    /// without what ties it to the source document. `/Parent` and `/Rotate` are
    /// added when the file is written.
    fn page(self: *Copy, a: Allocator, p: pages.Page, resources: ?Object, annots: []const Object) Error!Dict {
        var out: std.ArrayList(Entry) = .empty;
        try out.appendSlice(a, (try self.dictionary(a, p.dict, &.{
            "Type",      "Parent",    "Resources", "MediaBox", "CropBox",
            "Rotate",    "Annots",    "B",         "AA",       "StructParents",
            "PresSteps", "PieceInfo", "DPart",
        })).entries);
        try out.append(a, .{ .key = "Type", .value = .{ .name = "Page" } });
        try out.append(a, .{ .key = "MediaBox", .value = try rectArray(a, p.media_box) });
        if (!std.meta.eql(p.crop_box, p.media_box)) try out.append(a, .{ .key = "CropBox", .value = try rectArray(a, p.crop_box) });
        // Kept as a reference where it was one, so that pages go on sharing it.
        const res: Object = if (resources) |r| try self.value(a, r) else .null;
        try out.append(a, .{ .key = "Resources", .value = if (res == .null) .{ .dict = .{} } else res });
        if (annots.len > 0) try out.append(a, .{ .key = "Annots", .value = .{ .array = annots } });
        return .{ .entries = out.items };
    }
};

fn rectArray(a: Allocator, r: pages.Rect) Allocator.Error!Object {
    return serial.numbers(a, &.{ r.x0, r.y0, r.x1, r.y1 });
}

/// `dict` of a stream without a `/Crypt` filter and its parameters, or null
/// when it has none.
fn withoutCrypt(a: Allocator, doc: *Document, dict: Dict) Allocator.Error!?Dict {
    const filter = doc.resolve(dict.get("Filter") orelse return null);
    const names: []const Object = switch (filter) {
        .name => &.{filter},
        .array => |arr| arr,
        else => return null,
    };
    const parms = if (dict.get("DecodeParms")) |v| doc.resolve(v) else Object.null;
    var kept: std.ArrayList(Object) = .empty;
    var kept_parms: std.ArrayList(Object) = .empty;
    var found = false;
    var any_parms = false;
    for (names, 0..) |item, i| {
        if (std.mem.eql(u8, doc.resolve(item).asName() orelse "", "Crypt")) {
            found = true;
            continue;
        }
        const own: Object = switch (parms) {
            .array => |arr| if (i < arr.len) arr[i] else .null,
            .dict => if (i == 0) parms else .null,
            else => .null,
        };
        if (own != .null) any_parms = true;
        try kept.append(a, item);
        try kept_parms.append(a, own);
    }
    if (!found) return null;
    var out = try serial.dictWithout(a, try serial.dictWithout(a, dict, "Filter"), "DecodeParms");
    if (kept.items.len > 0) out = try serial.dictWith(a, out, "Filter", .{ .array = kept.items });
    if (any_parms) out = try serial.dictWith(a, out, "DecodeParms", .{ .array = kept_parms.items });
    return out;
}
