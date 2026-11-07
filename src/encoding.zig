//! Simple-font encodings (ISO 32000-1:2008, Annex D) and glyph names.
//!
//! An encoding maps a one-byte character code to a Unicode code point. The
//! tables cover the Latin repertoire of StandardEncoding, WinAnsiEncoding and
//! MacRomanEncoding. Glyph names outside the Latin set are handled only in the
//! forms `uniXXXX`, `uXXXX..XXXXXX` and `a_b` ligature names; anything else has
//! no Unicode value here (text then comes from `/ToUnicode`).

const std = @import("std");
const agl = @import("agl.zig");

pub const Base = enum { standard, win_ansi, mac_roman, pdf_doc, none };

/// Glyph names with Unicode values: the Latin glyphs of the three encodings and
/// the common typographic extras, from the Adobe Glyph List.
pub const names = [_]struct { []const u8, u21 }{
    .{ "space", 0x20 },            .{ "exclam", 0x21 },          .{ "quotedbl", 0x22 },         .{ "numbersign", 0x23 },
    .{ "dollar", 0x24 },           .{ "percent", 0x25 },         .{ "ampersand", 0x26 },        .{ "quotesingle", 0x27 },
    .{ "parenleft", 0x28 },        .{ "parenright", 0x29 },      .{ "asterisk", 0x2A },         .{ "plus", 0x2B },
    .{ "comma", 0x2C },            .{ "hyphen", 0x2D },          .{ "period", 0x2E },           .{ "slash", 0x2F },
    .{ "zero", 0x30 },             .{ "one", 0x31 },             .{ "two", 0x32 },              .{ "three", 0x33 },
    .{ "four", 0x34 },             .{ "five", 0x35 },            .{ "six", 0x36 },              .{ "seven", 0x37 },
    .{ "eight", 0x38 },            .{ "nine", 0x39 },            .{ "colon", 0x3A },            .{ "semicolon", 0x3B },
    .{ "less", 0x3C },             .{ "equal", 0x3D },           .{ "greater", 0x3E },          .{ "question", 0x3F },
    .{ "at", 0x40 },               .{ "A", 0x41 },               .{ "B", 0x42 },                .{ "C", 0x43 },
    .{ "D", 0x44 },                .{ "E", 0x45 },               .{ "F", 0x46 },                .{ "G", 0x47 },
    .{ "H", 0x48 },                .{ "I", 0x49 },               .{ "J", 0x4A },                .{ "K", 0x4B },
    .{ "L", 0x4C },                .{ "M", 0x4D },               .{ "N", 0x4E },                .{ "O", 0x4F },
    .{ "P", 0x50 },                .{ "Q", 0x51 },               .{ "R", 0x52 },                .{ "S", 0x53 },
    .{ "T", 0x54 },                .{ "U", 0x55 },               .{ "V", 0x56 },                .{ "W", 0x57 },
    .{ "X", 0x58 },                .{ "Y", 0x59 },               .{ "Z", 0x5A },                .{ "bracketleft", 0x5B },
    .{ "backslash", 0x5C },        .{ "bracketright", 0x5D },    .{ "asciicircum", 0x5E },      .{ "underscore", 0x5F },
    .{ "grave", 0x60 },            .{ "a", 0x61 },               .{ "b", 0x62 },                .{ "c", 0x63 },
    .{ "d", 0x64 },                .{ "e", 0x65 },               .{ "f", 0x66 },                .{ "g", 0x67 },
    .{ "h", 0x68 },                .{ "i", 0x69 },               .{ "j", 0x6A },                .{ "k", 0x6B },
    .{ "l", 0x6C },                .{ "m", 0x6D },               .{ "n", 0x6E },                .{ "o", 0x6F },
    .{ "p", 0x70 },                .{ "q", 0x71 },               .{ "r", 0x72 },                .{ "s", 0x73 },
    .{ "t", 0x74 },                .{ "u", 0x75 },               .{ "v", 0x76 },                .{ "w", 0x77 },
    .{ "x", 0x78 },                .{ "y", 0x79 },               .{ "z", 0x7A },                .{ "braceleft", 0x7B },
    .{ "bar", 0x7C },              .{ "braceright", 0x7D },      .{ "asciitilde", 0x7E },       .{ "exclamdown", 0xA1 },
    .{ "cent", 0xA2 },             .{ "sterling", 0xA3 },        .{ "currency", 0xA4 },         .{ "yen", 0xA5 },
    .{ "brokenbar", 0xA6 },        .{ "section", 0xA7 },         .{ "dieresis", 0xA8 },         .{ "copyright", 0xA9 },
    .{ "ordfeminine", 0xAA },      .{ "guillemotleft", 0xAB },   .{ "logicalnot", 0xAC },       .{ "registered", 0xAE },
    .{ "macron", 0xAF },           .{ "degree", 0xB0 },          .{ "plusminus", 0xB1 },        .{ "twosuperior", 0xB2 },
    .{ "threesuperior", 0xB3 },    .{ "acute", 0xB4 },           .{ "mu", 0xB5 },               .{ "paragraph", 0xB6 },
    .{ "periodcentered", 0xB7 },   .{ "cedilla", 0xB8 },         .{ "onesuperior", 0xB9 },      .{ "ordmasculine", 0xBA },
    .{ "guillemotright", 0xBB },   .{ "onequarter", 0xBC },      .{ "onehalf", 0xBD },          .{ "threequarters", 0xBE },
    .{ "questiondown", 0xBF },     .{ "Agrave", 0xC0 },          .{ "Aacute", 0xC1 },           .{ "Acircumflex", 0xC2 },
    .{ "Atilde", 0xC3 },           .{ "Adieresis", 0xC4 },       .{ "Aring", 0xC5 },            .{ "AE", 0xC6 },
    .{ "Ccedilla", 0xC7 },         .{ "Egrave", 0xC8 },          .{ "Eacute", 0xC9 },           .{ "Ecircumflex", 0xCA },
    .{ "Edieresis", 0xCB },        .{ "Igrave", 0xCC },          .{ "Iacute", 0xCD },           .{ "Icircumflex", 0xCE },
    .{ "Idieresis", 0xCF },        .{ "Eth", 0xD0 },             .{ "Ntilde", 0xD1 },           .{ "Ograve", 0xD2 },
    .{ "Oacute", 0xD3 },           .{ "Ocircumflex", 0xD4 },     .{ "Otilde", 0xD5 },           .{ "Odieresis", 0xD6 },
    .{ "multiply", 0xD7 },         .{ "Oslash", 0xD8 },          .{ "Ugrave", 0xD9 },           .{ "Uacute", 0xDA },
    .{ "Ucircumflex", 0xDB },      .{ "Udieresis", 0xDC },       .{ "Yacute", 0xDD },           .{ "Thorn", 0xDE },
    .{ "germandbls", 0xDF },       .{ "agrave", 0xE0 },          .{ "aacute", 0xE1 },           .{ "acircumflex", 0xE2 },
    .{ "atilde", 0xE3 },           .{ "adieresis", 0xE4 },       .{ "aring", 0xE5 },            .{ "ae", 0xE6 },
    .{ "ccedilla", 0xE7 },         .{ "egrave", 0xE8 },          .{ "eacute", 0xE9 },           .{ "ecircumflex", 0xEA },
    .{ "edieresis", 0xEB },        .{ "igrave", 0xEC },          .{ "iacute", 0xED },           .{ "icircumflex", 0xEE },
    .{ "idieresis", 0xEF },        .{ "eth", 0xF0 },             .{ "ntilde", 0xF1 },           .{ "ograve", 0xF2 },
    .{ "oacute", 0xF3 },           .{ "ocircumflex", 0xF4 },     .{ "otilde", 0xF5 },           .{ "odieresis", 0xF6 },
    .{ "divide", 0xF7 },           .{ "oslash", 0xF8 },          .{ "ugrave", 0xF9 },           .{ "uacute", 0xFA },
    .{ "ucircumflex", 0xFB },      .{ "udieresis", 0xFC },       .{ "yacute", 0xFD },           .{ "thorn", 0xFE },
    .{ "ydieresis", 0xFF },        .{ "Euro", 0x20AC },          .{ "quotesinglbase", 0x201A }, .{ "florin", 0x0192 },
    .{ "quotedblbase", 0x201E },   .{ "ellipsis", 0x2026 },      .{ "dagger", 0x2020 },         .{ "daggerdbl", 0x2021 },
    .{ "circumflex", 0x02C6 },     .{ "perthousand", 0x2030 },   .{ "Scaron", 0x0160 },         .{ "guilsinglleft", 0x2039 },
    .{ "OE", 0x0152 },             .{ "Zcaron", 0x017D },        .{ "quoteleft", 0x2018 },      .{ "quoteright", 0x2019 },
    .{ "quotedblleft", 0x201C },   .{ "quotedblright", 0x201D }, .{ "bullet", 0x2022 },         .{ "endash", 0x2013 },
    .{ "emdash", 0x2014 },         .{ "tilde", 0x02DC },         .{ "trademark", 0x2122 },      .{ "scaron", 0x0161 },
    .{ "guilsinglright", 0x203A }, .{ "oe", 0x0153 },            .{ "zcaron", 0x017E },         .{ "Ydieresis", 0x0178 },
    .{ "fi", 0xFB01 },             .{ "fl", 0xFB02 },            .{ "ff", 0xFB00 },             .{ "ffi", 0xFB03 },
    .{ "ffl", 0xFB04 },            .{ "dotlessi", 0x0131 },      .{ "Lslash", 0x0141 },         .{ "lslash", 0x0142 },
    .{ "fraction", 0x2044 },       .{ "breve", 0x02D8 },         .{ "caron", 0x02C7 },          .{ "dotaccent", 0x02D9 },
    .{ "hungarumlaut", 0x02DD },   .{ "ogonek", 0x02DB },        .{ "ring", 0x02DA },           .{ "minus", 0x2212 },
    .{ "nbspace", 0xA0 },          .{ "sfthyphen", 0xAD },       .{ "periodcentered", 0xB7 },   .{ "mu1", 0xB5 },
    .{ "Delta", 0x2206 },          .{ "Omega", 0x2126 },         .{ "notequal", 0x2260 },       .{ "infinity", 0x221E },
    .{ "lessequal", 0x2264 },      .{ "greaterequal", 0x2265 },  .{ "partialdiff", 0x2202 },    .{ "summation", 0x2211 },
    .{ "product", 0x220F },        .{ "pi", 0x03C0 },            .{ "integral", 0x222B },       .{ "radical", 0x221A },
    .{ "approxequal", 0x2248 },    .{ "lozenge", 0x25CA },       .{ "apple", 0xF8FF },
};

