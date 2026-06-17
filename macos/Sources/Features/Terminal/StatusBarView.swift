import SwiftUI
import Darwin
import IOKit.ps

final class StatusBarModel: ObservableObject {
    @Published var clock: String = ""
    @Published var load: String = ""
    @Published var perCore: [Double] = []       // 0...100 per CPU core
    @Published var memoryPercent: Double = 0    // 0...100
    @Published var diskPercent: Double = 0      // 0...100 (used)
    @Published var network: String = ""         // "↓ x ↑ y"
    @Published var uptime: String = ""
    @Published var battery: String?             // nil when there's no battery (desktops) -> hidden
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    private var timer: Timer?

    // Cumulative-since-boot counters: keep the previous sample to report a delta.
    private var previousCoreTicks: [[UInt32]]?
    private var previousNet: (inBytes: UInt64, outBytes: UInt64)?
    private var previousNetTime: Date?

    // Built once; formatters are expensive to create and tick() runs every second.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let byteRateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file            // decimal (1000) — network convention
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()
    private let uptimeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    init() {
        tick()  // seed immediately so the bar isn't blank for the first second
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common mode so the bar keeps ticking during window drag/resize.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        clock = timeFormatter.string(from: Date())
        load = loadAverageString()
        perCore = perCoreUsage()
        memoryPercent = memoryUsedPercent()
        diskPercent = diskUsedPercent()
        network = networkRateString()
        uptime = uptimeFormatter.string(from: ProcessInfo.processInfo.systemUptime) ?? "—"
        battery = batteryString()
        thermalState = ProcessInfo.processInfo.thermalState
    }

    // MARK: - Stats

