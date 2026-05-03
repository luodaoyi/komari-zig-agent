/// Shared data models exchanged between platform collectors and protocol encoders.
pub const CpuInfo = struct {
    name: []const u8 = "Unknown",
    architecture: []const u8 = "unknown",
    cores: u32 = 1,
    usage: f64 = 0.001,
};

pub const MemInfo = struct {
    total: u64 = 0,
    used: u64 = 0,
};

pub const LoadInfo = struct {
    load1: f64 = 0,
    load5: f64 = 0,
    load15: f64 = 0,
};

pub const DiskInfo = struct {
    total: u64 = 0,
    used: u64 = 0,
};

pub const DiskMount = struct {
    mountpoint: []const u8,
    fstype: []const u8,
};

pub const SnapshotOptions = struct {
    include_nics: []const u8 = "",
    exclude_nics: []const u8 = "",
    include_mountpoints: []const u8 = "",
    month_rotate: i32 = 0,
    enable_gpu: bool = false,
    host_proc: []const u8 = "",
    memory_include_cache: bool = false,
    memory_report_raw_used: bool = false,
};

pub const NetworkInfo = struct {
    up: u64 = 0,
    down: u64 = 0,
    totalUp: u64 = 0,
    totalDown: u64 = 0,
};

pub const ConnectionInfo = struct {
    tcp: u64 = 0,
    udp: u64 = 0,
};

pub const BasicInfo = struct {
    cpu: CpuInfo = .{},
    os_name: []const u8 = "unknown",
    kernel_version: []const u8 = "",
    ipv4: []const u8 = "",
    ipv6: []const u8 = "",
    mem_total: u64 = 0,
    swap_total: u64 = 0,
    disk_total: u64 = 0,
    gpu_name: []const u8 = "",
    virtualization: []const u8 = "",
};

pub const LocalIpInfo = struct {
    ipv4: []const u8 = "",
    ipv6: []const u8 = "",
};

pub const Snapshot = struct {
    cpu: CpuInfo = .{},
    ram: MemInfo = .{},
    swap: MemInfo = .{},
    load: LoadInfo = .{},
    disk: DiskInfo = .{},
    network: NetworkInfo = .{},
    connections: ConnectionInfo = .{},
    uptime: u64 = 0,
    process: u64 = 0,
    gpu_json: []const u8 = "",
    message: []const u8 = "",
};
