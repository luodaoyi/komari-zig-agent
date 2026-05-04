const std = @import("std");
const runtime = @import("runtime");

const fs = @import("compat/fs.zig");
const process = @import("compat/process.zig");
const posix = @import("compat/posix.zig");
const sync = @import("compat/sync.zig");
const time = @import("compat/time.zig");
const format = @import("compat/format.zig");

/// Compatibility facade kept stable while internals move to Zig 0.16 modules.
pub const Mutex = sync.Mutex;

pub fn currentEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return runtime.currentEnvMap(allocator);
}

pub fn emptyEnvMap(allocator: std.mem.Allocator) std.process.Environ.Map {
    return .init(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return runtime.getEnvVarOwned(allocator, key);
}

pub const readFileAlloc = fs.readFileAlloc;
pub const selfExePathAlloc = fs.selfExePathAlloc;
pub const statFile = fs.statFile;
pub const openFile = fs.openFile;
pub const openFileAbsolute = fs.openFileAbsolute;
pub const createFileAbsolute = fs.createFileAbsolute;
pub const openDir = fs.openDir;
pub const renameAbsolute = fs.renameAbsolute;
pub const deleteFileAbsolute = fs.deleteFileAbsolute;
pub const copyFileAbsolute = fs.copyFileAbsolute;
pub const private_file_permissions = fs.private_file_permissions;
pub const executable_file_permissions = fs.executable_file_permissions;
pub const readLinkAbsolute = fs.readLinkAbsolute;
pub const FileWriter = fs.FileWriter;
pub const fileWriter = fs.fileWriter;
pub const readAll = fs.readAll;

pub const closeFd = posix.closeFd;
pub const pipe = posix.pipe;
pub const socket = posix.socket;
pub const sendTo = posix.sendTo;
pub const recvFrom = posix.recvFrom;
pub const fork = posix.fork;
pub const dup2 = posix.dup2;
pub const execveZ = posix.execveZ;
pub const WaitPidResult = posix.WaitPidResult;
pub const waitPid = posix.waitPid;
pub const setsid = posix.setsid;

pub const RunOutputResult = process.RunOutputResult;
pub const runOutputIgnoreStderr = process.runOutputIgnoreStderr;
pub const runIgnoreOutput = process.runIgnoreOutput;

pub const sleep = time.sleep;
pub const unixTimestamp = time.unixTimestamp;
pub const milliTimestamp = time.milliTimestamp;
pub const nanoTimestamp = time.nanoTimestamp;

pub const appendPrint = format.appendPrint;
