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
//! pages imported in the same call, URI and named actions, which layers are off
//! by default, the fields that have a widget on an imported page, and the
//! bookmarks that lead to one. Not carried: document information and metadata,
//! page labels, attachments of the document, structure, scripts and every other
//! action, and signatures.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const outline = @import("outline.zig");
const interp = @import("interp.zig");
const serial = @import("write.zig");
const compose_form = @import("compose_form.zig");
const compose_outline = @import("compose_outline.zig");
const pack = @import("compose_pack.zig");
const draw = @import("draw.zig");

const Object = object.Object;
const Dict = object.Dict;
const Entry = object.Entry;
const Document = document.Document;

pub const Options = struct {
    /// Largest file the builder makes. It also bounds what is held for it and
    /// the size of what is compressed in it before compression, so memory use
    /// stays in proportion. The default is what `Document.open` accepts.
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
    /// Document information that is not usable text or a PDF date.
    BadValue,
    /// A canvas whose path was neither painted nor used to clip.
    PathOpen,
    OutOfMemory,
    WriteFailed,
};

/// Object numbers of the catalog and the root of the page tree, written last.
const catalog_num = 1;
const tree_num = 2;
const first_free_num = 3;

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
    /// Every other object: streams and object streams.
    body: std.ArrayList(u8) = .empty,
    /// Where object `first_free_num + i` is: an offset is into `body`.
    offsets: std.ArrayList(pack.Location) = .empty,
    /// Objects waiting for an object stream. It is empty between calls.
    pending: pack.Pack = .{},
    /// The bytes that went into object streams, before compression.
    unpacked_bytes: usize = 0,
    page_list: std.ArrayList(PageRec) = .empty,
    layers: std.ArrayList(Layer) = .empty,
    /// A source was PDF 2.0.
    version2: bool = false,
    /// Names and bookmarks.
    arena: std.heap.ArenaAllocator,
    /// The form: its top level fields, their names, and the fonts that default
    /// appearances name (resource name to object number).
    field_roots: std.ArrayList(u32) = .empty,
    field_names: std.StringArrayHashMapUnmanaged(void) = .empty,
    form_fonts: std.StringArrayHashMapUnmanaged(u32) = .empty,
    need_appearances: bool = false,
    /// Objects for what canvases draw with, made once: the built-in fonts by
    /// their order, and images by their digest.
    drawn_fonts: std.EnumArray(draw.Builtin, u32) = .initFill(0),
    drawn_images: std.AutoArrayHashMapUnmanaged([32]u8, u32) = .empty,
    /// The document information dictionary, when `setInfo` gave one.
    info: ?Dict = null,
    bookmarks: std.ArrayList(compose_outline.Item) = .empty,
    /// What names and bookmarks take of `Options.max_bytes`.
    extra_bytes: usize = 0,

    pub fn init(gpa: Allocator, options: Options) Builder {
        return .{ .gpa = gpa, .options = options, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Builder) void {
        self.body.deinit(self.gpa);
        self.offsets.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.page_list.deinit(self.gpa);
        self.layers.deinit(self.gpa);
        self.page_bytes.deinit(self.gpa);
        self.field_roots.deinit(self.gpa);
        self.field_names.deinit(self.gpa);
        self.form_fonts.deinit(self.gpa);
        self.bookmarks.deinit(self.gpa);
        self.drawn_images.deinit(self.gpa);
        self.arena.deinit();
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
        try self.addPageRecord(try self.newNumber(), dict, 0);
    }

    fn addPageRecord(self: *Builder, num: u32, dict: Dict, rotate: u16) Error!void {
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
        return self.body.items.len +| self.pending.data.items.len +| self.page_bytes.items.len +| self.extra_bytes;
    }

    /// Counts `n` bytes held outside the serialized buffers.
    pub fn charge(self: *Builder, n: usize) Error!void {
        self.extra_bytes +|= n;
        if (self.size() > self.options.max_bytes) return error.TooLarge;
    }

    /// Appends a page with what `canvas` draws. The builder copies it, so the
    /// canvas can be changed or freed afterwards. Saved states still open are
    /// closed.
    pub fn addPage(self: *Builder, canvas: *const draw.Canvas) Error!void {
        if (canvas.path != .none) return error.PathOpen;
        const mark = self.snapshot();
        errdefer self.restore(mark);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var objects: Drawn = .{ .builder = self };
        const resources = try draw.resourcesOf(a, canvas, &objects);
        const contents = try self.newNumber();
        const squeezed = try draw.compressedContent(a, canvas);
        try self.emit(contents, .{ .stream = .{ .dict = try serial.makeDict(a, &.{.{ "Filter", .{ .name = "FlateDecode" } }}), .data = squeezed } });
        try self.flush();

        try self.addPageRecord(try self.newNumber(), try serial.makeDict(a, &.{
            .{ "Type", .{ .name = "Page" } },
            .{ "MediaBox", try serial.numbers(a, &.{ 0, 0, canvas.width, canvas.height }) },
            .{ "Resources", .{ .dict = resources } },
            .{ "Contents", .{ .ref = .{ .num = contents } } },
        }), 0);
    }

    pub const Info = struct {
        /// UTF-8; empty ones are left out.
        title: []const u8 = "",
        author: []const u8 = "",
        subject: []const u8 = "",
        keywords: []const u8 = "",
        creator: []const u8 = "",
        producer: []const u8 = "",
        /// Dates as PDF writes them (7.9.4), such as `D:20261127120000Z`.
        created: []const u8 = "",
        modified: []const u8 = "",
    };

    /// Sets the document information (14.3.3), in place of any set before.
    pub fn setInfo(self: *Builder, info: Info) Error!void {
        const mark = self.snapshot();
        errdefer self.restore(mark);
        const a = self.arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        for ([_]struct { []const u8, []const u8, bool }{
            .{ "Title", info.title, false },         .{ "Author", info.author, false },
            .{ "Subject", info.subject, false },     .{ "Keywords", info.keywords, false },
            .{ "Creator", info.creator, false },     .{ "Producer", info.producer, false },
            .{ "CreationDate", info.created, true }, .{ "ModDate", info.modified, true },
        }) |field| {
            const value = field[1];
            if (value.len == 0) continue;
            if (!std.unicode.utf8ValidateSlice(value)) return error.BadValue;
            if (field[2] and !isDate(value)) return error.BadValue;
            try self.charge(value.len *| 2);
            try entries.append(a, .{ .key = field[0], .value = .{ .string = try serial.textString(a, value) } });
        }
        self.info = if (entries.items.len > 0) .{ .entries = entries.items } else null;
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

    const Snapshot = struct { body: usize, page_bytes: usize, offsets: usize, pages: usize, layers: usize, version2: bool, field_roots: usize, field_names: usize, form_fonts: usize, need_appearances: bool, bookmarks: usize, extra_bytes: usize, unpacked_bytes: usize, drawn_fonts: std.EnumArray(draw.Builtin, u32), drawn_images: usize, info: ?Dict };

    fn snapshot(self: *const Builder) Snapshot {
        return .{ .body = self.body.items.len, .page_bytes = self.page_bytes.items.len, .offsets = self.offsets.items.len, .pages = self.page_list.items.len, .layers = self.layers.items.len, .version2 = self.version2, .field_roots = self.field_roots.items.len, .field_names = self.field_names.count(), .form_fonts = self.form_fonts.count(), .need_appearances = self.need_appearances, .bookmarks = self.bookmarks.items.len, .extra_bytes = self.extra_bytes, .unpacked_bytes = self.unpacked_bytes, .drawn_fonts = self.drawn_fonts, .drawn_images = self.drawn_images.count(), .info = self.info };
    }

    fn restore(self: *Builder, s: Snapshot) void {
        self.body.shrinkRetainingCapacity(s.body);
        self.page_bytes.shrinkRetainingCapacity(s.page_bytes);
        self.offsets.shrinkRetainingCapacity(s.offsets);
        self.page_list.shrinkRetainingCapacity(s.pages);
        self.layers.shrinkRetainingCapacity(s.layers);
        self.version2 = s.version2;
        self.field_roots.shrinkRetainingCapacity(s.field_roots);
        self.field_names.shrinkRetainingCapacity(s.field_names);
        self.form_fonts.shrinkRetainingCapacity(s.form_fonts);
        self.need_appearances = s.need_appearances;
        self.bookmarks.shrinkRetainingCapacity(s.bookmarks);
        self.extra_bytes = s.extra_bytes;
        self.unpacked_bytes = s.unpacked_bytes;
        self.drawn_fonts = s.drawn_fonts;
        self.drawn_images.shrinkRetainingCapacity(s.drawn_images);
        self.info = s.info;
        self.pending.clear();
    }

    pub fn newNumber(self: *Builder) Error!u32 {
        const num = first_free_num + self.offsets.items.len;
        // One more is left for the cross-reference table's free entry.
        if (num + 1 >= self.options.max_objects) return error.TooManyObjects;
        try self.offsets.append(self.gpa, .none);
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
        var form = try compose_form.Plan.read(&copy);
        var annots: std.ArrayList(Annot) = .empty;
        for (chosen, nums) |p, page_num| {
            for (doc.getArray(p.dict, "Annots") orelse &.{}) |item| {
                if (item != .ref) continue;
                const d = doc.resolve(item).asDict() orelse continue;
                if (isDocumentNode(doc, d)) continue;
                if (isWidget(doc, d)) form.keep(item.ref.num);
                const gop = try copy.map.getOrPut(copy.a, item.ref.num);
                if (gop.found_existing) continue;
                gop.value_ptr.* = try self.newNumber();
                try annots.append(copy.a, .{ .source = item.ref.num, .num = gop.value_ptr.*, .page = page_num });
            }
        }
        // And the fields above their widgets, which are numbered too.
        var groups: std.ArrayList(u32) = .empty;
        try form.number(&copy, &groups);
        try form.merge(&copy);

        var work: outline.Work = .{ .index_allocator = self.gpa };
        defer work.deinit();
        for (annots.items) |an| {
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            const d = doc.getObject(an.source).asDict() orelse Dict{};
            const copied = try copy.annotation(a, d, an.page, form.omitted(an.source), &work);
            try self.emit(an.num, .{ .dict = try form.finish(&copy, a, an.source, copied) });
        }
        for (groups.items) |source| {
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            const d = doc.getObject(source).asDict() orelse Dict{};
            // Actions on a field are scripts; `finish` gives it its kids.
            const scripts: []const []const u8 = &.{ "A", "AA" };
            const copied = try copy.dictionary(a, d, try std.mem.concat(a, []const u8, &.{ scripts, form.omitted(source) }));
            try self.emit(copy.map.get(source).?, .{ .dict = try form.finish(&copy, a, source, copied) });
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
                    const rewritten = try copy.annotation(a, d, page_num, &.{}, &work);
                    direct_bytes +|= rewritten.entries.len * @sizeOf(Entry);
                    if (direct_bytes > self.options.max_bytes) return error.TooLarge;
                    try items.append(a, .{ .dict = rewritten });
                }
            }
            try self.addPageRecord(page_num, try copy.page(a, p, list.entries[index].inh.resources, items.items), p.rotate);
        }

        // Everything referred to, and what that refers to, until nothing is left.
        var done: usize = 0;
        while (done < copy.queue.items.len) : (done += 1) {
            _ = scratch.reset(.retain_capacity);
            const next = copy.queue.items[done];
            try self.emit(next.num, try copy.indirect(scratch.allocator(), next.source));
        }

        try compose_outline.collect(&copy, &work);
        // Fonts of the form may have queued more.
        while (done < copy.queue.items.len) : (done += 1) {
            _ = scratch.reset(.retain_capacity);
            const next = copy.queue.items[done];
            try self.emit(next.num, try copy.indirect(scratch.allocator(), next.source));
        }
        try self.flush();
        try self.addLayers(&copy);
        if (isVersion2(doc)) self.version2 = true;
    }

    /// Serializes `o` as object `num`: a stream into `body` as it is, anything
    /// else into the object stream being filled.
    pub fn emit(self: *Builder, num: u32, o: Object) Error!void {
        const data_len = if (o == .stream) o.stream.data.len else 0;
        if (data_len > self.options.max_bytes -| self.size()) return error.TooLarge;
        if (o != .stream) {
            var value: Io.Writer.Allocating = .init(self.gpa);
            defer value.deinit();
            serial.writeObject(&value.writer, o) catch return error.OutOfMemory;
            if (value.written().len < pack.max_packed_object) {
                self.unpacked_bytes +|= value.written().len;
                try self.pending.add(self.gpa, num, value.written());
                if (@max(self.size(), self.unpacked_bytes) > self.options.max_bytes) return error.TooLarge;
                if (self.pending.isFull()) try self.flush();
                return;
            }
        }
        const at = self.body.items.len;
        {
            var out: Io.Writer.Allocating = .fromArrayList(self.gpa, &self.body);
            defer self.body = out.toArrayList();
            try putObject(&out.writer, num, o);
        }
        if (self.size() > self.options.max_bytes) return error.TooLarge;
        self.offsets.items[num - first_free_num] = .{ .at = at };
    }

    /// Puts the waiting objects into an object stream in `body`.
    fn flush(self: *Builder) Error!void {
        if (self.pending.nums.items.len == 0) return;
        const num = try self.newNumber();
        const at = self.body.items.len;
        {
            var out: Io.Writer.Allocating = .fromArrayList(self.gpa, &self.body);
            defer self.body = out.toArrayList();
            // `close` records locations by object number; this list starts at
            // the first free one.
            try self.pending.close(self.gpa, &out.writer, num, .{ .items = self.offsets.items, .first = first_free_num });
        }
        if (self.size() > self.options.max_bytes) return error.TooLarge;
        self.offsets.items[num - first_free_num] = .{ .at = at };
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

        // What follows the body: the pages, their tree, the outline and the
        // catalog in object streams, then the cross-reference stream.
        var tail: Tail = try .init(self, header.len + self.body.items.len);
        defer tail.deinit();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const kids = try a.alloc(Object, self.page_list.items.len);
        var page_value: std.ArrayList(u8) = .empty;
        defer page_value.deinit(self.gpa);
        for (self.page_list.items, kids) |rec, *kid| {
            kid.* = .{ .ref = .{ .num = rec.num } };
            // The stored dictionary, reopened before its closing `>>`.
            const dict = self.page_bytes.items[rec.start..][0..rec.len];
            page_value.clearRetainingCapacity();
            try page_value.print(self.gpa, "{s} /Parent {d} 0 R /Rotate {d} >>", .{ dict[0 .. dict.len - " >>".len], tree_num, rec.rotate });
            try tail.addValue(rec.num, page_value.items);
        }
        try tail.add(tree_num, .{ .dict = try serial.makeDict(a, &.{
            .{ "Type", .{ .name = "Pages" } },
            .{ "Kids", .{ .array = kids } },
            .{ "Count", .{ .integer = @intCast(kids.len) } },
        }) });
        var catalog = try serial.makeDict(a, &.{
            .{ "Type", .{ .name = "Catalog" } },
            .{ "Pages", .{ .ref = .{ .num = tree_num } } },
        });
        if (self.bookmarks.items.len > 0) {
            const root = try compose_outline.write(a, self.bookmarks.items, &tail);
            catalog = try serial.dictWith(a, catalog, "Outlines", .{ .ref = .{ .num = root } });
        }
        if (self.field_roots.items.len > 0) catalog = try serial.dictWith(a, catalog, "AcroForm", .{ .dict = try self.formDictionary(a) });
        if (self.layers.items.len > 0) catalog = try serial.dictWith(a, catalog, "OCProperties", .{ .dict = try self.layerProperties(a) });
        try tail.add(catalog_num, .{ .dict = catalog });
        var info_num: ?u32 = null;
        if (self.info) |info| {
            info_num = try tail.newNumber();
            try tail.add(info_num.?, .{ .dict = info });
        }
        try tail.finish(info_num);

        if (tail.base + tail.out.written().len > self.options.max_bytes) return error.TooLarge;
        w.writeAll(header) catch return error.WriteFailed;
        w.writeAll(self.body.items) catch return error.WriteFailed;
        w.writeAll(tail.out.written()) catch return error.WriteFailed;
    }

    /// The interactive form dictionary (table 218).
    fn formDictionary(self: *const Builder, a: Allocator) Allocator.Error!Dict {
        const roots = try a.alloc(Object, self.field_roots.items.len);
        for (self.field_roots.items, roots) |num, *r| r.* = .{ .ref = .{ .num = num } };
        var out = try serial.makeDict(a, &.{.{ "Fields", .{ .array = roots } }});
        if (self.form_fonts.count() > 0) {
            const fonts = try a.alloc(Entry, self.form_fonts.count());
            for (self.form_fonts.keys(), self.form_fonts.values(), fonts) |name, num, *e| e.* = .{ .key = name, .value = .{ .ref = .{ .num = num } } };
            const resources = try serial.makeDict(a, &.{.{ "Font", .{ .dict = .{ .entries = fonts } } }});
            out = try serial.dictWith(a, out, "DR", .{ .dict = resources });
        }
        if (self.need_appearances) out = try serial.dictWith(a, out, "NeedAppearances", .{ .boolean = true });
        return out;
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

/// The builder's objects for what a canvas draws with.
const Drawn = struct {
    builder: *Builder,

    pub fn fontObject(self: *Drawn, a: Allocator, font: draw.Builtin) Error!object.Ref {
        const builder = self.builder;
        if (builder.drawn_fonts.get(font) == 0) {
            const num = try builder.newNumber();
            try builder.emit(num, .{ .dict = try draw.fontDictionary(a, font) });
            builder.drawn_fonts.set(font, num);
        }
        return .{ .num = builder.drawn_fonts.get(font) };
    }

    /// An image XObject, with its alpha as a soft mask.
    pub fn imageObject(self: *Drawn, a: Allocator, picture: *const draw.Image) Error!object.Ref {
        const builder = self.builder;
        if (builder.drawn_images.get(picture.digest)) |num| return .{ .num = num };
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(a, (try draw.imageDictionary(a, picture, picture.components, picture.jpeg)).entries);
        if (picture.alpha) |alpha| {
            const mask = try builder.newNumber();
            try builder.emit(mask, .{ .stream = .{ .dict = try draw.imageDictionary(a, picture, 1, false), .data = alpha } });
            try entries.append(a, .{ .key = "SMask", .value = .{ .ref = .{ .num = mask } } });
        }
        const num = try builder.newNumber();
        try builder.emit(num, .{ .stream = .{ .dict = .{ .entries = entries.items }, .data = picture.data } });
        try builder.drawn_images.put(builder.gpa, picture.digest, num);
        return .{ .num = num };
    }
};

/// Whether `s` is a date as 7.9.4 writes them: `D:` and a year, then pairs of
/// digits as far as they go, and perhaps a time zone.
fn isDate(s: []const u8) bool {
    if (s.len < 6 or !std.mem.startsWith(u8, s, "D:")) return false;
    var i: usize = 2;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    const digits = i - 2;
    if (digits < 4 or digits > 14 or digits % 2 != 0) return false;
    if (i == s.len) return true;
    if (s[i] != 'Z' and s[i] != '+' and s[i] != '-') return false;
    for (s[i + 1 ..]) |c| if (!std.ascii.isDigit(c) and c != '\'') return false;
    return true;
}

/// The end of a file being written: what `write` adds after the body, without
/// changing the builder.
pub const Tail = struct {
    builder: *const Builder,
    /// The offset in the file where the tail starts.
    base: usize,
    out: Io.Writer.Allocating,
    pending: pack.Pack = .{},
    /// By object number; offsets are into the file.
    locations: std.ArrayList(pack.Location) = .empty,

    fn init(builder: *const Builder, base: usize) Error!Tail {
        const gpa = builder.gpa;
        var self: Tail = .{ .builder = builder, .base = base, .out = .init(gpa) };
        errdefer self.deinit();
        try self.locations.appendNTimes(gpa, .none, first_free_num);
        const header_len = base - builder.body.items.len;
        for (builder.offsets.items) |location| try self.locations.append(gpa, switch (location) {
            .at => |offset| .{ .at = header_len + offset },
            else => location,
        });
        return self;
    }

    fn deinit(self: *Tail) void {
        self.out.deinit();
        self.pending.deinit(self.builder.gpa);
        self.locations.deinit(self.builder.gpa);
    }

    /// A number for an object that the builder has none for.
    pub fn newNumber(self: *Tail) Error!u32 {
        const num = self.locations.items.len;
        if (num + 1 >= self.builder.options.max_objects) return error.TooManyObjects;
        try self.locations.append(self.builder.gpa, .none);
        return @intCast(num);
    }

    /// Adds `o`, which is not a stream, as object `num`.
    pub fn add(self: *Tail, num: u32, o: Object) Error!void {
        var value: Io.Writer.Allocating = .init(self.builder.gpa);
        defer value.deinit();
        serial.writeObject(&value.writer, o) catch return error.OutOfMemory;
        try self.addValue(num, value.written());
    }

    fn addValue(self: *Tail, num: u32, value: []const u8) Error!void {
        try self.pending.add(self.builder.gpa, num, value);
        if (self.pending.isFull()) try self.flush();
    }

    fn flush(self: *Tail) Error!void {
        if (self.pending.nums.items.len == 0) return;
        const num = try self.newNumber();
        self.locations.items[num] = .{ .at = self.base + self.out.written().len };
        try self.pending.close(self.builder.gpa, &self.out.writer, num, .{ .items = self.locations.items });
    }

    fn finish(self: *Tail, info: ?u32) Error!void {
        try self.flush();
        const own = try self.newNumber();
        const own_at = self.base + self.out.written().len;
        // Both file identifiers are a digest of the content (14.4).
        var hash = std.crypto.hash.Md5.init(.{});
        hash.update(self.builder.body.items);
        hash.update(self.out.written());
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        try pack.writeXref(self.builder.gpa, &self.out.writer, self.locations.items, own, own_at, .{ .root = catalog_num, .info = info }, digest);
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

/// In `Copy.map`: an object that is not copied, so references to it are null.
pub const excluded = 0;

/// Whether `d` is part of the source's document structure, which is never
/// copied: reaching a page this way would bring in a page that was left out.
pub fn isDocumentNode(doc: *Document, d: Dict) bool {
    const ty = doc.getName(d, "Type") orelse return false;
    for ([_][]const u8{ "Catalog", "Pages", "Page", "StructTreeRoot", "StructElem", "Outlines" }) |name| {
        if (std.mem.eql(u8, ty, name)) return true;
    }
    return false;
}

fn isWidget(doc: *Document, d: Dict) bool {
    return std.mem.eql(u8, doc.getName(d, "Subtype") orelse "", "Widget");
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
pub const Copy = struct {
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
    pub fn reference(self: *Copy, num: u32) Error!Object {
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
    pub fn value(self: *Copy, a: Allocator, v: Object) Error!Object {
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
    pub fn dictionary(self: *Copy, a: Allocator, d: Dict, without: []const []const u8) Error!Dict {
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
    fn annotation(self: *Copy, a: Allocator, d: Dict, page_num: u32, omit: []const []const u8, work: *outline.Work) Error!Dict {
        const doc = self.doc;
        const widget = isWidget(doc, d);
        // A widget's `/Parent` is its field, whose other widgets may be on
        // pages left out. `compose_form` gives it back for fields of the form.
        const without: []const []const u8 = if (widget)
            &.{ "A", "AA", "PA", "Dest", "P", "StructParent", "Parent" }
        else
            &.{ "A", "AA", "PA", "Dest", "P", "StructParent" };
        var out: std.ArrayList(Entry) = .empty;
        try out.appendSlice(a, (try self.dictionary(a, d, try std.mem.concat(a, []const u8, &.{ without, omit }))).entries);
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
    pub fn destination(self: *Copy, a: Allocator, dest: Object, work: *outline.Work) Error!?Object {
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
