//! The PDF object model and the syntax parser (ISO 32000-1:2008, clauses 7.2
//! and 7.3).
//!
//! `Object` values are plain data. Strings, names, arrays and dictionaries are
//! allocated from the allocator given to the `Parser` (the document's arena);
//! stream data is a slice of the input and is not copied.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An indirect reference `num gen R` (7.3.10).
pub const Ref = struct {
    num: u32,
    gen: u16 = 0,

    pub fn eql(a: Ref, b: Ref) bool {
        return a.num == b.num and a.gen == b.gen;
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Object,
};

/// A dictionary (7.3.7). Keys are names without the slash. Dictionaries are
/// small, so lookup is a linear search; the first entry of a repeated key wins.
pub const Dict = struct {
    entries: []const Entry = &.{},

    pub fn get(self: Dict, key: []const u8) ?Object {
        for (self.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    pub fn has(self: Dict, key: []const u8) bool {
        return self.get(key) != null;
    }
};

/// A stream (7.3.8): its dictionary and the raw bytes between `stream` and
/// `endstream`, still encoded with the dictionary's filters.
pub const Stream = struct {
    dict: Dict,
    data: []const u8,
};

pub const Object = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    /// Decoded string bytes (literal escapes and hex digits resolved).
    string: []const u8,
    /// Decoded name without the leading slash (`#xx` resolved).
    name: []const u8,
    array: []const Object,
    dict: Dict,
    stream: Stream,
    ref: Ref,

    pub fn asInt(self: Object) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .real => |r| if (std.math.isFinite(r) and @abs(r) < 9e18) @as(i64, @intFromFloat(@trunc(r))) else null,
            else => null,
        };
    }

    pub fn asNum(self: Object) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .real => |r| r,
            else => null,
        };
    }

    pub fn asName(self: Object) ?[]const u8 {
        return switch (self) {
            .name => |n| n,
            else => null,
        };
    }

    pub fn asDict(self: Object) ?Dict {
        return switch (self) {
            .dict => |d| d,
            .stream => |s| s.dict,
            else => null,
        };
    }

    pub fn asArray(self: Object) ?[]const Object {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }
};

pub const ParseError = error{
    /// The text is not valid PDF syntax at this point.
    Syntax,
    /// Objects are nested deeper than `Parser.max_depth`.
    TooDeep,
    OutOfMemory,
};

/// White-space characters (7.2.3, table 1).
pub fn isWhite(c: u8) bool {
    return switch (c) {
        0, 9, 10, 12, 13, 32 => true,
        else => false,
    };
}

