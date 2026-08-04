const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const common = @import("common.zig");
const gpu = @import("gpu.zig");
const compat = @import("compat");
const report_netstatic = @import("report_netstatic");

var sample_mutex: compat.Mutex = .{};
var previous_cpu: ?CpuTimes = null;
var previous_network: ?NetworkSample = null;
const unknown_cpu_physical_cores = std.math.maxInt(u32);
var cached_cpu_physical_cores = std.atomic.Value(u32).init(unknown_cpu_physical_cores);

const FILETIME = extern struct {
    dwLowDateTime: windows.DWORD,
    dwHighDateTime: windows.DWORD,
};

const MEMORYSTATUSEX = extern struct {
    dwLength: windows.DWORD,
    dwMemoryLoad: windows.DWORD,
    ullTotalPhys: u64,
    ullAvailPhys: u64,
    ullTotalPageFile: u64,
    ullAvailPageFile: u64,
    ullTotalVirtual: u64,
    ullAvailVirtual: u64,
    ullAvailExtendedVirtual: u64,
};

const ULARGE_INTEGER = extern union {
    QuadPart: u64,
    Parts: extern struct {
        LowPart: windows.DWORD,
        HighPart: windows.DWORD,
    },
};

const PROCESSENTRY32W = extern struct {
    dwSize: windows.DWORD,
    cntUsage: windows.DWORD,
    th32ProcessID: windows.DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: windows.DWORD,
    cntThreads: windows.DWORD,
    th32ParentProcessID: windows.DWORD,
    pcPriClassBase: i32,
    dwFlags: windows.DWORD,
    szExeFile: [260]u16,
};

const MIB_IF_ROW2 = extern struct {
    InterfaceLuid: u64,
    InterfaceIndex: u32,
    InterfaceGuid: windows.GUID,
    Alias: [257]u16,
    Description: [257]u16,
    PhysicalAddressLength: u32,
    PhysicalAddress: [32]u8,
    PermanentPhysicalAddress: [32]u8,
    Mtu: u32,
    Type: u32,
    TunnelType: u32,
    MediaType: u32,
    PhysicalMediumType: u32,
    AccessType: u32,
    DirectionType: u32,
    InterfaceAndOperStatusFlags: u8,
    OperStatus: u32,
    AdminStatus: u32,
    MediaConnectState: u32,
    NetworkGuid: windows.GUID,
    ConnectionType: u32,
    TransmitLinkSpeed: u64,
    ReceiveLinkSpeed: u64,
    InOctets: u64,
    InUcastPkts: u64,
    InNUcastPkts: u64,
    InDiscards: u64,
    InErrors: u64,
    InUnknownProtos: u64,
    InUcastOctets: u64,
    InMulticastOctets: u64,
    InBroadcastOctets: u64,
    OutOctets: u64,
    OutUcastPkts: u64,
    OutNUcastPkts: u64,
    OutDiscards: u64,
    OutErrors: u64,
    OutUcastOctets: u64,
    OutMulticastOctets: u64,
    OutBroadcastOctets: u64,
    OutQLen: u64,
};

const MIB_IF_TABLE2 = extern struct {
    NumEntries: windows.DWORD,
    Table: [1]MIB_IF_ROW2,
};

const SOCKET_ADDRESS = extern struct {
    lpSockaddr: ?*std.c.sockaddr,
    iSockaddrLength: i32,
};

const IP_ADAPTER_UNICAST_ADDRESS_LH = extern struct {
    Alignment: u64,
    Next: ?*IP_ADAPTER_UNICAST_ADDRESS_LH,
    Address: SOCKET_ADDRESS,
    PrefixOrigin: u32,
    SuffixOrigin: u32,
    DadState: u32,
    ValidLifetime: u32,
    PreferredLifetime: u32,
    LeaseLifetime: u32,
    OnLinkPrefixLength: u8,
};

const IP_ADAPTER_ADDRESSES_LH = extern struct {
    Alignment: u64,
    Next: ?*IP_ADAPTER_ADDRESSES_LH,
    AdapterName: ?[*:0]u8,
    FirstUnicastAddress: ?*IP_ADAPTER_UNICAST_ADDRESS_LH,
    FirstAnycastAddress: ?*anyopaque,
    FirstMulticastAddress: ?*anyopaque,
    FirstDnsServerAddress: ?*anyopaque,
    DnsSuffix: ?[*:0]u16,
    Description: ?[*:0]u16,
    FriendlyName: ?[*:0]u16,
    PhysicalAddress: [8]u8,
    PhysicalAddressLength: u32,
    Flags: u32,
    Mtu: u32,
    IfType: u32,
    OperStatus: u32,
    Ipv6IfIndex: u32,
    ZoneIndices: [16]u32,
    FirstPrefix: ?*anyopaque,
};

const CpuTimes = struct {
    idle: u64,
    total: u64,
};

const NetworkSample = struct {
    total_up: u64,
    total_down: u64,
    timestamp_ms: i64,
    include_nics: []const u8,
    exclude_nics: []const u8,
};

const InterfaceCounter = struct {
    name: []const u8,
    in_octets: u64,
    out_octets: u64,
};

