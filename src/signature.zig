// SPDX-License-Identifier: LGPL-2.0-or-later
//! The signatures of a document: what each claims, which bytes it covers and
//! what changed afterwards (ISO 32000-1 12.8; decision 0006, step S1).
//!
//! **Nothing here is verified.** No digest or certificate is checked, so a
//! signature listed here may be forged, and sound coverage means only that the
//! signature is placed so that checking it would say something about a known
//! part of the file.
//!
//! The coverage rules follow the verification algorithm of Mladenov, Mainka,
//! Meyer zu Selhausen, Grothe and Schwenk, "1 Trillion Dollar Refund: How To
//! Spoof PDF Signatures" (CCS 2019), against forged signature objects,
//! incremental saving and signature wrapping, and add the position of
//! `/Contents` and a reading of the signed revision on its own. Whether changes
//! after signing are permitted is deliberately not judged: attacks on certified
//! documents (Rohlmann et al., IEEE S&P 2021) use changes that the permission
//! level allows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const document = @import("document.zig");
const pages = @import("pages.zig");
const form = @import("form.zig");
const write = @import("write.zig");

const Document = document.Document;
const Object = object.Object;
const Dict = object.Dict;
const Ref = object.Ref;

pub const Kind = enum {
    /// A signature in a signature field.
    approval,
    /// The author's signature, which says which later changes it allows.
    certification,
    /// Rights granted to a reader, named by the permissions dictionary (12.8.4).
    usage_rights,
    /// A time stamp over the document, not a person's signature.
    timestamp,
};

/// The changes a certification says it allows (table 254).
pub const Allowed = enum {
    nothing,
    forms_and_signing,
    forms_signing_and_annotations,
};

/// Fields a signature says may not change any more (table 256).
pub const Lock = struct {
    action: enum { all, include, exclude },
    /// Field names, UTF-8.
    fields: []const []const u8,
    /// False if names were left out (`max_listed_bytes`, `max_lock_fields`), so
    /// that a name missing from `fields` says nothing.
    complete: bool = true,
};

/// What the signature dictionary says. **Anyone can write anything here:**
/// show these as claims. All are UTF-8; `date` is the PDF date string.
pub const Claims = struct {
    name: ?[]const u8 = null,
    date: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    location: ?[]const u8 = null,
    contact: ?[]const u8 = null,
};

/// Why a signature's byte range cannot be relied on.
pub const Defect = enum {
    /// The field's value is not a signature dictionary.
    not_a_signature,
    /// The whole file had to be repaired to be read.
    damaged_file,
    /// The signature dictionary is not stored as plain text in the file, for
    /// example inside an object stream, so no byte range can leave out its value.
    not_in_file,
    /// No `/ByteRange` of four whole numbers, none negative, written directly.
    no_byte_range,
    /// Not two parts, the first from the start of the file, with a gap between.
    byte_range_shape,
    /// The byte range runs past the end of the file.
    out_of_file,
    /// No `/Contents` string written directly.
    no_value,
    /// What the byte range leaves out is not exactly this dictionary's
    /// `/Contents` in hexadecimal.
    gap_is_not_value,
    /// The signature value is empty or all zeros.
    empty_value,
    /// The signed bytes do not end where a revision of the file ends.
    not_end_of_revision,
    /// The signed bytes cannot be read as a document without repair.
    revision_unreadable,
    /// Read on their own, the signed bytes do not have this signature in this
    /// place.
    revision_differs,
    /// The signature value is longer than `max_value_bytes`, or than what is
    /// left of `max_all_values_bytes`.
    value_too_large,
    /// The file has more signatures than `max_examined`. Nothing of this one
    /// but its field was read, so its kind and claims say nothing.
    not_examined,
};

pub const Coverage = union(enum) {
    /// The byte range is everything up to `end` but this signature's value.
    sound: struct {
        /// The length of the signed revision.
        end: usize,
        /// `/ByteRange`: two pairs of start and length.
        byte_range: [4]usize,
    },
    unsound: Defect,
};

pub const Change = struct {
    num: u32,
    kind: enum { added, replaced, removed },
};

pub const Changes = struct {
    /// How many bytes follow the signed revision.
    bytes: usize,
    /// The objects that the whole file takes from somewhere else than the signed
    /// revision does, by number. **It can be empty although the file changed:**
    /// readers that repair files may show content added without a
    /// cross-reference entry.
    objects: []const Change,
    /// How many more differ than `objects` holds (`max_changes`).
    omitted: usize = 0,
    /// The trailer names another catalog, information or encryption dictionary.
    trailer: bool,
};

