//! Generic filesystem abstraction.
//!
//! `Fs` is a vtable over "read this file by path", so FAT today and EXT4 (or
//! anything else) tomorrow plug into the boot manager the same way without the
//! manager knowing which filesystem it is talking to.

pub const Fs = struct {
    ctx: *anyopaque,
    /// Read the whole file at `path` into `buf`. Returns bytes read, or null if
    /// the path was not found, was not a regular file, or did not fit in `buf`.
    /// Path separators may be '/' or '\\'.
    read_file: *const fn (ctx: *anyopaque, path: []const u8, buf: []u8) ?usize,

    pub fn readFile(self: *const Fs, path: []const u8, buf: []u8) ?usize {
        return self.read_file(self.ctx, path, buf);
    }
};
