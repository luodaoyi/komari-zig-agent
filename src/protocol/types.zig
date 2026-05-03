const std = @import("std");

/// JSON field writers and payload shapes for Komari protocol messages.
pub const BasicInfoPayload = struct {
    cpu_name: []const u8,
    cpu_cores: u32,
    arch: []const u8,
    os: []const u8,
    kernel_version: []const u8,
    ipv4: []const u8,
    ipv6: []const u8,
    mem_total: u64,
    swap_total: u64,
    disk_total: u64,
    gpu_name: []const u8,
    virtualization: []const u8,
    version: []const u8,
};

pub const TaskResultPayload = struct {
    task_id: []const u8,
    result: []const u8,
    exit_code: i32,
    finished_at: []const u8,
};

pub const PingResultPayload = struct {
    task_id: u64,
    ping_type: []const u8,
    value: i64,
    finished_at: []const u8,
};

pub const AutoDiscoveryRequest = struct {
    key: []const u8,
};

pub const CpuReport = struct {
    usage: f64,
};

pub const MemoryReport = struct {
    total: u64,
    used: u64,
};

pub const LoadReport = struct {
    load1: f64,
    load5: f64,
    load15: f64,
};

pub const DiskReport = struct {
    total: u64,
    used: u64,
};

pub const NetworkReport = struct {
    up: u64,
    down: u64,
    totalUp: u64,
    totalDown: u64,
};

pub const ConnectionReport = struct {
    tcp: u64,
    udp: u64,
};

pub const ReportPayload = struct {
    cpu: CpuReport,
    ram: MemoryReport,
    swap: MemoryReport,
    load: LoadReport,
    disk: DiskReport,
    network: NetworkReport,
    connections: ConnectionReport,
    uptime: u64,
    process: u64,
    message: []const u8,
};

pub fn writeBasicInfoJson(writer: anytype, payload: BasicInfoPayload, include_kernel_version: bool) !void {
    try writer.writeAll("{");
    try writeField(writer, "cpu_name", payload.cpu_name, false);
    try writeIntField(writer, "cpu_cores", payload.cpu_cores, true);
    try writeField(writer, "arch", payload.arch, true);
    try writeField(writer, "os", payload.os, true);
    if (include_kernel_version) try writeField(writer, "kernel_version", payload.kernel_version, true);
    try writeField(writer, "ipv4", payload.ipv4, true);
    try writeField(writer, "ipv6", payload.ipv6, true);
    try writeIntField(writer, "mem_total", payload.mem_total, true);
    try writeIntField(writer, "swap_total", payload.swap_total, true);
    try writeIntField(writer, "disk_total", payload.disk_total, true);
    try writeField(writer, "gpu_name", payload.gpu_name, true);
    try writeField(writer, "virtualization", payload.virtualization, true);
    try writeField(writer, "version", payload.version, true);
    try writer.writeAll("}");
}

pub fn writeTaskResultJson(writer: anytype, payload: TaskResultPayload) !void {
    try writer.print("{f}", .{std.json.fmt(payload, .{})});
}

pub fn writePingResultJson(writer: anytype, payload: PingResultPayload) !void {
    try writer.writeAll("{\"type\":\"ping_result\",");
    try writeIntField(writer, "task_id", payload.task_id, false);
    try writeField(writer, "ping_type", payload.ping_type, true);
    try writeIntField(writer, "value", payload.value, true);
    try writeField(writer, "finished_at", payload.finished_at, true);
    try writer.writeAll("}");
}

pub fn writeAutoDiscoveryRequestJson(writer: anytype, payload: AutoDiscoveryRequest) !void {
    try writer.print("{f}", .{std.json.fmt(payload, .{})});
}

pub fn writeReportJson(writer: anytype, payload: ReportPayload) !void {
    try writer.print("{f}", .{std.json.fmt(payload, .{})});
}

fn writeField(writer: anytype, name: []const u8, value: []const u8, comma_before: bool) !void {
    if (comma_before) try writer.writeAll(",");
    try writer.print("{f}", .{std.json.fmt(name, .{})});
    try writer.writeAll(":");
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

fn writeIntField(writer: anytype, name: []const u8, value: anytype, comma_before: bool) !void {
    if (comma_before) try writer.writeAll(",");
    try writer.print("{f}", .{std.json.fmt(name, .{})});
    try writer.writeAll(":");
    try writer.print("{}", .{value});
}
