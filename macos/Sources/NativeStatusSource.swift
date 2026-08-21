//
//  NativeStatusSource.swift
//  Burrow
//
//  A fail-safe status snapshot built entirely from macOS APIs. The dashboard must never
//  depend on an optional CLI sidecar merely to show that the Mac is alive. The bundled
//  engine remains the richer source; this source is used only when that engine (and any
//  system mo fallback) cannot produce a valid snapshot.
//


import Darwin
import Foundation

struct NativeStatusSource: StatusSource {
    func statusJSON() throws -> String {
        let cpu = NativeStatusMetrics.cpu()
        let memory = NativeStatusMetrics.memory()
        let disk = NativeStatusMetrics.rootDisk()
        let allProcesses = ProcessSampler.sample()
        let processes = allProcesses.prefix(12).map { process in
            var row: [String: Any] = [
                "pid": process.pid,
                "name": process.name,
                "command": process.command,
                "cpu": process.cpu,
                "memory": process.memory,
            ]
            if let ppid = process.ppid { row["ppid"] = ppid }
            if let bytes = process.memoryBytes { row["memory_bytes"] = bytes }
            return row
        }

        let pressurePercent = MemoryPressure.percent()
        let pressure: String
        switch pressurePercent {
        case 80...: pressure = "critical"
        case 60...: pressure = "warning"
        default: pressure = "normal"
        }

        let cpuPenalty = max(0, Int(cpu.usage - 70) / 3)
        let memoryPenalty = max(0, pressurePercent - 60) / 2
        let diskPenalty = max(0, Int(disk.usedPercent - 85))
        let healthScore = max(0, 100 - cpuPenalty - memoryPenalty - diskPenalty)

        let object: [String: Any] = [
            "collected_at": NativeStatusMetrics.timestamp(),
            "host": Host.current().localizedName ?? Foundation.ProcessInfo.processInfo.hostName,
            "platform": "macOS",
            "uptime_seconds": UInt64(max(0, Foundation.ProcessInfo.processInfo.systemUptime)),
            "procs": allProcesses.count,
            "hardware": [
                "model": NativeStatusMetrics.sysctlString("hw.model") ?? "Mac",
                "cpu_model": NativeStatusMetrics.cpuModel,
                "total_ram": NativeStatusMetrics.formatBytes(memory.total),
                "disk_size": NativeStatusMetrics.formatBytes(disk.total),
                "os_version": Foundation.ProcessInfo.processInfo.operatingSystemVersionString,
            ],
            "health_score": healthScore,
            "health_score_msg": "Native macOS status",
            "cpu": [
                "usage": cpu.usage,
                "per_core": [],
                "load1": cpu.loads[0],
                "load5": cpu.loads[1],
                "load15": cpu.loads[2],
                "core_count": Foundation.ProcessInfo.processInfo.processorCount,
                "logical_cpu": Foundation.ProcessInfo.processInfo.activeProcessorCount,
            ],
            "memory": [
                "used": memory.used,
                "total": memory.total,
                "available": memory.available,
                "cached": memory.cached,
                "used_percent": memory.usedPercent,
                "swap_used": memory.swapUsed,
                "swap_total": memory.swapTotal,
                "pressure": pressure,
            ],
            "disk_io": ["read_rate": 0.0, "write_rate": 0.0],
            "disks": [[
                "mount": "/",
                "used": disk.used,
                "total": disk.total,
                "used_percent": disk.usedPercent,
                "external": false,
            ]],
            "network": [],
            "thermal": [
                "cpu_temp": 0.0,
                "gpu_temp": 0.0,
                "fan_speed": 0,
                "fan_count": 0,
                "system_power": 0.0,
            ],
            "top_processes": processes,
            "gpu": [[
                "name": "Integrated GPU",
                "usage": -1.0,
                "memory_used": 0,
                "memory_total": 0,
                "core_count": 0,
                "note": "Native fallback",
            ]],
        ]

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Burrow.NativeStatus", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "native status JSON was not UTF-8",
            ])
        }
        return json
    }
}

private enum NativeStatusMetrics {
    struct CPU {
        let usage: Double
        let loads: [Double]
    }

    struct Memory {
        let used: UInt64
        let total: UInt64
        let available: UInt64
        let cached: UInt64
        let usedPercent: Double
        let swapUsed: UInt64
        let swapTotal: UInt64
    }

    struct Disk {
        let used: UInt64
        let total: UInt64
        let usedPercent: Double
    }

    private static let cpuLock = NSLock()
    private static var previousCPUTicks: (busy: UInt64, total: UInt64)?

    static func cpu() -> CPU {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, Int32(load.count))

        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride /
                                           MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            let cores = max(1, Foundation.ProcessInfo.processInfo.activeProcessorCount)
            return CPU(usage: min(100, max(0, load[0] / Double(cores) * 100)), loads: load)
        }

        let ticks = withUnsafeBytes(of: info.cpu_ticks) { raw in
            Array(raw.bindMemory(to: UInt32.self)).map(UInt64.init)
        }
        guard ticks.count >= Int(CPU_STATE_MAX) else { return CPU(usage: 0, loads: load) }
        let idle = ticks[Int(CPU_STATE_IDLE)]
        let total = ticks.reduce(0, +)
        let busy = total >= idle ? total - idle : 0

        cpuLock.lock()
        let previous = previousCPUTicks
        previousCPUTicks = (busy, total)
        cpuLock.unlock()

        if let previous, total > previous.total, busy >= previous.busy {
            let deltaTotal = total - previous.total
            let deltaBusy = busy - previous.busy
            return CPU(usage: min(100, Double(deltaBusy) / Double(deltaTotal) * 100), loads: load)
        }
        let cores = max(1, Foundation.ProcessInfo.processInfo.activeProcessorCount)
        return CPU(usage: min(100, max(0, load[0] / Double(cores) * 100)), loads: load)
    }

    static func memory() -> Memory {
        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        _ = sysctlbyname("hw.memsize", &total, &totalSize, nil, 0)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride /
                                           MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let page = UInt64(vm_page_size)
        let used: UInt64
        let cached: UInt64
        if result == KERN_SUCCESS {
            used = (UInt64(stats.active_count) + UInt64(stats.wire_count) +
                    UInt64(stats.compressor_page_count)) * page
            cached = UInt64(stats.inactive_count) * page
        } else {
            used = 0
            cached = 0
        }
        let boundedUsed = min(used, total)
        let available = total >= boundedUsed ? total - boundedUsed : 0

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        return Memory(
            used: boundedUsed,
            total: total,
            available: available,
            cached: cached,
            usedPercent: total > 0 ? Double(boundedUsed) / Double(total) * 100 : 0,
            swapUsed: hasSwap ? swap.xsu_used : 0,
            swapTotal: hasSwap ? swap.xsu_total : 0)
    }

    static func rootDisk() -> Disk {
        let url = URL(fileURLWithPath: "/", isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        let values = try? url.resourceValues(forKeys: keys)
        let total = UInt64(max(0, values?.volumeTotalCapacity ?? 0))
        let availableValue = values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
        let available = UInt64(max(0, availableValue))
        let used = total >= available ? total - available : 0
        return Disk(used: used, total: total,
                    usedPercent: total > 0 ? Double(used) / Double(total) * 100 : 0)
    }

    static var cpuModel: String {
        sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? "Apple Silicon"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