pub const After = union(enum) {
    /// The coverage is unsound, so there is nothing to compare with.
    unknown,
    /// Nothing but white space follows the signed bytes.
    nothing,
    changed: Changes,
};

pub const Signature = struct {
    kind: Kind,
    /// The signature field, or 0 for one that only the permissions name.
    field_num: u32,
    /// The field's full name, or "" without a field.
    field_name: []const u8,
    /// The permissions dictionary names this signature (`DocMDP` or `UR3`).
    in_permissions: bool = false,
    /// For a certification: what it allows, or null if it says something else.
    allowed: ?Allowed = null,
    lock: ?Lock = null,
    claims: Claims = .{},
    /// `/Filter` and `/SubFilter`: the software and format the signature names.
    filter: ?[]const u8 = null,
    sub_filter: ?[]const u8 = null,
    /// The signature value, decoded from the bytes the byte range leaves out,
    /// including any padding. Empty unless the coverage is sound.
    value: []const u8 = "",
    coverage: Coverage,
    after: After = .unknown,
};

pub const Options = struct {
    /// The password the document was opened with: the signed revision is opened
    /// again on its own.
    password: []const u8 = "",
};

// What a file can make the listing do and keep is bounded: any number of
// fields can name one large dictionary.

/// Each examined signature opens part of the file again.
pub const max_examined = 64;
/// Real values, with certificates and revocation data, are far smaller.
pub const max_value_bytes = 16 << 20;
/// All the values one listing keeps.
pub const max_all_values_bytes = 64 << 20;
/// The text of all claims and lock names one listing reads. A claim that does
/// not fit is left out.
pub const max_listed_bytes = 1 << 20;
/// Names kept of one lock.
pub const max_lock_fields = 4096;
/// Changed objects listed for one signature, lowest numbers first.
pub const max_changes = 10_000;

/// What the listing may still copy.
const Budget = struct {
    text: usize = max_listed_bytes,
    values: usize = max_all_values_bytes,
};

/// The bytes a signature with sound coverage signs, with the gap: opening them
/// as a document shows the file as it was signed. **A signed revision can
/// itself hold content that a later change reveals** ("shadow attacks", Mainka
/// et al., NDSS 2021), so it is not proof of what the signer saw. The slice
/// lives as long as the document's bytes.
pub fn signedRevision(doc: *const Document, signature: Signature) ?[]const u8 {
    return switch (signature.coverage) {
        .sound => |s| doc.data[0..s.end],
        .unsound => null,
    };
}

/// The signatures of `doc`: those in signature fields that the form lists, then
/// any that only the permissions dictionary names. Only the first
/// `max_examined` are read. A field without a value is
/// not signed and not listed. **A later change can remove a signature from the
/// form**, so an empty result does not mean the file was never signed. Allocate
/// from an arena.
pub fn list(a: Allocator, doc: *Document, page_list: pages.PageList, options: Options) Allocator.Error![]Signature {
    var out: std.ArrayList(Signature) = .empty;
    // Where each listed signature's dictionary is, to match the permissions.
    var places: std.ArrayList(?usize) = .empty;
    var budget: Budget = .{};

    for (try form.fields(a, doc, page_list)) |field| {
        if (field.kind != .signature or field.num == 0) continue;
        const source = fieldValue(doc, field.num) orelse continue;
        try add(a, doc, &out, &places, source, .{
            .kind = .approval,
            .field_num = field.num,
            .field_name = field.name,
            .coverage = .{ .unsound = .not_a_signature },
        }, options, &budget);
    }

    if (permissions(doc)) |perms| for ([_][]const u8{ "DocMDP", "UR3" }) |key| {
        const source = permissionValue(doc, perms, key) orelse continue;
        const place = try dictOffset(doc, source);
        const listed = for (places.items, 0..) |other, i| {
            if (place != null and other == place) break i;
        } else null;
        if (listed) |i| {
            out.items[i].in_permissions = true;
            continue;
        }
        try add(a, doc, &out, &places, source, .{
            .kind = if (std.mem.eql(u8, key, "UR3")) .usage_rights else .approval,
            .field_num = 0,
            .field_name = "",
            .in_permissions = true,
            .coverage = .{ .unsound = .not_a_signature },
        }, options, &budget);
    };
    try doc.checkMemory(0);
    return out.toOwnedSlice(a);
}