/// Delimiter characters (7.2.3, table 2).
pub fn isDelim(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

pub fn isRegular(c: u8) bool {
    return !isWhite(c) and !isDelim(c);
}

pub const Parser = struct {
    /// Allocator for strings, names, arrays and dictionaries.
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    pub const max_depth = 64;

    pub fn init(a: Allocator, src: []const u8, pos: usize) Parser {
        return .{ .a = a, .src = src, .pos = pos };
    }

    pub fn atEnd(self: *const Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    /// Skips white space and comments (7.2.4).
    pub fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isWhite(c)) {
                self.pos += 1;
            } else if (c == '%') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n' and self.src[self.pos] != '\r') self.pos += 1;
            } else break;
        }
    }

    /// The regular-character token at the cursor (a keyword or number text), or
    /// null if the cursor is at a delimiter or the end.
    pub fn token(self: *Parser) ?[]const u8 {
        self.skipWs();
        const start = self.pos;
        while (self.pos < self.src.len and isRegular(self.src[self.pos])) self.pos += 1;
        return if (self.pos > start) self.src[start..self.pos] else null;
    }

    /// True (and consumes it) if the next token is exactly `kw`.
    pub fn eatKeyword(self: *Parser, kw: []const u8) bool {
        const save = self.pos;
        const t = self.token() orelse {
            self.pos = save;
            return false;
        };
        if (std.mem.eql(u8, t, kw)) return true;
        self.pos = save;
        return false;
    }

    /// Parses one object. A dictionary followed by `stream` is *not* turned into
    /// a stream here; see `document.zig` for indirect objects.
    pub fn parseObject(self: *Parser) ParseError!Object {
        self.skipWs();
        const c = self.peek() orelse return error.Syntax;
        switch (c) {
            '/' => return .{ .name = try self.parseName() },
            '(' => return .{ .string = try self.parseLiteralString() },
            '<' => {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '<') return self.parseDict();
                return .{ .string = try self.parseHexString() };
            },
            '[' => return self.parseArray(),
            '+', '-', '.', '0'...'9' => return self.parseNumberOrRef(),
            else => {
                const t = self.token() orelse return error.Syntax;
                if (std.mem.eql(u8, t, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, t, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, t, "null")) return .null;
                return error.Syntax;
            },
        }
    }

    fn enter(self: *Parser) ParseError!void {
        if (self.depth >= max_depth) return error.TooDeep;
        self.depth += 1;
    }

    fn parseName(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // the slash
        const start = self.pos;
        while (self.pos < self.src.len and isRegular(self.src[self.pos])) self.pos += 1;
        const raw = self.src[start..self.pos];
        if (std.mem.indexOfScalar(u8, raw, '#') == null) return raw;
        // `#xx` stands for the byte xx (7.3.5).
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '#' and i + 2 < raw.len + 0 and i + 2 <= raw.len - 1 + 0) {
                if (hexVal(raw[i + 1])) |hi| if (hexVal(raw[i + 2])) |lo| {
                    try out.append(self.a, hi * 16 + lo);
                    i += 2;
                    continue;
                };
            }
            try out.append(self.a, raw[i]);
        }
        return out.items;
    }

    fn hexVal(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    /// 7.3.4.2: balanced parentheses, backslash escapes, octal codes, and
    /// end-of-line normalisation to LF.
    fn parseLiteralString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // (
        var out: std.ArrayList(u8) = .empty;
        var depth: usize = 1;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            switch (c) {
                '(' => {
                    depth += 1;
                    try out.append(self.a, c);
                },
                ')' => {
                    depth -= 1;
                    if (depth == 0) return out.items;
                    try out.append(self.a, c);
                },
                '\\' => {
                    if (self.pos >= self.src.len) break;
                    const e = self.src[self.pos];
                    self.pos += 1;
                    switch (e) {
                        'n' => try out.append(self.a, '\n'),
                        'r' => try out.append(self.a, '\r'),
                        't' => try out.append(self.a, '\t'),
                        'b' => try out.append(self.a, 8),
                        'f' => try out.append(self.a, 12),
                        '(', ')', '\\' => try out.append(self.a, e),
                        '\r' => {
                            // A backslash before an end-of-line continues the line.
                            if (self.pos < self.src.len and self.src[self.pos] == '\n') self.pos += 1;
                        },
                        '\n' => {},
                        '0'...'7' => {
                            var v: u32 = e - '0';
                            var n: usize = 1;
                            while (n < 3 and self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '7') : (n += 1) {
                                v = v * 8 + (self.src[self.pos] - '0');
                                self.pos += 1;
                            }
                            try out.append(self.a, @truncate(v));
                        },
                        else => try out.append(self.a, e), // unknown escape: the character itself
                    }
                },
                '\r' => {
                    if (self.pos < self.src.len and self.src[self.pos] == '\n') self.pos += 1;
                    try out.append(self.a, '\n');
                },
                else => try out.append(self.a, c),
            }
        }
        return error.Syntax; // unterminated
    }

    /// 7.3.4.3: hex digits, white space ignored, a missing final digit is 0.
    fn parseHexString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // <
        var out: std.ArrayList(u8) = .empty;
        var hi: ?u8 = null;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == '>') {
                if (hi) |h| try out.append(self.a, h * 16);
                return out.items;
            }
            if (isWhite(c)) continue;
            const v = hexVal(c) orelse return error.Syntax;
            if (hi) |h| {
                try out.append(self.a, h * 16 + v);
                hi = null;
            } else hi = v;
        }
        return error.Syntax;
    }

    fn parseArray(self: *Parser) ParseError!Object {
        try self.enter();
        defer self.depth -= 1;
        self.pos += 1; // [
        var items: std.ArrayList(Object) = .empty;
        while (true) {
            self.skipWs();
            const c = self.peek() orelse return error.Syntax;
            if (c == ']') {
                self.pos += 1;
                return .{ .array = items.items };
            }
            try items.append(self.a, try self.parseObject());
        }
    }

    fn parseDict(self: *Parser) ParseError!Object {
        try self.enter();
        defer self.depth -= 1;
        self.pos += 2; // <<
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            self.skipWs();
            const c = self.peek() orelse return error.Syntax;
            if (c == '>') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
                    self.pos += 2;
                    return .{ .dict = .{ .entries = entries.items } };
                }
                return error.Syntax;
            }
            if (c != '/') return error.Syntax;
            const key = try self.parseName();
            self.skipWs();
            // A key with no value before `>>` is dropped (damaged files).
            if (self.peek() == '>') continue;
            const value = try self.parseObject();
            try entries.append(self.a, .{ .key = key, .value = value });
        }
    }

    /// An integer, a real, or `num gen R` (7.3.3, 7.3.10).
    fn parseNumberOrRef(self: *Parser) ParseError!Object {
        const start = self.pos;
        const num = try self.number();
        if (num != .integer or num.integer < 0 or num.integer > std.math.maxInt(u32)) return num;
        // Look ahead for `gen R`.
        const after_num = self.pos;
        self.skipWs();
        const gstart = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        if (self.pos > gstart and self.pos - gstart <= 5) {
            const gen = std.fmt.parseInt(u32, self.src[gstart..self.pos], 10) catch 0;
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == 'R' and
                (self.pos + 1 >= self.src.len or !isRegular(self.src[self.pos + 1])) and gen <= 65535)
            {
                self.pos += 1;
                return .{ .ref = .{ .num = @intCast(num.integer), .gen = @intCast(gen) } };
            }
        }
        self.pos = after_num;
        _ = start;
        return num;
    }

    /// Reads a number token: `[+-]digits[.digits]`, also `.5`, `-.5`, `4.`.
    pub fn number(self: *Parser) ParseError!Object {
        const start = self.pos;
        var i = self.pos;
        if (i < self.src.len and (self.src[i] == '+' or self.src[i] == '-')) i += 1;
        // Some producers write a doubled sign (`--5`); read it as the sign once.
        while (i < self.src.len and (self.src[i] == '-' or self.src[i] == '+')) i += 1;
        const digits_start = i;
        var seen_dot = false;
        while (i < self.src.len) : (i += 1) {
            const c = self.src[i];
            if (std.ascii.isDigit(c)) continue;
            if (c == '.' and !seen_dot) {
                seen_dot = true;
                continue;
            }
            break;
        }
        if (i == digits_start) return error.Syntax;
        if (i < self.src.len and isRegular(self.src[i])) return error.Syntax; // `12abc`
        const text = self.src[start..i];
        self.pos = i;
        const neg = text[0] == '-';
        var body = text[0..];
        while (body.len > 0 and (body[0] == '+' or body[0] == '-')) body = body[1..];
        if (!seen_dot) {
            const v = std.fmt.parseInt(i64, body, 10) catch {
                // Too big for an integer: keep it as a real.
                const f = std.fmt.parseFloat(f64, body) catch return error.Syntax;
                return .{ .real = if (neg) -f else f };
            };
            return .{ .integer = if (neg) -v else v };
        }
        // "4." and ".5" are valid; parseFloat wants digits on both sides.
        var buf: [64]u8 = undefined;
        if (body.len + 2 > buf.len) return error.Syntax;
        var n: usize = 0;
        if (body[0] == '.') {
            buf[n] = '0';
            n += 1;
        }
        @memcpy(buf[n .. n + body.len], body);
        n += body.len;
        if (body[body.len - 1] == '.') {
            buf[n] = '0';
            n += 1;
        }
        const f = std.fmt.parseFloat(f64, buf[0..n]) catch return error.Syntax;
        return .{ .real = if (neg) -f else f };
    }
};

