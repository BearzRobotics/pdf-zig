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
pub const form = @import("form.zig");
pub const Object = object.Object;
pub const Dict = object.Dict;
pub const Ref = object.Ref;
pub const Stream = object.Stream;

test {
    _ = @import("object.zig");
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
    _ = @import("form.zig");
    _ = @import("image.zig");
    _ = @import("ccitt.zig");
    _ = @import("image_tests.zig");
    _ = @import("interp_tests.zig");
    _ = @import("doc_tests.zig");
}