    /// 1-minute load average via the libc call. No struct/pointer ceremony.
    private func loadAverageString() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return "—" }
        return String(format: "%.2f", loads[0])
    }

    /// Per-core CPU usage %. Ticks are cumulative since boot, so we diff against
    /// the previous sample. The kernel hands us a heap buffer we must free.
    private func perCoreUsage() -> [Double] {
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let kr = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &infoCount)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return perCore }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)  // user, system, idle, nice
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * states
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }

        defer { previousCoreTicks = current }
        guard let prev = previousCoreTicks, prev.count == current.count else {
            return Array(repeating: 0, count: current.count)  // first sample: no delta
        }

        return current.indices.map { i in
            let c = current[i], p = prev[i]
            let busy = Double((c[0] &- p[0]) + (c[1] &- p[1]) + (c[3] &- p[3]))  // user+system+nice
            let total = busy + Double(c[2] &- p[2])                              // + idle
            return total > 0 ? min(100, max(0, busy / total * 100)) : 0
        }
    }

    /// Percentage of physical RAM in use (active + wired + compressed), via the
    /// mach kernel. The counts come back in pages, so we multiply by the page size.
    private func memoryUsedPercent() -> Double {
        let host = mach_host_self()

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return memoryPercent }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(host, host_flavor_t(HOST_VM_INFO64), reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return memoryPercent }

        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let used = usedPages * UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return memoryPercent }
        return min(100, max(0, Double(used) / Double(total) * 100))
    }

    /// Used percentage of the boot volume.
    private func diskUsedPercent() -> Double {
        let url = URL(fileURLWithPath: "/")
        guard
            let vals = try? url.resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = vals.volumeTotalCapacity, total > 0
        else { return diskPercent }
        let available = Double(vals.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = Double(total) - available
        return min(100, max(0, used / Double(total) * 100))
    }

    /// Network throughput (down/up) since the last tick. Byte counters are
    /// cumulative, so we diff against the previous sample over elapsed time.
    private func networkRateString() -> String {
        guard let cur = networkBytes() else { return network }
        let now = Date()
        defer { previousNet = cur; previousNetTime = now }
        guard let prev = previousNet, let prevTime = previousNetTime else { return "↓ 0 ↑ 0" }

        let elapsed = now.timeIntervalSince(prevTime)
        guard elapsed > 0 else { return network }
        // Guard against counter wrap (cur < prev): treat as 0 for that interval.
        let down = cur.inBytes >= prev.inBytes ? Double(cur.inBytes - prev.inBytes) / elapsed : 0
        let up = cur.outBytes >= prev.outBytes ? Double(cur.outBytes - prev.outBytes) / elapsed : 0
        return "↓ \(byteRate(down)) ↑ \(byteRate(up))"
    }

    private func byteRate(_ bytesPerSecond: Double) -> String {
        byteRateFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// Sum of in/out bytes across real interfaces (AF_LINK, excluding loopback).
    private func networkBytes() -> (inBytes: UInt64, outBytes: UInt64)? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var cursor = addrs
        while let c = cursor {
            let ifa = c.pointee
            if let addr = ifa.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               !String(cString: ifa.ifa_name).hasPrefix("lo"),
               let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                totalIn += UInt64(data.pointee.ifi_ibytes)
                totalOut += UInt64(data.pointee.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }
        return (totalIn, totalOut)
    }

    /// Battery percentage (+ a bolt while charging), or nil on machines without a battery.
    private func batteryString() -> String? {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
            !sources.isEmpty
        else { return nil }

        for source in sources {
            guard
                let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                let current = desc[kIOPSCurrentCapacityKey] as? Int,
                let max = desc[kIOPSMaxCapacityKey] as? Int,
                max > 0
            else { continue }

            let pct = Int((Double(current) / Double(max) * 100).rounded())
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            return charging ? "\(pct)% ⚡" : "\(pct)%"
        }
        return nil
    }
}

// MARK: - Views

struct StatusBarView: View {
    @StateObject private var model = StatusBarModel()

    var body: some View {
        HStack(spacing: 14) {
            Label(model.clock, systemImage: "clock")
            separator
            Label(model.load, systemImage: "speedometer")
            separator
            PerCoreBars(values: model.perCore)
            separator
            StatBar(icon: "memorychip", value: model.memoryPercent)
            separator
            StatBar(icon: "internaldrive", value: model.diskPercent)
            separator
            Label(model.network, systemImage: "network")
            separator
            Label(model.uptime, systemImage: "power")
            if let battery = model.battery {
                separator
                Label(battery, systemImage: "battery.100")
            }
            separator
            ThermalIndicator(state: model.thermalState)
            Spacer()
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var separator: some View {
        Divider().frame(height: 12)
    }
}

private func loadColor(_ value: Double) -> Color {
    switch value {
    case ..<60: return .green
    case ..<85: return .yellow
    default: return .red
    }
}

/// htop-style segmented bar: discrete ticks, filled portion colored by load.
private struct StatBar: View {
    let icon: String
    let value: Double           // 0...100
    var segments: Int = 10

    private var filled: Int { Int((value / 100 * Double(segments)).rounded()) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            HStack(spacing: 1) {
                ForEach(0..<segments, id: \.self) { i in
                    Rectangle()
                        .fill(i < filled ? loadColor(value) : Color.secondary.opacity(0.25))
                        .frame(width: 4, height: 9)
                }
            }
            Text(String(format: "%.0f%%", value))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// A compact per-core "equalizer": one column per CPU core, filled bottom-up by load.
private struct PerCoreBars: View {
    let values: [Double]        // 0...100 per core
    private let height: CGFloat = 11

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 3, height: height)
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(loadColor(v))
                                .frame(width: 3, height: max(1, height * v / 100))
                        }
                }
            }
        }
    }
}

/// Thermal state as a color-coded dot (thermal state is categorical, not a fraction).
private struct ThermalIndicator: View {
    let state: ProcessInfo.ThermalState

    private var color: Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private var label: String {
        switch state {
        case .nominal: return "OK"
        case .fair: return "Fair"
        case .serious: return "Hot"
        case .critical: return "Crit"
        @unknown default: return "—"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
