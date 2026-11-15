//! The board identity, from the zon file `-Dboard-info` names.

const options = @import("build_options");

pub const BoardInfo = @import("smbios/board_info.zig").BoardInfo;

/// With no file, every field has its default.
pub const info: BoardInfo = if (options.has_board_info) @import("board_info") else .{};