/// Where a signature dictionary is named: object `num`, then the keys to follow
/// inside it. An empty path means the object is the dictionary.
const Source = struct {
    num: u32,
    path: [2]?[]const u8 = .{ null, null },
    /// How to find it again in another reading of the file.
    through: union(enum) { field: u32, permission: []const u8 },
};

/// The field's own or inherited `/V` (12.7.3.1), if it has one.
fn fieldValue(doc: *Document, field_num: u32) ?Source {
    var num = field_num;
    for (0..32) |_| {
        const d = doc.getObject(num).asDict() orelse return null;
        if (d.get("V")) |v| {
            if (v == .null) return null;
            // A reference that leads nowhere is kept, to be shown as broken: one
            // attack hides a signature from view this way.
            if (v == .ref) return .{ .num = v.ref.num, .through = .{ .field = field_num } };
            return .{ .num = num, .path = .{ "V", null }, .through = .{ .field = field_num } };
        }
        const parent = d.get("Parent") orelse return null;
        if (parent != .ref) return null;
        num = parent.ref.num;
    }
    return null;
}

fn permissions(doc: *Document) ?Dict {
    return doc.getDict(doc.catalog() orelse return null, "Perms");
}

fn permissionValue(doc: *Document, perms: Dict, key: []const u8) ?Source {
    const v = perms.get(key) orelse return null;
    if (v == .ref) return .{ .num = v.ref.num, .through = .{ .permission = key } };
    if (v != .dict) return null;
    // Written inside the permissions dictionary, or inside the catalog.
    const root = doc.trailer.get("Root") orelse return null;
    if (root != .ref) return null;
    const holder = doc.catalog().?.get("Perms").?;
    if (holder == .ref) return .{ .num = holder.ref.num, .path = .{ key, null }, .through = .{ .permission = key } };
    return .{ .num = root.ref.num, .path = .{ "Perms", key }, .through = .{ .permission = key } };
}

/// The signature dictionary as the document reads it (decrypted).
fn dictionary(doc: *Document, source: Source) ?Dict {
    var value = doc.getObject(source.num);
    for (source.path) |key| {
        value = doc.resolve((value.asDict() orelse return null).get(key orelse break) orelse return null);
    }
    return value.asDict();
}

/// A signature dictionary as it is written in the file.
const Place = struct {
    /// The offset of its `<<`.
    dict: usize,
    /// Its entries, not decrypted.
    entries: Dict,
    /// Where the last `/Contents` value starts and ends.
    contents: ?[2]usize,
};

const Span = struct { start: usize, end: usize };

/// Reads the dictionary whose `<<` is next, noting where the value of the last
/// `want` is. Null if there is no whole dictionary.
fn walk(p: *object.Parser, entries: *std.ArrayList(object.Entry), want: []const u8) Allocator.Error!?struct { at: usize, found: ?Span } {
    p.skipWs();
    const at = p.pos;
    if (!std.mem.startsWith(u8, p.src[at..], "<<")) return null;
    p.pos += 2;
    var found: ?Span = null;
    while (true) {
        p.skipWs();
        if (std.mem.startsWith(u8, p.src[p.pos..], ">>")) return .{ .at = at, .found = found };
        const key = p.parseObject() catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
        if (key != .name) return null;
        p.skipWs();
        const start = p.pos;
        const value = p.parseObject() catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
        try entries.append(p.a, .{ .key = key.name, .value = value });
        if (std.mem.eql(u8, key.name, want)) found = .{ .start = start, .end = p.pos };
    }
}