/// Unicode value of a glyph name, or null.
pub fn unicodeOfName(name: []const u8) ?u21 {
    // Names with a suffix (`a.sc`, `one.oldstyle`) stand for the base glyph.
    const base = if (std.mem.indexOfScalar(u8, name, '.')) |d| (if (d > 0) name[0..d] else name) else name;
    for (names) |n| if (std.mem.eql(u8, n[0], base)) return n[1];
    // Some producers (dvips, Type 3 bitmap fonts) name a glyph by its character.
    if (base.len == 1 and base[0] > 0x20 and base[0] < 0x7F) return base[0];
    if (agl.glyphNameToUnicode(base)) |u| return u;
    if (std.mem.startsWith(u8, base, "uni") and base.len >= 7) {
        return std.fmt.parseInt(u21, base[3..7], 16) catch null;
    }
    if (base.len >= 5 and base[0] == 'u' and base.len <= 7) {
        return std.fmt.parseInt(u21, base[1..], 16) catch null;
    }
    return null;
}

/// The glyph name for a code point (the first match in `names`), or null.
pub fn nameOfUnicode(u: u21) ?[]const u8 {
    for (names) |n| if (n[1] == u) return n[0];
    return null;
}

/// cp1252 (WinAnsiEncoding), codes 0x80..0x9F; the rest is Latin-1.
const win_high = [32]u21{
    0x20AC, 0x2022, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x2022, 0x017D, 0x2022,
    0x2022, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x2022, 0x017E, 0x0178,
};

