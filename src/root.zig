//! pdf-zig: a PDF reader library built on `std.Io`.
//!
//! See docs/decisions/0001-architecture.md for scope and docs/architecture.md
//! for the layout of the code.

pub const object = @import("object.zig");
pub const filters = @import("filters.zig");

test {
    _ = @import("object.zig");
    _ = @import("filters.zig");
}