fn locate(a: Allocator, doc: *Document, source: Source) (Allocator.Error || error{NotInFile})!Place {
    const entry = doc.xref.get(source.num) orelse return error.NotInFile;
    if (entry != .in_use) return error.NotInFile;
    const offset = std.math.cast(usize, entry.in_use.offset) orelse return error.NotInFile;
    if (offset >= doc.data.len -| doc.base) return error.NotInFile;
    var p = object.Parser.init(a, doc.data, doc.base + offset);
    const number = p.token() orelse return error.NotInFile;
    if ((std.fmt.parseInt(u32, number, 10) catch return error.NotInFile) != source.num) return error.NotInFile;
    _ = p.token() orelse return error.NotInFile;
    if (!p.eatKeyword("obj")) return error.NotInFile;

    for (source.path) |maybe| {
        const key = maybe orelse break;
        var entries: std.ArrayList(object.Entry) = .empty;
        const outer = try walk(&p, &entries, key) orelse return error.NotInFile;
        p.pos = (outer.found orelse return error.NotInFile).start;
    }
    var entries: std.ArrayList(object.Entry) = .empty;
    const inner = try walk(&p, &entries, "Contents") orelse return error.NotInFile;
    return .{
        .dict = inner.at,
        .entries = .{ .entries = entries.items },
        .contents = if (inner.found) |s| .{ s.start, s.end } else null,
    };
}

/// The offset of the dictionary's `<<` in the file, if it is written there.
fn dictOffset(doc: *Document, source: Source) Allocator.Error!?usize {
    var scratch = std.heap.ArenaAllocator.init(doc.arena.child_allocator);
    defer scratch.deinit();
    const place = locate(scratch.allocator(), doc, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotInFile => return null,
    };
    return place.dict;
}

/// A text string as UTF-8, if it fits in what is left of the budget.
fn text(a: Allocator, budget: *Budget, v: Object) Allocator.Error!?[]const u8 {
    if (v != .string or v.string.len > budget.text) return null;
    budget.text -= v.string.len;
    return try write.textToUtf8(a, v.string);
}

fn claim(a: Allocator, doc: *Document, d: Dict, key: []const u8, budget: *Budget) Allocator.Error!?[]const u8 {
    return text(a, budget, doc.get(d, key) orelse return null);
}

fn name(a: Allocator, doc: *Document, d: Dict, key: []const u8, budget: *Budget) Allocator.Error!?[]const u8 {
    const n = doc.getName(d, key) orelse return null;
    if (n.len > budget.text) return null;
    budget.text -= n.len;
    return try a.dupe(u8, n);
}

/// Reads `Reference` (table 253) and the type, which settle the kind.
fn describe(a: Allocator, doc: *Document, d: Dict, s: *Signature, budget: *Budget) Allocator.Error!void {
    s.claims = .{
        .name = try claim(a, doc, d, "Name", budget),
        .date = try claim(a, doc, d, "M", budget),
        .reason = try claim(a, doc, d, "Reason", budget),
        .location = try claim(a, doc, d, "Location", budget),
        .contact = try claim(a, doc, d, "ContactInfo", budget),
    };
    s.filter = try name(a, doc, d, "Filter", budget);
    s.sub_filter = try name(a, doc, d, "SubFilter", budget);
    if (s.kind != .usage_rights) {
        const doc_type = std.mem.eql(u8, doc.getName(d, "Type") orelse "", "DocTimeStamp");
        if (doc_type or std.mem.eql(u8, s.sub_filter orelse "", "ETSI.RFC3161")) s.kind = .timestamp;
    }
    const references = doc.getArray(d, "Reference") orelse return;
    for (references[0..@min(references.len, 16)]) |item| {
        const reference = doc.resolve(item).asDict() orelse continue;
        const method = doc.getName(reference, "TransformMethod") orelse continue;
        const params = doc.getDict(reference, "TransformParams") orelse Dict{};
        if (std.mem.eql(u8, method, "DocMDP")) {
            s.kind = .certification;
            const level = if (doc.get(params, "P")) |v| v.asInt() orelse 0 else 2;
            s.allowed = switch (level) {
                1 => .nothing,
                2 => .forms_and_signing,
                3 => .forms_signing_and_annotations,
                else => null,
            };
        } else if (std.mem.eql(u8, method, "FieldMDP")) {
            const action = doc.getName(params, "Action") orelse continue;
            var names: std.ArrayList([]const u8) = .empty;
            var complete = true;
            if (doc.getArray(params, "Fields")) |items| for (items) |field| {
                const v = doc.resolve(field);
                if (v != .string) continue;
                const kept = if (names.items.len < max_lock_fields) try text(a, budget, v) else null;
                try names.append(a, kept orelse {
                    complete = false;
                    break;
                });
            };
            s.lock = .{
                .action = if (std.mem.eql(u8, action, "All")) .all else if (std.mem.eql(u8, action, "Include")) .include else if (std.mem.eql(u8, action, "Exclude")) .exclude else continue,
                .fields = names.items,
                .complete = complete,
            };
        }
    }
}