const TH32CS_SNAPPROCESS: windows.DWORD = 0x00000002;
const DRIVE_FIXED: windows.DWORD = 3;
const KEY_QUERY_VALUE: u32 = 0x0001;
const REG_SZ: windows.DWORD = 1;
const REG_EXPAND_SZ: windows.DWORD = 2;
const REG_DWORD: windows.DWORD = 4;
const AF_UNSPEC: u32 = 0;
const AF_INET: u32 = 2;
const AF_INET6: u32 = 23;
const ERROR_BUFFER_OVERFLOW: windows.DWORD = 111;
const ERROR_INSUFFICIENT_BUFFER: windows.DWORD = 122;
const IF_TYPE_SOFTWARE_LOOPBACK: u32 = 24;
const NET_IF_ACCESS_LOOPBACK: u32 = 1;
const IF_OPER_STATUS_UP: u32 = 1;
const IF_ROW_FILTER_INTERFACE: u8 = 0x02;
const TCP_TABLE_OWNER_PID_ALL: u32 = 5;
const UDP_TABLE_OWNER_PID: u32 = 1;

const current_version_key = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
const cpu_key = "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0";

extern "kernel32" fn GetSystemTimes(
    lpIdleTime: *FILETIME,
    lpKernelTime: *FILETIME,
    lpUserTime: *FILETIME,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

extern "kernel32" fn GetLogicalDrives() callconv(.winapi) windows.DWORD;

extern "kernel32" fn GetDriveTypeW(lpRootPathName: [*:0]const u16) callconv(.winapi) windows.DWORD;

extern "kernel32" fn GetDiskFreeSpaceExW(
    lpDirectoryName: [*:0]const u16,
    lpFreeBytesAvailableToCaller: ?*ULARGE_INTEGER,
    lpTotalNumberOfBytes: ?*ULARGE_INTEGER,
    lpTotalNumberOfFreeBytes: ?*ULARGE_INTEGER,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetVolumeInformationW(
    lpRootPathName: [*:0]const u16,
    lpVolumeNameBuffer: ?[*]u16,
    nVolumeNameSize: windows.DWORD,
    lpVolumeSerialNumber: ?*windows.DWORD,
    lpMaximumComponentLength: ?*windows.DWORD,
    lpFileSystemFlags: ?*windows.DWORD,
    lpFileSystemNameBuffer: ?[*]u16,
    nFileSystemNameSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreateToolhelp32Snapshot(
    dwFlags: windows.DWORD,
    th32ProcessID: windows.DWORD,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn Process32FirstW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn Process32NextW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;

extern "advapi32" fn RegOpenKeyExW(
    hKey: windows.HKEY,
    lpSubKey: [*:0]const u16,
    ulOptions: windows.DWORD,
    samDesired: u32,
    phkResult: *windows.HKEY,
) callconv(.winapi) i32;

extern "advapi32" fn RegQueryValueExW(
    hKey: windows.HKEY,
    lpValueName: [*:0]const u16,
    lpReserved: ?*windows.DWORD,
    lpType: ?*windows.DWORD,
    lpData: ?[*]u8,
    lpcbData: *windows.DWORD,
) callconv(.winapi) i32;

extern "advapi32" fn RegCloseKey(hKey: windows.HKEY) callconv(.winapi) i32;

extern "iphlpapi" fn GetIfTable2(table: *?*MIB_IF_TABLE2) callconv(.winapi) windows.DWORD;

extern "iphlpapi" fn FreeMibTable(memory: *anyopaque) callconv(.winapi) void;

extern "iphlpapi" fn GetExtendedTcpTable(
    table: ?*anyopaque,
    size: *windows.DWORD,
    order: windows.BOOL,
    family: u32,
    table_class: u32,
    reserved: u32,
) callconv(.winapi) windows.DWORD;

extern "iphlpapi" fn GetExtendedUdpTable(
    table: ?*anyopaque,
    size: *windows.DWORD,
    order: windows.BOOL,
    family: u32,
    table_class: u32,
    reserved: u32,
) callconv(.winapi) windows.DWORD;

extern "iphlpapi" fn GetAdaptersAddresses(
    family: u32,
    flags: u32,
    reserved: ?*anyopaque,
    adapter_addresses: ?*IP_ADAPTER_ADDRESSES_LH,
    size_pointer: *windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub fn basicInfo(allocator: std.mem.Allocator) !common.BasicInfo {
    const ram = memInfo() catch common.MemInfo{};
    const swap = swapInfo() catch common.MemInfo{};
    const disk = diskInfoWithMountpoints(allocator, "") catch common.DiskInfo{};
    var info = common.BasicInfo{
        .cpu = .{
            .name = cpuName(allocator) catch "Unknown",
            .architecture = normalizeArch(@tagName(builtin.cpu.arch)),
            .cores = cpuCoreCount(),
            .physical_cores = cpuPhysicalCoreCount(allocator) catch 0,
            .usage = 0.001,
        },
        .os_name = osName(allocator) catch "Microsoft Windows",
        .kernel_version = kernelVersion(allocator) catch "",
        .mem_total = ram.total,
        .swap_total = swap.total,
        .disk_total = disk.total,
        .gpu_name = gpuName(allocator) catch "None",
        .virtualization = virtualization(allocator) catch "none",
    };
    fillLocalIp(allocator, &info);
    return info;
}

pub fn snapshot(options: common.SnapshotOptions) !common.Snapshot {
    return .{
        .cpu = .{
            .architecture = normalizeArch(@tagName(builtin.cpu.arch)),
            .cores = cpuCoreCount(),
            .usage = cpuUsage() catch 0.001,
        },
        .ram = memInfo() catch .{},
        .swap = swapInfo() catch .{},
        .load = .{},
        .disk = diskInfoWithMountpoints(std.heap.page_allocator, options.include_mountpoints) catch .{},
        .network = networkInfo(options) catch .{},
        .connections = connectionsInfo() catch .{},
        .uptime = uptime(),
        .process = processCount() catch 0,
        .gpu_json = if (options.enable_gpu) detailedGpuJson(std.heap.page_allocator) catch "" else "",
        .message = "",
    };
}

pub fn diskList(allocator: std.mem.Allocator) ![]common.DiskMount {
    var list: std.ArrayList(common.DiskMount) = .empty;
    const drives = GetLogicalDrives();
    var index: u8 = 0;
    while (index < 26) : (index += 1) {
        if ((drives & (@as(windows.DWORD, 1) << @as(u5, @intCast(index)))) == 0) continue;
        const root = driveRoot(index);
        if (GetDriveTypeW(&root) != DRIVE_FIXED) continue;
        try list.append(allocator, .{
            .mountpoint = try std.fmt.allocPrint(allocator, "{c}:\\", .{'A' + index}),
            .fstype = fsTypeForRoot(allocator, &root) catch try allocator.dupe(u8, "unknown"),
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn monitoringDiskList(allocator: std.mem.Allocator, include_mountpoints: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (include_mountpoints.len != 0) {
        var mounts = std.mem.splitScalar(u8, include_mountpoints, ';');
        while (mounts.next()) |raw| {
            const mountpoint = std.mem.trim(u8, raw, " \t\r\n");
            if (mountpoint.len != 0) try out.append(allocator, try allocator.dupe(u8, mountpoint));
        }
        return out.toOwnedSlice(allocator);
    }
    const disks = try diskList(allocator);
    defer freeDiskMounts(allocator, disks);
    for (disks) |disk| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s} ({s})", .{ disk.mountpoint, disk.fstype }));
    }
    return out.toOwnedSlice(allocator);
}

pub fn interfaceList(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) ![]const []const u8 {
    const counters = try collectInterfaceCounters(allocator);
    defer freeInterfaceCounters(allocator, counters);

    var out: std.ArrayList([]const u8) = .empty;
    for (counters) |counter| {
        if (!shouldIncludeInterface(counter.name, include_nics, exclude_nics)) continue;
        try out.append(allocator, try allocator.dupe(u8, counter.name));
    }
    return out.toOwnedSlice(allocator);
}

pub fn localIpFromInterfaces(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) !common.LocalIpInfo {
    return detectLocalIpFromInterfaces(allocator, include_nics, exclude_nics);
}

pub fn canProbeIpv6(_: std.mem.Allocator, _: []const u8, _: []const u8) !bool {
    return true;
}

pub fn normalizeArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return "amd64";
    if (std.mem.eql(u8, arch, "aarch64")) return "arm64";
    if (std.mem.eql(u8, arch, "x86")) return "386";
    if (std.mem.eql(u8, arch, "i386")) return "386";
    if (std.mem.eql(u8, arch, "arm")) return "arm";
    if (std.mem.eql(u8, arch, "loongarch64")) return "loong64";
    return arch;
}

fn cpuCoreCount() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

fn cpuPhysicalCoreCount(allocator: std.mem.Allocator) !u32 {
    const cached = cached_cpu_physical_cores.load(.acquire);
    if (cached != unknown_cpu_physical_cores) return cached;

    const output = runPowerShell(
        allocator,
        "Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | ForEach-Object { $_.NumberOfCores }",
        16 * 1024,
    ) catch {
        cached_cpu_physical_cores.store(0, .release);
        return 0;
    };
    defer allocator.free(output);

    var total: u32 = 0;
    var saw_value = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const value = std.fmt.parseInt(u32, line, 10) catch continue;
        if (value == 0) continue;
        total = total +| value;
        saw_value = true;
    }

    const result: u32 = if (saw_value) total else 0;
    cached_cpu_physical_cores.store(result, .release);
    return result;
}

fn cpuName(allocator: std.mem.Allocator) ![]const u8 {
    return readRegistryStringValue(allocator, cpu_key, "ProcessorNameString");
}

fn osName(allocator: std.mem.Allocator) ![]const u8 {
    const product = try readRegistryStringValue(allocator, current_version_key, "ProductName");
    defer allocator.free(product);
    const build = currentBuildNumber(allocator) catch 0;
    return normalizeWindowsProductName(allocator, product, build);
}

fn kernelVersion(allocator: std.mem.Allocator) ![]const u8 {
    const build = try readRegistryStringValue(allocator, current_version_key, "CurrentBuild");
    errdefer allocator.free(build);
    const ubr = readRegistryDwordValue(allocator, current_version_key, "UBR") catch return build;
    return std.fmt.allocPrint(allocator, "{s}.{d}", .{ build, ubr });
}

fn currentBuildNumber(allocator: std.mem.Allocator) !u32 {
    const build = try readRegistryStringValue(allocator, current_version_key, "CurrentBuild");
    defer allocator.free(build);
    return std.fmt.parseInt(u32, std.mem.trim(u8, build, " \t\r\n"), 10);
}

fn normalizeWindowsProductName(allocator: std.mem.Allocator, product_name: []const u8, build_number: u32) ![]const u8 {
    if (std.mem.indexOf(u8, product_name, "Server") != null) return allocator.dupe(u8, product_name);
    if (std.mem.indexOf(u8, product_name, "Windows 11") != null) return allocator.dupe(u8, product_name);
    if (build_number < 22000) return allocator.dupe(u8, product_name);

    if (std.mem.startsWith(u8, product_name, "Windows 10 ")) {
        return std.fmt.allocPrint(allocator, "Windows 11 {s}", .{product_name["Windows 10 ".len..]});
    }
    if (std.mem.eql(u8, product_name, "Windows 10")) {
        return allocator.dupe(u8, "Windows 11");
    }
    if (std.mem.indexOf(u8, product_name, "Windows 10")) |idx| {
        return std.fmt.allocPrint(allocator, "{s}Windows 11{s}", .{ product_name[0..idx], product_name[idx + "Windows 10".len ..] });
    }
    return allocator.dupe(u8, product_name);
}

fn cpuUsage() !f64 {
    const current = try systemCpuTimes();

    sample_mutex.lock();
    defer sample_mutex.unlock();

    const usage = if (previous_cpu) |previous| cpuUsagePercent(previous, current) else 0.001;
    previous_cpu = current;
    return if (usage <= 0.001) 0.001 else usage;
}

fn systemCpuTimes() !CpuTimes {
    var idle: FILETIME = undefined;
    var kernel: FILETIME = undefined;
    var user: FILETIME = undefined;
    if (GetSystemTimes(&idle, &kernel, &user) == .FALSE) return error.WinApiFailed;
    const idle_value = fileTimeToU64(idle);
    const kernel_value = fileTimeToU64(kernel);
    const user_value = fileTimeToU64(user);
    return .{
        .idle = idle_value,
        .total = kernel_value + user_value,
    };
}

fn cpuUsagePercent(previous: CpuTimes, current: CpuTimes) f64 {
    if (current.total <= previous.total or current.idle < previous.idle) return 0.001;
    const total_delta = current.total - previous.total;
    const idle_delta = current.idle - previous.idle;
    if (total_delta == 0 or total_delta < idle_delta) return 0.001;
    return (@as(f64, @floatFromInt(total_delta - idle_delta)) / @as(f64, @floatFromInt(total_delta))) * 100.0;
}

fn fileTimeToU64(value: FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

fn memInfo() !common.MemInfo {
    const status = try memoryStatus();
    return .{
        .total = status.ullTotalPhys,
        .used = if (status.ullTotalPhys >= status.ullAvailPhys) status.ullTotalPhys - status.ullAvailPhys else 0,
    };
}

fn swapInfo() !common.MemInfo {
    const status = try memoryStatus();
    const total = if (status.ullTotalPageFile > status.ullTotalPhys) status.ullTotalPageFile - status.ullTotalPhys else 0;
    const available = if (status.ullAvailPageFile > status.ullAvailPhys) status.ullAvailPageFile - status.ullAvailPhys else 0;
    return .{
        .total = total,
        .used = if (total >= available) total - available else 0,
    };
}

fn memoryStatus() !MEMORYSTATUSEX {
    var status = std.mem.zeroes(MEMORYSTATUSEX);
    status.dwLength = @sizeOf(MEMORYSTATUSEX);
    if (GlobalMemoryStatusEx(&status) == .FALSE) return error.WinApiFailed;
    return status;
}

fn diskInfoWithMountpoints(allocator: std.mem.Allocator, include_mountpoints: []const u8) !common.DiskInfo {
    if (include_mountpoints.len != 0) {
        var total = common.DiskInfo{};
        var mounts = std.mem.splitScalar(u8, include_mountpoints, ';');
        while (mounts.next()) |raw_mount| {
            const mountpoint = std.mem.trim(u8, raw_mount, " \t\r\n");
            if (mountpoint.len == 0) continue;
            const usage = diskUsageForPath(allocator, mountpoint) catch continue;
            total.total += usage.total;
            total.used += usage.used;
        }
        return total;
    }

    var total = common.DiskInfo{};
    const drives = GetLogicalDrives();
    var index: u8 = 0;
    while (index < 26) : (index += 1) {
        if ((drives & (@as(windows.DWORD, 1) << @as(u5, @intCast(index)))) == 0) continue;
        const root = driveRoot(index);
        if (GetDriveTypeW(&root) != DRIVE_FIXED) continue;
        const usage = diskUsageForRoot(&root) catch continue;
        total.total += usage.total;
        total.used += usage.used;
    }
    return total;
}

fn diskUsageForPath(allocator: std.mem.Allocator, path: []const u8) !common.DiskInfo {
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
    defer allocator.free(path_w);
    return diskUsageForRoot(path_w);
}

fn diskUsageForRoot(root: [:0]const u16) !common.DiskInfo {
    var total_bytes = ULARGE_INTEGER{ .QuadPart = 0 };
    var free_bytes = ULARGE_INTEGER{ .QuadPart = 0 };
    if (GetDiskFreeSpaceExW(root.ptr, null, &total_bytes, &free_bytes) == .FALSE) return error.WinApiFailed;
    return .{
        .total = total_bytes.QuadPart,
        .used = if (total_bytes.QuadPart >= free_bytes.QuadPart) total_bytes.QuadPart - free_bytes.QuadPart else 0,
    };
}

fn fsTypeForRoot(allocator: std.mem.Allocator, root: [:0]const u16) ![]const u8 {
    var fs_name: [64]u16 = std.mem.zeroes([64]u16);
    if (GetVolumeInformationW(root.ptr, null, 0, null, null, null, &fs_name, fs_name.len) == .FALSE) return error.WinApiFailed;
    const end = std.mem.indexOfScalar(u16, &fs_name, 0) orelse fs_name.len;
    return std.unicode.utf16LeToUtf8Alloc(allocator, fs_name[0..end]);
}

fn networkInfo(options: common.SnapshotOptions) !common.NetworkInfo {
    const counters = try collectInterfaceCounters(std.heap.page_allocator);
    defer freeInterfaceCounters(std.heap.page_allocator, counters);

    var current = common.NetworkInfo{};
    for (counters) |counter| {
        if (!shouldIncludeInterface(counter.name, options.include_nics, options.exclude_nics)) continue;
        current.totalUp += counter.out_octets;
        current.totalDown += counter.in_octets;
    }

    const now_ms = compat.milliTimestamp();
    sample_mutex.lock();
    defer sample_mutex.unlock();

    if (previous_network) |previous| {
        if (networkSampleMatches(previous, options)) {
            const elapsed_ms: u64 = @intCast(@max(now_ms - previous.timestamp_ms, 0));
            current.up = perSecond(current.totalUp, previous.total_up, elapsed_ms);
            current.down = perSecond(current.totalDown, previous.total_down, elapsed_ms);
        }
    }
    previous_network = .{
        .total_up = current.totalUp,
        .total_down = current.totalDown,
        .timestamp_ms = now_ms,
        .include_nics = options.include_nics,
        .exclude_nics = options.exclude_nics,
    };

    if (options.month_rotate != 0) {
        const totals = report_netstatic.applyMonthlyTotalsFiltered(std.heap.page_allocator, options.month_rotate, options.include_nics, options.exclude_nics);
        current.totalUp = totals.up;
        current.totalDown = totals.down;
    }
    return current;
}

fn networkSampleMatches(sample: NetworkSample, options: common.SnapshotOptions) bool {
    return std.mem.eql(u8, sample.include_nics, options.include_nics) and
        std.mem.eql(u8, sample.exclude_nics, options.exclude_nics);
}

fn perSecond(current: u64, previous: u64, elapsed_ms: u64) u64 {
    if (elapsed_ms == 0 or current < previous) return 0;
    return ((current - previous) * 1000) / elapsed_ms;
}

fn collectInterfaceCounters(allocator: std.mem.Allocator) ![]InterfaceCounter {
    var table_ptr: ?*MIB_IF_TABLE2 = null;
    if (GetIfTable2(&table_ptr) != 0 or table_ptr == null) return error.WinApiFailed;
    defer FreeMibTable(@ptrCast(table_ptr.?));

    const table = table_ptr.?;
    const rows: [*]const MIB_IF_ROW2 = @ptrCast(&table.Table[0]);
    var out: std.ArrayList(InterfaceCounter) = .empty;

    for (0..table.NumEntries) |i| {
        const row = rows[i];
        const name = interfaceName(allocator, row) catch continue;
        if (name.len == 0) {
            allocator.free(name);
            continue;
        }
        if (isLoopbackInterface(row, name)) {
            allocator.free(name);
            continue;
        }
        try out.append(allocator, .{
            .name = name,
            .in_octets = row.InOctets,
            .out_octets = row.OutOctets,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn interfaceName(allocator: std.mem.Allocator, row: MIB_IF_ROW2) ![]const u8 {
    const alias_end = utf16BufLen(&row.Alias);
    if (alias_end != 0) return std.unicode.utf16LeToUtf8Alloc(allocator, row.Alias[0..alias_end]);
    const desc_end = utf16BufLen(&row.Description);
    if (desc_end != 0) return std.unicode.utf16LeToUtf8Alloc(allocator, row.Description[0..desc_end]);
    return allocator.dupe(u8, "");
}

fn utf16BufLen(buf: []const u16) usize {
    return std.mem.indexOfScalar(u16, buf, 0) orelse buf.len;
}

fn isLoopbackInterface(row: MIB_IF_ROW2, name: []const u8) bool {
    if (row.OperStatus != IF_OPER_STATUS_UP) return true;
    if ((row.InterfaceAndOperStatusFlags & IF_ROW_FILTER_INTERFACE) != 0) return true;
    if (row.Type == IF_TYPE_SOFTWARE_LOOPBACK) return true;
    if (row.AccessType == NET_IF_ACCESS_LOOPBACK) return true;
    return std.ascii.indexOfIgnoreCase(name, "loopback") != null;
}

fn freeInterfaceCounters(allocator: std.mem.Allocator, counters: []InterfaceCounter) void {
    for (counters) |counter| allocator.free(counter.name);
    allocator.free(counters);
}

fn connectionsInfo() !common.ConnectionInfo {
    return .{
        .tcp = try tcpConnectionCount(),
        .udp = try udpConnectionCount(),
    };
}

fn tcpConnectionCount() !u64 {
    return try extendedTableCount(.tcp, AF_INET, TCP_TABLE_OWNER_PID_ALL) +
        try extendedTableCount(.tcp, AF_INET6, TCP_TABLE_OWNER_PID_ALL);
}

fn udpConnectionCount() !u64 {
    return try extendedTableCount(.udp, AF_INET, UDP_TABLE_OWNER_PID) +
        try extendedTableCount(.udp, AF_INET6, UDP_TABLE_OWNER_PID);
}

const TableKind = enum { tcp, udp };

fn extendedTableCount(kind: TableKind, family: u32, table_class: u32) !u64 {
    var size: windows.DWORD = 0;
    const first = switch (kind) {
        .tcp => GetExtendedTcpTable(null, &size, .FALSE, family, table_class, 0),
        .udp => GetExtendedUdpTable(null, &size, .FALSE, family, table_class, 0),
    };
    if (first != 0 and first != ERROR_INSUFFICIENT_BUFFER) return error.WinApiFailed;
    if (size < @sizeOf(windows.DWORD)) return 0;

    const buf = try std.heap.page_allocator.alloc(u8, size);
    defer std.heap.page_allocator.free(buf);

    var actual_size = size;
    const rc = switch (kind) {
        .tcp => GetExtendedTcpTable(buf.ptr, &actual_size, .FALSE, family, table_class, 0),
        .udp => GetExtendedUdpTable(buf.ptr, &actual_size, .FALSE, family, table_class, 0),
    };
    if (rc != 0 or actual_size < @sizeOf(windows.DWORD)) return error.WinApiFailed;
    return std.mem.readInt(u32, buf[0..4], .little);
}

fn processCount() !u64 {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == windows.INVALID_HANDLE_VALUE) return error.WinApiFailed;
    defer _ = CloseHandle(snap);

    var entry = std.mem.zeroes(PROCESSENTRY32W);
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == .FALSE) return 0;

    var count: u64 = 0;
    while (true) {
        count += 1;
        if (Process32NextW(snap, &entry) == .FALSE) break;
    }
    return count;
}

fn uptime() u64 {
    return GetTickCount64() / std.time.ms_per_s;
}

fn gpuName(allocator: std.mem.Allocator) ![]const u8 {
    const output = try runPowerShell(
        allocator,
        "Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }",
        128 * 1024,
    );
    defer allocator.free(output);
    return gpu.allocOutputNames(allocator, .{ .output = output, .empty_name = "None" });
}

fn detailedGpuJson(allocator: std.mem.Allocator) ![]const u8 {
    const output = try runPowerShell(
        allocator,
        "& nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu," ++
            "temperature.gpu --format=csv,noheader,nounits 2>$null",
        256 * 1024,
    );
    defer allocator.free(output);
    return gpu.allocNvidiaDetailedJson(allocator, output);
}

fn virtualization(allocator: std.mem.Allocator) ![]const u8 {
    const output = try runPowerShell(
        allocator,
        "$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue; if ($cs) { \"$($cs.Manufacturer)|$($cs.Model)\" }",
        32 * 1024,
    );
    defer allocator.free(output);

    const line = std.mem.trim(u8, output, " \t\r\n");
    if (line.len == 0) return allocator.dupe(u8, "none");

    const sep = std.mem.indexOfScalar(u8, line, '|') orelse return allocator.dupe(u8, "none");
    const manufacturer = std.mem.trim(u8, line[0..sep], " \t");
    const model = std.mem.trim(u8, line[sep + 1 ..], " \t");

    if (containsIgnoreCase(manufacturer, "vmware") or containsIgnoreCase(model, "vmware")) return allocator.dupe(u8, "vmware");
    if (containsIgnoreCase(manufacturer, "microsoft") and (containsIgnoreCase(model, "virtual") or containsIgnoreCase(model, "hyper-v"))) return allocator.dupe(u8, "microsoft");
    if (containsIgnoreCase(manufacturer, "oracle") or containsIgnoreCase(manufacturer, "innotek") or containsIgnoreCase(model, "virtualbox")) return allocator.dupe(u8, "oracle");
    if (containsIgnoreCase(manufacturer, "qemu") or containsIgnoreCase(model, "qemu")) return allocator.dupe(u8, "qemu");
    if (containsIgnoreCase(manufacturer, "kvm") or containsIgnoreCase(model, "kvm")) return allocator.dupe(u8, "kvm");
    if (containsIgnoreCase(manufacturer, "xen") or containsIgnoreCase(model, "xen") or containsIgnoreCase(model, "domu")) return allocator.dupe(u8, "xen");
    if (containsIgnoreCase(manufacturer, "parallels") or containsIgnoreCase(model, "parallels")) return allocator.dupe(u8, "parallels");
    if (containsIgnoreCase(model, "virtual")) return allocator.dupe(u8, "virtualized");
    return allocator.dupe(u8, "none");
}

fn readRegistryStringValue(allocator: std.mem.Allocator, subkey: []const u8, value_name: []const u8) ![]const u8 {
    const subkey_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, subkey);
    defer allocator.free(subkey_w);
    const value_name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, value_name);
    defer allocator.free(value_name_w);

    var key: windows.HKEY = undefined;
    if (RegOpenKeyExW(windows.HKEY_LOCAL_MACHINE, subkey_w.ptr, 0, KEY_QUERY_VALUE, &key) != 0) {
        return error.RegistryOpenFailed;
    }
    defer _ = RegCloseKey(key);

    var value_type: windows.DWORD = 0;
    var size: windows.DWORD = 0;
    if (RegQueryValueExW(key, value_name_w.ptr, null, &value_type, null, &size) != 0) return error.RegistryReadFailed;
    if (value_type != REG_SZ and value_type != REG_EXPAND_SZ) return error.RegistryBadType;

    const word_count: usize = @intCast((size + 1) / 2);
    const words = try allocator.alloc(u16, word_count);
    defer allocator.free(words);

    var read_size = size;
    if (RegQueryValueExW(key, value_name_w.ptr, null, &value_type, @ptrCast(words.ptr), &read_size) != 0) {
        return error.RegistryReadFailed;
    }

    var utf16_len: usize = @intCast(read_size / 2);
    if (utf16_len != 0 and words[utf16_len - 1] == 0) utf16_len -= 1;
    return std.unicode.utf16LeToUtf8Alloc(allocator, words[0..utf16_len]);
}

fn readRegistryDwordValue(allocator: std.mem.Allocator, subkey: []const u8, value_name: []const u8) !u32 {
    const subkey_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, subkey);
    defer allocator.free(subkey_w);
    const value_name_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, value_name);
    defer allocator.free(value_name_w);

    var key: windows.HKEY = undefined;
    if (RegOpenKeyExW(windows.HKEY_LOCAL_MACHINE, subkey_w.ptr, 0, KEY_QUERY_VALUE, &key) != 0) {
        return error.RegistryOpenFailed;
    }
    defer _ = RegCloseKey(key);

    var value_type: windows.DWORD = 0;
    var value: u32 = 0;
    var size: windows.DWORD = @sizeOf(u32);
    if (RegQueryValueExW(key, value_name_w.ptr, null, &value_type, @ptrCast(&value), &size) != 0) return error.RegistryReadFailed;
    if (value_type != REG_DWORD or size != @sizeOf(u32)) return error.RegistryBadType;
    return value;
}

fn fillLocalIp(allocator: std.mem.Allocator, info: *common.BasicInfo) void {
    const local = detectLocalIpFromInterfaces(allocator, "", "") catch detectHostLocalIp(allocator) catch return;
    info.ipv4 = local.ipv4;
    info.ipv6 = local.ipv6;
}

fn detectLocalIpFromInterfaces(allocator: std.mem.Allocator, include_nics: []const u8, exclude_nics: []const u8) !common.LocalIpInfo {
    const work_allocator = std.heap.page_allocator;
    var ipv4: []const u8 = "";
    var ipv6: []const u8 = "";

    var size: windows.DWORD = 16 * 1024;
    var buf = try work_allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(@alignOf(IP_ADAPTER_ADDRESSES_LH)), size);
    defer work_allocator.free(buf);

    while (true) {
        const rc = GetAdaptersAddresses(AF_UNSPEC, 0, null, @ptrCast(buf.ptr), &size);
        if (rc == 0) break;
        if (rc != ERROR_BUFFER_OVERFLOW) return error.WinApiFailed;
        work_allocator.free(buf);
        buf = try work_allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(@alignOf(IP_ADAPTER_ADDRESSES_LH)), size);
    }

    var adapter: ?*IP_ADAPTER_ADDRESSES_LH = @ptrCast(buf.ptr);
    while (adapter) |current| : (adapter = current.Next) {
        const nic_name = adapterFriendlyName(allocator, current) catch continue;
        defer allocator.free(nic_name);
        if (!shouldIncludeInterface(nic_name, include_nics, exclude_nics)) continue;

        var unicast = current.FirstUnicastAddress;
        while (unicast) |entry| : (unicast = entry.Next) {
            const sockaddr = entry.Address.lpSockaddr orelse continue;
            const ip = formatSocketIp(allocator, sockaddr) catch continue;
            errdefer allocator.free(ip);

            if (ipv4.len == 0 and isUsableIpv4(ip)) {
                ipv4 = ip;
                continue;
            }
            if (ipv6.len == 0 and isUsableIpv6(ip)) {
                ipv6 = ip;
                continue;
            }
            allocator.free(ip);
        }
    }

    if (ipv4.len == 0 and ipv6.len == 0) return error.NoLocalIpFound;
    return .{ .ipv4 = ipv4, .ipv6 = ipv6 };
}

fn adapterFriendlyName(allocator: std.mem.Allocator, adapter: *const IP_ADAPTER_ADDRESSES_LH) ![]const u8 {
    const friendly = adapter.FriendlyName orelse return allocator.dupe(u8, "");
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(friendly));
}

fn formatSocketIp(allocator: std.mem.Allocator, sockaddr: *const std.c.sockaddr) ![]const u8 {
    return switch (sockaddr.family) {
        AF_INET => blk: {
            const sa4: *const std.c.sockaddr.in = @ptrCast(@alignCast(sockaddr));
            const bytes: *const [4]u8 = @ptrCast(&sa4.addr);
            break :blk std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
        },
        AF_INET6 => blk: {
            const sa6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(sockaddr));
            var buf: [96]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const ip: std.Io.net.IpAddress = .{ .ip6 = .{ .bytes = sa6.addr, .port = 0 } };
            try ip.format(&writer);
            const formatted = writer.buffered();
            if (std.mem.startsWith(u8, formatted, "[") and std.mem.endsWith(u8, formatted, "]:0")) {
                break :blk allocator.dupe(u8, formatted[1 .. formatted.len - 3]);
            }
            break :blk allocator.dupe(u8, formatted);
        },
        else => error.UnsupportedAddressFamily,
    };
}