/// MacRomanEncoding, codes 0x80..0xFF.
const mac_high = [128]u21{
    0xC4,   0xC5,   0xC7,   0xC9,   0xD1,   0xD6,   0xDC,   0xE1,   0xE0,   0xE2,   0xE4,   0xE3,   0xE5,   0xE7,   0xE9,   0xE8,
    0xEA,   0xEB,   0xED,   0xEC,   0xEE,   0xEF,   0xF1,   0xF3,   0xF2,   0xF4,   0xF6,   0xF5,   0xFA,   0xF9,   0xFB,   0xFC,
    0x2020, 0xB0,   0xA2,   0xA3,   0xA7,   0x2022, 0xB6,   0xDF,   0xAE,   0xA9,   0x2122, 0xB4,   0xA8,   0x2260, 0xC6,   0xD8,
    0x221E, 0xB1,   0x2264, 0x2265, 0xA5,   0xB5,   0x2202, 0x2211, 0x220F, 0x03C0, 0x222B, 0xAA,   0xBA,   0x2126, 0xE6,   0xF8,
    0xBF,   0xA1,   0xAC,   0x221A, 0x0192, 0x2248, 0x2206, 0xAB,   0xBB,   0x2026, 0xA0,   0xC0,   0xC3,   0xD5,   0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0xF7,   0x25CA, 0xFF,   0x0178, 0x2044, 0xA4,   0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0xB7,   0x201A, 0x201E, 0x2030, 0xC2,   0xCA,   0xC1,   0xCB,   0xC8,   0xCD,   0xCE,   0xCF,   0xCC,   0xD3,   0xD4,
    0xF8FF, 0xD2,   0xDA,   0xDB,   0xD9,   0x0131, 0x02C6, 0x02DC, 0xAF,   0x02D8, 0x02D9, 0x02DA, 0xB8,   0x02DD, 0x02DB, 0x02C7,
};