fn add(
    a: Allocator,
    doc: *Document,
    out: *std.ArrayList(Signature),
    places: *std.ArrayList(?usize),
    source: Source,
    initial: Signature,
    options: Options,
    budget: *Budget,
) Allocator.Error!void {
    var s = initial;
    var offset: ?usize = null;
    if (out.items.len >= max_examined) {
        s.coverage = .{ .unsound = .not_examined };
    } else if (dictionary(doc, source)) |d| {
        try describe(a, doc, d, &s, budget);
        // The dictionary as written is only needed while it is examined.
        var scratch = std.heap.ArenaAllocator.init(doc.arena.child_allocator);
        defer scratch.deinit();
        const place: ?Place = locate(scratch.allocator(), doc, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotInFile => null,
        };
        if (place) |found| offset = found.dict;
        if (doc.repaired) {
            s.coverage = .{ .unsound = .damaged_file };
        } else if (place) |found| {
            try examine(a, doc, source, found, &s, options, budget);
        } else s.coverage = .{ .unsound = .not_in_file };
    }
    try out.append(a, s);
    try places.append(a, offset);
}

/// A byte offset or length. Not `usize`: on 32 bits a large one must still be
/// seen to lie outside the file.
fn wholeNumber(v: Object) ?u64 {
    if (v != .integer or v.integer < 0) return null;
    return @intCast(v.integer);
}

/// Sets the coverage of `s`, and what came after it.
fn examine(a: Allocator, doc: *Document, source: Source, place: Place, s: *Signature, options: Options, budget: *Budget) Allocator.Error!void {
    const bad = struct {
        fn f(target: *Signature, defect: Defect) void {
            target.coverage = .{ .unsound = defect };
        }
    }.f;

    const array = place.entries.get("ByteRange") orelse return bad(s, .no_byte_range);
    if (array != .array or array.array.len != 4) return bad(s, .no_byte_range);
    var numbers: [4]u64 = undefined;
    for (array.array, &numbers) |item, *slot| slot.* = wholeNumber(item) orelse return bad(s, .no_byte_range);
    if (numbers[0] != 0 or numbers[1] == 0 or numbers[2] <= numbers[1] or numbers[3] == 0) return bad(s, .byte_range_shape);
    if (numbers[2] > doc.data.len or numbers[3] > doc.data.len - numbers[2]) return bad(s, .out_of_file);
    // The first length ends before the second start, so all fit now.
    const range: [4]usize = .{ 0, @intCast(numbers[1]), @intCast(numbers[2]), @intCast(numbers[3]) };
    const first = range[1];
    const second = range[2];
    const end = second + range[3];

    const contents = place.entries.get("Contents") orelse return bad(s, .no_value);
    if (contents != .string) return bad(s, .no_value);
    const span = place.contents orelse return bad(s, .no_value);
    // By position, not by value: another string like it elsewhere will not do.
    if (span[0] != first or span[1] != second) return bad(s, .gap_is_not_value);
    const gap = doc.data[first..second];
    if (gap.len < 2 or gap[0] != '<' or gap[gap.len - 1] != '>') return bad(s, .gap_is_not_value);
    const digits = gap[1 .. gap.len - 1];
    if (digits.len % 2 != 0) return bad(s, .gap_is_not_value);
    for (digits) |c| if (!std.ascii.isHex(c)) return bad(s, .gap_is_not_value);
    if (std.mem.allEqual(u8, digits, '0')) return bad(s, .empty_value);
    if (digits.len / 2 > @min(max_value_bytes, budget.values)) return bad(s, .value_too_large);

    var trimmed = end;
    while (trimmed > 0 and object.isWhite(doc.data[trimmed - 1])) trimmed -= 1;
    if (!std.mem.endsWith(u8, doc.data[0..trimmed], "%%EOF")) return bad(s, .not_end_of_revision);

    var open_options = doc.options;
    open_options.password = options.password;
    const gpa = doc.arena.child_allocator;
    var signed = Document.open(gpa, doc.data[0..end], open_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return bad(s, .revision_unreadable),
    };
    defer signed.deinit();
    if (signed.repaired) return bad(s, .revision_unreadable);

    // The signed bytes, read on their own, must lead to the same dictionary.
    const again: ?Source = switch (source.through) {
        .field => |num| fieldValue(&signed, num),
        .permission => |key| if (permissions(&signed)) |perms| permissionValue(&signed, perms, key) else null,
    };
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const there: ?Place = if (again) |found| locate(scratch.allocator(), &signed, found) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotInFile => null,
    } else null;
    try signed.checkMemory(0);
    if (signed.repaired) return bad(s, .revision_unreadable);
    if (there == null or there.?.dict != place.dict) return bad(s, .revision_differs);
    // A field the form of the signed revision does not list was not a field then.
    if (source.through == .field) {
        const signed_pages = try pages.PageList.build(&signed);
        const in_form = for (try form.fields(scratch.allocator(), &signed, signed_pages)) |field| {
            if (field.num == source.through.field) break true;
        } else false;
        try signed.checkMemory(0);
        if (!in_form) return bad(s, .revision_differs);
    }

    budget.values -= digits.len / 2;
    const value = try a.alloc(u8, digits.len / 2);
    _ = std.fmt.hexToBytes(value, digits) catch unreachable; // checked above
    s.value = value;
    s.coverage = .{ .sound = .{ .end = end, .byte_range = range } };

    for (doc.data[end..]) |c| {
        if (!object.isWhite(c)) break;
    } else {
        s.after = .nothing;
        return;
    }
    const differing = try compare(scratch.allocator(), &signed, doc);
    const kept = @min(differing.len, max_changes);
    s.after = .{ .changed = .{
        .bytes = doc.data.len - end,
        .objects = try a.dupe(Change, differing[0..kept]),
        .omitted = differing.len - kept,
        .trailer = trailerDiffers(&signed, doc),
    } };
}

