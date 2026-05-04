/// Default terminal configuration matching node-pty behavior.
const std = @import("std");
const builtin = @import("builtin");

/// Configure termios with sane defaults matching node-pty.
pub fn configure(term: *std.c.termios, use_utf8: bool) void {
    if (builtin.os.tag == .linux) {
        configureLinux(@ptrCast(term), use_utf8);
    } else if (builtin.os.tag == .macos) {
        configureDarwin(@ptrCast(term));
    }
}

fn configureLinux(term: *std.os.linux.termios, use_utf8: bool) void {
    const V = std.os.linux.V;

    // Input flags
    term.iflag = .{
        .BRKINT = true,
        .ICRNL = true,
        .IXON = true,
        .IXANY = true,
        .IMAXBEL = true,
        .IUTF8 = use_utf8,
    };

    // Output flags
    term.oflag = .{ .OPOST = true, .ONLCR = true };

    // Control flags
    term.cflag = .{ .CREAD = true, .HUPCL = true, .CSIZE = .CS8 };

    // Local flags
    term.lflag = .{
        .ECHO = true,
        .ECHOE = true,
        .ECHOK = true,
        .ECHOKE = true,
        .ECHOCTL = true,
        .ISIG = true,
        .ICANON = true,
        .IEXTEN = true,
    };

    // Baud rate. Some Linux ABIs such as MIPS keep speeds in cflag instead of
    // exposing dedicated ispeed/ospeed fields in Zig's termios definition.
    if (@hasField(std.os.linux.termios, "ispeed")) {
        term.ispeed = .B38400;
        term.ospeed = .B38400;
    }

    // Special characters
    term.cc[@intFromEnum(V.INTR)] = 0x03; // Ctrl-C
    term.cc[@intFromEnum(V.QUIT)] = 0x1c; // Ctrl-backslash
    term.cc[@intFromEnum(V.ERASE)] = 0x7f; // DEL
    term.cc[@intFromEnum(V.KILL)] = 0x15; // Ctrl-U
    term.cc[@intFromEnum(V.EOF)] = 0x04; // Ctrl-D
    term.cc[@intFromEnum(V.START)] = 0x11; // Ctrl-Q (XON)
    term.cc[@intFromEnum(V.STOP)] = 0x13; // Ctrl-S (XOFF)
    term.cc[@intFromEnum(V.SUSP)] = 0x1a; // Ctrl-Z
    term.cc[@intFromEnum(V.REPRINT)] = 0x12; // Ctrl-R
    term.cc[@intFromEnum(V.WERASE)] = 0x17; // Ctrl-W
    term.cc[@intFromEnum(V.LNEXT)] = 0x16; // Ctrl-V
    term.cc[@intFromEnum(V.DISCARD)] = 0x0f; // Ctrl-O
    term.cc[@intFromEnum(V.MIN)] = 1;
    term.cc[@intFromEnum(V.TIME)] = 0;
}

fn configureDarwin(term: *std.c.termios) void {
    const V = std.c.V;

    // Input flags
    term.iflag = .{
        .BRKINT = true,
        .ICRNL = true,
        .IXON = true,
        .IXANY = true,
        .IMAXBEL = true,
    };

    // Output flags
    term.oflag = .{ .OPOST = true, .ONLCR = true };

    // Control flags
    term.cflag = .{ .CREAD = true, .HUPCL = true, .CSIZE = .CS8 };

    // Local flags
    term.lflag = .{
        .ECHO = true,
        .ECHOE = true,
        .ECHOK = true,
        .ECHOKE = true,
        .ECHOCTL = true,
        .ISIG = true,
        .ICANON = true,
        .IEXTEN = true,
    };

    // Baud rate
    term.ispeed = .B38400;
    term.ospeed = .B38400;

    // Special characters
    term.cc[@intFromEnum(V.INTR)] = 0x03; // Ctrl-C
    term.cc[@intFromEnum(V.QUIT)] = 0x1c; // Ctrl-backslash
    term.cc[@intFromEnum(V.ERASE)] = 0x7f; // DEL
    term.cc[@intFromEnum(V.KILL)] = 0x15; // Ctrl-U
    term.cc[@intFromEnum(V.EOF)] = 0x04; // Ctrl-D
    term.cc[@intFromEnum(V.START)] = 0x11; // Ctrl-Q (XON)
    term.cc[@intFromEnum(V.STOP)] = 0x13; // Ctrl-S (XOFF)
    term.cc[@intFromEnum(V.SUSP)] = 0x1a; // Ctrl-Z
    term.cc[@intFromEnum(V.REPRINT)] = 0x12; // Ctrl-R
    term.cc[@intFromEnum(V.WERASE)] = 0x17; // Ctrl-W
    term.cc[@intFromEnum(V.LNEXT)] = 0x16; // Ctrl-V
    term.cc[@intFromEnum(V.DISCARD)] = 0x0f; // Ctrl-O
    term.cc[@intFromEnum(V.MIN)] = 1;
    term.cc[@intFromEnum(V.TIME)] = 0;
    // macOS-only special characters
    term.cc[@intFromEnum(V.DSUSP)] = 0x19; // Ctrl-Y (delayed suspend)
    term.cc[@intFromEnum(V.STATUS)] = 0x14; // Ctrl-T (status)
}