fn parseAll(a: Allocator, text: []const u8) ParseError!Object {
    var p = Parser.init(a, text, 0);
    return p.parseObject();
}

test "numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(i64, 123), (try parseAll(a, "123")).integer);
    try std.testing.expectEqual(@as(i64, -98), (try parseAll(a, "-98")).integer);
    try std.testing.expectEqual(@as(i64, 43445), (try parseAll(a, "+43445")).integer);
    try std.testing.expectEqual(@as(f64, 34.5), (try parseAll(a, "34.5")).real);
    try std.testing.expectEqual(@as(f64, -3.62), (try parseAll(a, "-3.62")).real);
    try std.testing.expectEqual(@as(f64, 0.5), (try parseAll(a, ".5")).real);
    try std.testing.expectEqual(@as(f64, -0.5), (try parseAll(a, "-.5")).real);
    try std.testing.expectEqual(@as(f64, 4.0), (try parseAll(a, "4.")).real);
    try std.testing.expectEqual(@as(i64, -5), (try parseAll(a, "--5")).integer);
    // Too large for i64: a real, not an error or a wrap.
    try std.testing.expect((try parseAll(a, "99999999999999999999")).real > 1e19);
    try std.testing.expectError(error.Syntax, parseAll(a, "12abc"));
}

test "strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("This is a string", (try parseAll(a, "(This is a string)")).string);
    try std.testing.expectEqualStrings("a(b)c", (try parseAll(a, "(a(b)c)")).string);
    try std.testing.expectEqualStrings("a\nb\t(\\", (try parseAll(a, "(a\\nb\\t\\(\\\\)")).string);
    try std.testing.expectEqualStrings("AB", (try parseAll(a, "(\\101\\102)")).string);
    try std.testing.expectEqualStrings("\x053", (try parseAll(a, "(\\0053)")).string);
    try std.testing.expectEqualStrings("ab", (try parseAll(a, "(a\\\nb)")).string);
    try std.testing.expectEqualStrings("a\nb", (try parseAll(a, "(a\r\nb)")).string);
    try std.testing.expectEqualStrings("Nov", (try parseAll(a, "<4E6F76>")).string);
    try std.testing.expectEqualStrings("\x90\x10", (try parseAll(a, "<9 01 0>")).string);
    try std.testing.expectError(error.Syntax, parseAll(a, "(unterminated"));
    try std.testing.expectError(error.Syntax, parseAll(a, "<4E6"[0..3]));
}