fn inUse(entry: ?document.XrefEntry) ?document.XrefEntry {
    const e = entry orelse return null;
    return if (e == .free) null else e;
}

/// Whether two documents of the same bytes take an object from the same place.
fn samePlace(old: *const Document, new: *const Document, num: u32, was: document.XrefEntry, is: document.XrefEntry) bool {
    switch (was) {
        .free => return is == .free,
        .in_use => |e| return is == .in_use and is.in_use.offset == e.offset and is.in_use.gen == e.gen,
        .compressed => |c| {
            if (is != .compressed or is.compressed.stream_num != c.stream_num or is.compressed.index != c.index) return false;
            // The entry stays the same when the object stream is replaced.
            if (c.stream_num == num) return true;
            const before = inUse(old.xref.get(c.stream_num)) orelse return false;
            const after = inUse(new.xref.get(c.stream_num)) orelse return false;
            return before == .in_use and after == .in_use and
                before.in_use.offset == after.in_use.offset and before.in_use.gen == after.in_use.gen;
        },
    }
}

fn compare(a: Allocator, old: *const Document, new: *const Document) Allocator.Error![]Change {
    var out: std.ArrayList(Change) = .empty;
    var it = new.xref.iterator();
    while (it.next()) |entry| {
        const num = entry.key_ptr.*;
        const is = inUse(entry.value_ptr.*);
        const was = inUse(old.xref.get(num));
        if (is) |now| {
            if (was) |then| {
                if (!samePlace(old, new, num, then, now)) try out.append(a, .{ .num = num, .kind = .replaced });
            } else try out.append(a, .{ .num = num, .kind = .added });
        } else if (was != null) try out.append(a, .{ .num = num, .kind = .removed });
    }
    var before = old.xref.iterator();
    while (before.next()) |entry| {
        if (inUse(entry.value_ptr.*) != null and !new.xref.contains(entry.key_ptr.*)) {
            try out.append(a, .{ .num = entry.key_ptr.*, .kind = .removed });
        }
    }
    std.mem.sort(Change, out.items, {}, struct {
        fn less(_: void, x: Change, y: Change) bool {
            return x.num < y.num;
        }
    }.less);
    return out.toOwnedSlice(a);
}

fn trailerDiffers(old: *const Document, new: *const Document) bool {
    for ([_][]const u8{ "Root", "Info", "Encrypt" }) |key| {
        const was = old.trailer.get(key);
        const is = new.trailer.get(key);
        if ((was == null) != (is == null)) return true;
        if (was == null) continue;
        if (was.? == .ref) {
            if (is.? != .ref or !was.?.ref.eql(is.?.ref)) return true;
        } else if (is.? == .ref) return true;
    }
    return false;
}