/// StandardEncoding, codes 0xA1..0xFB (0 for unused codes).
fn standardHigh(code: u8) u21 {
    return switch (code) {
        0xA1 => 0xA1,
        0xA2 => 0xA2,
        0xA3 => 0xA3,
        0xA4 => 0x2044,
        0xA5 => 0xA5,
        0xA6 => 0x0192,
        0xA7 => 0xA7,
        0xA8 => 0xA4,
        0xA9 => 0x27,
        0xAA => 0x201C,
        0xAB => 0xAB,
        0xAC => 0x2039,
        0xAD => 0x203A,
        0xAE => 0xFB01,
        0xAF => 0xFB02,
        0xB1 => 0x2013,
        0xB2 => 0x2020,
        0xB3 => 0x2021,
        0xB4 => 0xB7,
        0xB6 => 0xB6,
        0xB7 => 0x2022,
        0xB8 => 0x201A,
        0xB9 => 0x201E,
        0xBA => 0x201D,
        0xBB => 0xBB,
        0xBC => 0x2026,
        0xBD => 0x2030,
        0xBF => 0xBF,
        0xC1 => 0x60,
        0xC2 => 0xB4,
        0xC3 => 0x02C6,
        0xC4 => 0x02DC,
        0xC5 => 0xAF,
        0xC6 => 0x02D8,
        0xC7 => 0x02D9,
        0xC8 => 0xA8,
        0xCA => 0x02DA,
        0xCB => 0xB8,
        0xCD => 0x02DD,
        0xCE => 0x02DB,
        0xCF => 0x02C7,
        0xD0 => 0x2014,
        0xE1 => 0xC6,
        0xE3 => 0xAA,
        0xE8 => 0x0141,
        0xE9 => 0xD8,
        0xEA => 0x0152,
        0xEB => 0xBA,
        0xF1 => 0xE6,
        0xF5 => 0x0131,
        0xF8 => 0x0142,
        0xF9 => 0xF8,
        0xFA => 0x0153,
        0xFB => 0xDF,
        else => 0,
    };
}

/// The Unicode value of `code` in base encoding `base`, or 0 if unmapped.
pub fn unicodeOf(base: Base, code: u8) u21 {
    switch (base) {
        .win_ansi => {
            if (code >= 0x20 and code < 0x7F) return code;
            if (code >= 0x80 and code < 0xA0) return win_high[code - 0x80];
            if (code >= 0xA0) return code;
            return 0;
        },
        .mac_roman => {
            if (code >= 0x20 and code < 0x7F) return code;
            if (code >= 0x80) return mac_high[code - 0x80];
            return 0;
        },
        .standard => {
            if (code == 0x27) return 0x2019; // quoteright
            if (code == 0x60) return 0x2018; // quoteleft
            if (code >= 0x20 and code < 0x7F) return code;
            if (code >= 0xA1) return standardHigh(code);
            return 0;
        },
        .pdf_doc => return unicodeOf(.win_ansi, code),
        .none => return 0,
    }
}