test "names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Name1", (try parseAll(a, "/Name1")).name);
    try std.testing.expectEqualStrings("A B", (try parseAll(a, "/A#20B")).name);
    try std.testing.expectEqualStrings("", (try parseAll(a, "/ ")).name);
    try std.testing.expectEqualStrings("a#zz", (try parseAll(a, "/a#zz")).name);
}

test "arrays, dictionaries, references, keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const arr = (try parseAll(a, "[549 3.14 false (Ralph) /SomeName 12 0 R]")).array;
    try std.testing.expectEqual(@as(usize, 6), arr.len);
    try std.testing.expectEqual(@as(u32, 12), arr[5].ref.num);

    const d = (try parseAll(a, "<< /Type /Page /Parent 4 0 R /Kids [1 0 R 2 0 R] /N null /Dup 1 /Dup 2 >>")).dict;
    try std.testing.expectEqualStrings("Page", d.get("Type").?.name);
    try std.testing.expectEqual(@as(u16, 0), d.get("Parent").?.ref.gen);
    try std.testing.expectEqual(@as(usize, 2), d.get("Kids").?.array.len);
    try std.testing.expect(d.get("N").? == .null);
    try std.testing.expectEqual(@as(i64, 1), d.get("Dup").?.integer); // first wins
    try std.testing.expect(d.get("Missing") == null);

    // Comments and a value-less key are tolerated.
    const d2 = (try parseAll(a, "<< /A 1 % comment\n /B >>")).dict;
    try std.testing.expectEqual(@as(i64, 1), d2.get("A").?.integer);
    try std.testing.expect(!d2.has("B"));

    // "1 2" is two integers, not a reference.
    var p = Parser.init(a, "1 2 3", 0);
    try std.testing.expectEqual(@as(i64, 1), (try p.parseObject()).integer);
    try std.testing.expectEqual(@as(i64, 2), (try p.parseObject()).integer);
    try std.testing.expect(try p.parseObject() == .integer);
}

test "nesting is limited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = try a.alloc(u8, 10_000);
    @memset(deep, '[');
    try std.testing.expectError(error.TooDeep, parseAll(a, deep));
}

test "malformed input never crashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inputs = [_][]const u8{ "", "<<", "<< /A", "<< /A >", "[", "[ ]]", "(", "(\\", "/", "<", "<<>>", "<<123>>", "R", "1 0", "tru", "-", ".", "+.", "1 0 R R" };
    for (inputs) |text| _ = parseAll(a, text) catch {};
}