fn detectHostLocalIp(allocator: std.mem.Allocator) !common.LocalIpInfo {
    const output = try runPowerShell(
        allocator,
        "[System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | ForEach-Object { $_.IPAddressToString }",
        64 * 1024,
    );
    defer allocator.free(output);

    var ipv4: []const u8 = "";
    var ipv6: []const u8 = "";
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (ipv4.len == 0 and isUsableIpv4(line)) {
            ipv4 = try allocator.dupe(u8, line);
            continue;
        }
        if (ipv6.len == 0 and isUsableIpv6(line)) {
            ipv6 = try allocator.dupe(u8, line);
        }
    }
    return .{ .ipv4 = ipv4, .ipv6 = ipv6 };
}

fn shouldIncludeInterface(name: []const u8, include_nics: []const u8, exclude_nics: []const u8) bool {
    const excluded_prefixes = [_][]const u8{ "br", "cni", "docker", "podman", "flannel", "lo", "veth", "virbr", "vmbr", "tap", "fwbr", "fwpr" };
    for (&excluded_prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(name, prefix)) return false;
    }
    if (std.ascii.indexOfIgnoreCase(name, "loopback") != null) return false;
    if (include_nics.len != 0) return csvMatches(include_nics, name);
    if (exclude_nics.len != 0 and csvMatches(exclude_nics, name)) return false;
    return true;
}