/// StandardEncoding as a table: the code point of each code, 0 where unused.
pub const standard_encoding: [256]u21 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u21 = undefined;
    for (0..256) |c| t[c] = unicodeOf(.standard, @intCast(c));
    break :blk t;
};

pub fn baseFromName(name: []const u8) ?Base {
    if (std.mem.eql(u8, name, "WinAnsiEncoding")) return .win_ansi;
    if (std.mem.eql(u8, name, "MacRomanEncoding")) return .mac_roman;
    if (std.mem.eql(u8, name, "StandardEncoding")) return .standard;
    if (std.mem.eql(u8, name, "PDFDocEncoding")) return .pdf_doc;
    if (std.mem.eql(u8, name, "MacExpertEncoding")) return .standard; // no expert glyph tables here
    return null;
}

test "base encodings" {
    try std.testing.expectEqual(@as(u21, 'A'), unicodeOf(.win_ansi, 'A'));
    try std.testing.expectEqual(@as(u21, 0x20AC), unicodeOf(.win_ansi, 0x80));
    try std.testing.expectEqual(@as(u21, 0xE9), unicodeOf(.win_ansi, 0xE9));
    try std.testing.expectEqual(@as(u21, 0x201C), unicodeOf(.win_ansi, 0x93));
    try std.testing.expectEqual(@as(u21, 0xE9), unicodeOf(.mac_roman, 0x8E));
    try std.testing.expectEqual(@as(u21, 0x2019), unicodeOf(.standard, 0x27));
    try std.testing.expectEqual(@as(u21, 0xFB01), unicodeOf(.standard, 0xAE));
    try std.testing.expectEqual(@as(u21, 0), unicodeOf(.standard, 0x80));
    try std.testing.expectEqual(@as(u21, 0), unicodeOf(.win_ansi, 0x05));
}

test "standard_encoding table" {
    try std.testing.expectEqual(@as(u21, 'A'), standard_encoding['A']);
    try std.testing.expectEqual(@as(u21, 0xFB01), standard_encoding[0xAE]);
    try std.testing.expectEqual(@as(u21, 0), standard_encoding[0x80]);
}

test "glyph names" {
    try std.testing.expectEqual(@as(?u21, 'A'), unicodeOfName("A"));
    try std.testing.expectEqual(@as(?u21, 0xE9), unicodeOfName("eacute"));
    try std.testing.expectEqual(@as(?u21, 0xFB01), unicodeOfName("fi"));
    try std.testing.expectEqual(@as(?u21, 'a'), unicodeOfName("a.sc"));
    try std.testing.expectEqual(@as(?u21, 0x2603), unicodeOfName("uni2603"));
    try std.testing.expectEqual(@as(?u21, 0x1F600), unicodeOfName("u1F600"));
    try std.testing.expectEqual(@as(?u21, '0'), unicodeOfName("0")); // a glyph named by its character
    try std.testing.expectEqual(@as(?u21, 0x03B1), unicodeOfName("alpha")); // the full Adobe Glyph List
    try std.testing.expectEqual(@as(?u21, 0x0416), unicodeOfName("Zhecyrillic.alt"));
    try std.testing.expectEqual(@as(?u21, null), unicodeOfName("g123"));
    try std.testing.expectEqual(@as(?u21, null), unicodeOfName(".notdef"));
    try std.testing.expectEqualStrings("eacute", nameOfUnicode(0xE9).?);
}

test "every WinAnsi, MacRoman and Standard code with a value has a glyph name" {
    for ([_]Base{ .win_ansi, .mac_roman, .standard }) |b| {
        for (0..256) |c| {
            const u = unicodeOf(b, @intCast(c));
            if (u == 0 or u == 0x20 or u == 0xA0) continue;
            // Private-use apple (MacRoman 0xF0) is the only one without an AGL name here.
            if (nameOfUnicode(u) == null and u != 0xF8FF) {
                std.debug.print("no name for U+{X:0>4} (base {s}, code {X})\n", .{ u, @tagName(b), c });
                return error.TestUnexpectedResult;
            }
        }
    }
}
