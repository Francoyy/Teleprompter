import SwiftUI
import UIKit
import Combine

// MARK: - AutoScrollController

final class AutoScrollController: ObservableObject {
    @Published var isAutoScrolling: Bool = false
    @Published var contentOffsetY: CGFloat = 0
    @Published var autoScrollSpeed: CGFloat = 1.8   // smaller = slower

    private var autoScrollTimer: Timer?
    var tickInterval: TimeInterval = 0.03

    // Limits for UI control (shown as 1–20)
    let minSpeed: CGFloat = 0.1   // shows as 1
    let maxSpeed: CGFloat = 3.0   // shows as 20
    let step: CGFloat = 0.1       // +/-1 in UI

    func toggle() {
        isAutoScrolling ? stop() : start()
    }

    func start() {
        guard !isAutoScrolling else { return }
        isAutoScrolling = true
        autoScrollTimer?.invalidate()

        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: tickInterval,
                                               repeats: true) { [weak self] _ in
            guard let self = self, self.isAutoScrolling else { return }

            // TELEPROMPTER DIRECTION:
            // Increase offset over time. The view will translate this into text moving UP.
            let next = self.contentOffsetY + self.autoScrollSpeed
            print("TICK: current=\(self.contentOffsetY) speed=\(self.autoScrollSpeed) -> next=\(next)")
            self.contentOffsetY = next
        }
        if let timer = autoScrollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("AutoScrollController.start() - tickInterval=\(tickInterval) speed=\(autoScrollSpeed)")
    }

    func stop() {
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        print("AutoScrollController.stop()")
    }

    func increaseSpeed() {
        autoScrollSpeed = min(maxSpeed, (autoScrollSpeed + step).rounded(toPlaces: 2))
        print("increaseSpeed -> \(autoScrollSpeed)")
    }

    func decreaseSpeed() {
        autoScrollSpeed = max(minSpeed, (autoScrollSpeed - step).rounded(toPlaces: 2))
        print("decreaseSpeed -> \(autoScrollSpeed)")
    }

    // Display value 1–20 for the UI
    var displaySpeed: Int {
        Int((autoScrollSpeed * 10).rounded())
    }

    deinit {
        autoScrollTimer?.invalidate()
        print("AutoScrollController deinit")
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let divisor = pow(10.0, CGFloat(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - AutoScrollView (Spacer-based, linear, consistent direction)

struct AutoScrollView<Content: View>: View {
    @Binding var contentOffsetY: CGFloat
    let isAutoScrolling: Bool
    let content: () -> Content

    /// Global scale for how fast things move.
    /// Larger = more movement; smaller = slower.
    private let pointsPerUnit: CGFloat = 0.3

    init(contentOffsetY: Binding<CGFloat>,
         isAutoScrolling: Bool,
         @ViewBuilder content: @escaping () -> Content) {
        self._contentOffsetY = contentOffsetY
        self.isAutoScrolling = isAutoScrolling
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // As contentOffsetY increases, this spacer SHRINKS,
                    // so the visible content moves UP (teleprompter behavior).
                    // Option A: start roughly in the middle of the screen
                    let topHeight = max(0, proxy.size.height * 0.1 - contentOffsetY * pointsPerUnit)

                    Color.clear
                        .frame(height: topHeight)

                    content()
                        .id("top")

                    Color.clear
                        .frame(height: proxy.size.height * 3)
                }
            }
        }
    }
}
