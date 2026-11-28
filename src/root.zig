// SPDX-License-Identifier: LGPL-2.0-or-later
//! pdf-zig: a PDF reader library built on `std.Io`.
//!
//! See docs/decisions/0001-architecture.md for scope and docs/architecture.md
//! for the layout of the code.

pub const object = @import("object.zig");
pub const filters = @import("filters.zig");
pub const document = @import("document.zig");
pub const crypt = @import("crypt.zig");
pub const pages = @import("pages.zig");
pub const content = @import("content.zig");
pub const encoding = @import("encoding.zig");
pub const agl = @import("agl.zig");
pub const cff_strings = @import("cff_strings.zig");
pub const cmap = @import("cmap.zig");
pub const font = @import("font.zig");
pub const function = @import("function.zig");
pub const color = @import("color.zig");
pub const display = @import("display.zig");
pub const interp = @import("interp.zig");
pub const text = @import("text.zig");
pub const image = @import("image.zig");
pub const ccitt = @import("ccitt.zig");

pub const Renderer = interp.Renderer;
pub const DisplayList = display.DisplayList;

pub const Document = document.Document;
pub const Options = document.Options;
pub const write = @import("write.zig");
pub const annot = @import("annot.zig");
pub const outline = @import("outline.zig");
pub const link = @import("link.zig");
pub const flatten = @import("flatten.zig");
pub const appearance = @import("appearance.zig");
pub const compose = @import("compose.zig");
pub const draw = @import("draw.zig");
pub const truetype = @import("truetype.zig");
pub const form = @import("form.zig");
pub const signature = @import("signature.zig");
pub const Object = object.Object;
pub const Dict = object.Dict;
pub const Ref = object.Ref;
pub const Stream = object.Stream;

test {
    _ = @import("object.zig");
    _ = @import("spans.zig");
    _ = @import("filters.zig");
    _ = @import("document.zig");
    _ = @import("crypt.zig");
    _ = @import("crypt_tests.zig");
    _ = @import("pages.zig");
    _ = @import("content.zig");
    _ = @import("encoding.zig");
    _ = @import("agl.zig");
    _ = @import("cmap.zig");
    _ = @import("font.zig");
    _ = @import("function.zig");
    _ = @import("color.zig");
    _ = @import("display.zig");
    _ = @import("interp.zig");
    _ = @import("text.zig");
    _ = @import("write.zig");
    _ = @import("annot.zig");
    _ = @import("outline.zig");
    _ = @import("link.zig");
    _ = @import("flatten.zig");
    _ = @import("flatten_tests.zig");
    _ = @import("appearance.zig");
    _ = @import("appearance_tests.zig");
    _ = @import("compose.zig");
    _ = @import("draw.zig");
    _ = @import("truetype.zig");
    _ = @import("truetype_tests.zig");
    _ = @import("form_font_tests.zig");
    _ = @import("signature.zig");
    _ = @import("signature_tests.zig");
    _ = @import("font_embed.zig");
    _ = @import("page_edit.zig");
    _ = @import("draw_tests.zig");
    _ = @import("compose_form.zig");
    _ = @import("compose_outline.zig");
    _ = @import("compose_pack.zig");
    _ = @import("compose_tests.zig");
    _ = @import("form.zig");
    _ = @import("image.zig");
    _ = @import("ccitt.zig");
    _ = @import("image_tests.zig");
    _ = @import("interp_tests.zig");
    _ = @import("doc_tests.zig");
}

test "CFF standard strings" {
    // Adobe Technical Note 5176, appendix A.
    try @import("std").testing.expectEqual(@as(usize, 391), cff_strings.std_strings.len);
    try @import("std").testing.expectEqualStrings("twodotenleader", cff_strings.std_strings[237]);
    try @import("std").testing.expectEqualStrings(".notdef", cff_strings.std_strings[0]);
    try @import("std").testing.expectEqualStrings("Semibold", cff_strings.std_strings[390]);
}