fn csvMatches(csv: []const u8, needle: []const u8) bool {
    var it = std.mem.splitAny(u8, csv, ",;");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, needle)) return true;
        if (globMatch(trimmed, needle)) return true;
    }
    return false;
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, value);
    return std.mem.startsWith(u8, value, pattern[0..star]) and std.mem.endsWith(u8, value, pattern[star + 1 ..]);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn isUsableIpv4(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '.') == null) return false;
    if (std.mem.startsWith(u8, value, "127.")) return false;
    if (std.mem.startsWith(u8, value, "169.254.")) return false;
    return true;
}

fn isUsableIpv6(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, ':') == null) return false;
    if (std.ascii.eqlIgnoreCase(value, "::1")) return false;
    if (std.ascii.startsWithIgnoreCase(value, "fe80:")) return false;
    return true;
}

fn runPowerShell(allocator: std.mem.Allocator, script: []const u8, limit: usize) ![]u8 {
    const work_allocator = std.heap.page_allocator;
    const wrapped = try std.fmt.allocPrint(
        work_allocator,
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; {s}",
        .{script},
    );
    defer work_allocator.free(wrapped);

    const result = try compat.runOutputWindows(
        work_allocator,
        &.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", wrapped },
        limit,
    );
    if (result.term != .exited or result.term.exited != 0) {
        work_allocator.free(result.stdout);
        return error.CommandFailed;
    }
    defer work_allocator.free(result.stdout);
    return allocator.dupe(u8, result.stdout);
}

fn driveRoot(index: u8) [4:0]u16 {
    return .{ @as(u16, 'A') + index, ':', '\\', 0 };
}

fn freeDiskMounts(allocator: std.mem.Allocator, disks: []common.DiskMount) void {
    for (disks) |disk| {
        allocator.free(disk.mountpoint);
        allocator.free(disk.fstype);
    }
    allocator.free(disks);
}
