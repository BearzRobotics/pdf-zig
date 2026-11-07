//! pdf-zig: a PDF reader library built on `std.Io`.
//!
//! See docs/decisions/0001-architecture.md for scope and docs/architecture.md
//! for the layout of the code.

pub const object = @import("object.zig");
pub const filters = @import("filters.zig");
pub const document = @import("document.zig");
pub const pages = @import("pages.zig");

pub const Document = document.Document;
pub const Options = document.Options;
pub const Object = object.Object;
pub const Dict = object.Dict;
pub const Ref = object.Ref;
pub const Stream = object.Stream;

test {
    _ = @import("object.zig");
    _ = @import("filters.zig");
    _ = @import("document.zig");
    _ = @import("pages.zig");
    _ = @import("doc_tests.zig");
}
