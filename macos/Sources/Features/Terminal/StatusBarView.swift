import SwiftUI
import Darwin
import IOKit.ps

final class StatusBarModel: ObservableObject {
    @Published var clock: String = ""
    @Published var load: String = ""
    @Published var memory: String = ""
    @Published var battery: String?     // nil when there's no battery (desktops) -> hidden
    @Published var thermal: String = ""

    private var timer: Timer?

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
        memory = memoryUsedString()
        battery = batteryString()
        thermal = thermalString()
    }

    // MARK: - Stats

    /// 1-minute load average via the libc call. No struct/pointer ceremony.
    private func loadAverageString() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return "—" }
        return String(format: "%.2f", loads[0])
    }

    /// Percentage of physical RAM in use (active + wired + compressed), via the
    /// mach kernel. The counts come back in pages, so we multiply by the page size.
    private func memoryUsedString() -> String {
        let host = mach_host_self()

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return "—" }

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
        guard kr == KERN_SUCCESS else { return "—" }

        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let used = usedPages * UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return "—" }
        return String(format: "%.0f%%", Double(used) / Double(total) * 100)
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

    /// System thermal pressure.
    private func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "OK"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "—"
        }
    }
}

struct StatusBarView: View {
    @StateObject private var model = StatusBarModel()

    var body: some View {
        HStack(spacing: 14) {
            Label(model.clock, systemImage: "clock")
            separator
            Label(model.load, systemImage: "speedometer")
            separator
            Label(model.memory, systemImage: "memorychip")
            if let battery = model.battery {
                separator
                Label(battery, systemImage: "battery.100")
            }
            separator
            Label(model.thermal, systemImage: "thermometer.medium")
            Spacer()
        }
        .font(.system(size: 13))
        .monospacedDigit()          // fixed-width digits so the bar doesn't twitch
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)      // option B: bar height grows with the font, no clipping
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)           // material designed for status/toolbars; adapts to light/dark
        .overlay(alignment: .top) { Divider() }
    }

    private var separator: some View {
        Divider().frame(height: 12)
    }
}
