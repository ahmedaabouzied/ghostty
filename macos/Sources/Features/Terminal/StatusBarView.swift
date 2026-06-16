import SwiftUI
import Darwin
import IOKit.ps

final class StatusBarModel: ObservableObject {
    @Published var clock: String = ""
    @Published var load: String = ""
    @Published var cpuPercent: Double = 0       // 0...100
    @Published var memoryPercent: Double = 0    // 0...100
    @Published var battery: String?             // nil when there's no battery (desktops) -> hidden
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    private var timer: Timer?

    // CPU ticks are cumulative since boot, so we keep the previous sample and
    // report the delta each tick. nil until the first sample is taken.
    private var previousCPUTicks: host_cpu_load_info_data_t?

    // Built once; formatters are expensive to create and tick() runs every second.
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
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
        cpuPercent = cpuUsagePercent()
        memoryPercent = memoryUsedPercent()
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

    /// Whole-machine CPU usage as a percentage. CPU ticks are cumulative since
    /// boot, so usage = busy delta / total delta between this tick and the last.
    private func cpuUsagePercent() -> Double {
        let host = mach_host_self()
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(host, host_flavor_t(HOST_CPU_LOAD_INFO), reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return cpuPercent }  // keep last value on failure

        // cpu_ticks tuple order: (user, system, idle, nice)
        defer { previousCPUTicks = info }
        guard let prev = previousCPUTicks else { return 0 }  // first sample: no delta yet

        let userD = Double(info.cpu_ticks.0) - Double(prev.cpu_ticks.0)
        let systemD = Double(info.cpu_ticks.1) - Double(prev.cpu_ticks.1)
        let idleD = Double(info.cpu_ticks.2) - Double(prev.cpu_ticks.2)
        let niceD = Double(info.cpu_ticks.3) - Double(prev.cpu_ticks.3)

        let busy = userD + systemD + niceD
        let total = busy + idleD
        guard total > 0 else { return cpuPercent }
        return min(100, max(0, busy / total * 100))
    }

    /// Percentage of physical RAM in use (active + wired + compressed), via the
    /// mach kernel. The counts come back in pages, so we multiply by the page size.
    private func memoryUsedPercent() -> Double {
        let host = mach_host_self()

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return memoryPercent }

        var stats = vm_statistics64_data_t()
        // HOST_VM_INFO64_COUNT isn't imported into Swift, so derive the count:
        // the struct, measured in units of integer_t.
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
            StatBar(icon: "cpu", value: model.cpuPercent)
            separator
            StatBar(icon: "memorychip", value: model.memoryPercent)
            if let battery = model.battery {
                separator
                Label(battery, systemImage: "battery.100")
            }
            separator
            ThermalIndicator(state: model.thermalState)
            Spacer()
        }
        .font(.system(size: 13))
        .monospacedDigit()          // fixed-width digits so the bar doesn't twitch
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)      // option B: height grows with the font, no clipping
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)           // material designed for status/toolbars; adapts to light/dark
        .overlay(alignment: .top) { Divider() }
    }

    private var separator: some View {
        Divider().frame(height: 12)
    }
}

/// htop-style segmented bar: discrete ticks, filled portion colored by load.
private struct StatBar: View {
    let icon: String
    let value: Double           // 0...100
    var segments: Int = 10

    private var filled: Int {
        Int((value / 100 * Double(segments)).rounded())
    }

    private var color: Color {
        switch value {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            HStack(spacing: 1) {
                ForEach(0..<segments, id: \.self) { i in
                    Rectangle()
                        .fill(i < filled ? color : Color.secondary.opacity(0.25))
                        .frame(width: 4, height: 9)
                }
            }
            Text(String(format: "%.0f%%", value))
                .frame(width: 34, alignment: .trailing)
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
