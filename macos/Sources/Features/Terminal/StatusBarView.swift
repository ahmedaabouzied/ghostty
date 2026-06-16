import SwiftUI

final class StatusBarModel: ObservableObject {
    @Published var clock: String = ""

    private var timer: Timer?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        tick()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        clock = timeFormatter.string(from: Date())
    }
}

struct StatusBarView: View {
    @StateObject private var model = StatusBarModel()

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Text(model.clock)
                .monospacedDigit()
            Spacer()
        }
        .font(.system(size: 11))
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        // your background + a top divider — style this part yourself
    }
}
