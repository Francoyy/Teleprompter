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

    init() {
        print("DEBUG: AutoScrollController init")
    }

    func toggle() {
        print("DEBUG: AutoScrollController toggle() called, current state: \(isAutoScrolling)")
        isAutoScrolling ? stop() : start()
    }

    func start() {
        print("DEBUG: AutoScrollController start() called")
        guard !isAutoScrolling else {
            print("DEBUG: Already auto-scrolling, returning")
            return
        }
        isAutoScrolling = true
        autoScrollTimer?.invalidate()

        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: tickInterval,
                                               repeats: true) { [weak self] _ in
            guard let self = self, self.isAutoScrolling else { return }

            // TELEPROMPTER DIRECTION:
            // Increase offset over time. The view will translate this into text moving UP.
            let next = self.contentOffsetY + self.autoScrollSpeed
            self.contentOffsetY = next
        }
        if let timer = autoScrollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        print("AutoScrollController.start() - tickInterval=\(tickInterval) speed=\(autoScrollSpeed)")
    }

    func stop() {
        print("DEBUG: AutoScrollController stop() called")
        guard isAutoScrolling else {
            print("DEBUG: Already stopped, returning")
            return
        }
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

// MARK: - AutoScrollView (Full-screen teleprompter)

struct AutoScrollView<Content: View>: View {
    @Binding var contentOffsetY: CGFloat
    let isAutoScrolling: Bool
    let content: () -> Content

    init(contentOffsetY: Binding<CGFloat>,
         isAutoScrolling: Bool,
         @ViewBuilder content: @escaping () -> Content) {
        self._contentOffsetY = contentOffsetY
        self.isAutoScrolling = isAutoScrolling
        self.content = content
        print("DEBUG: AutoScrollView init")
    }

    var body: some View {
        print("DEBUG: AutoScrollView body computed, contentOffsetY: \(contentOffsetY)")
        return GeometryReader { proxy in
            CustomScrollView(scrollOffset: $contentOffsetY, screenHeight: proxy.size.height) {
                VStack(spacing: 0) {
                    // Top spacer: always half screen height
                    // This keeps the first line of text in the middle
                    Color.clear
                        .frame(height: proxy.size.height * 0.5)
                        .id("top-spacer")

                    content()
                        .id("content")

                    // Bottom spacer to allow scrolling past the end
                    Color.clear
                        .frame(height: proxy.size.height * 2)
                        .id("bottom-spacer")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// Custom UIScrollView wrapper for precise control
struct CustomScrollView<Content: View>: UIViewRepresentable {
    @Binding var scrollOffset: CGFloat
    let screenHeight: CGFloat
    let content: () -> Content
    
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isScrollEnabled = true // Enable manual scrolling
        scrollView.delegate = context.coordinator
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never // Prevent auto-adjustment
        
        let hostingController = UIHostingController(rootView: content())
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        
        scrollView.addSubview(hostingController.view)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: scrollView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
        
        context.coordinator.hostingController = hostingController
        context.coordinator.scrollView = scrollView
        
        print("DEBUG: CustomScrollView makeUIView")
        return scrollView
    }
    
    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Update content and force layout first
        if let hostingController = context.coordinator.hostingController {
            hostingController.rootView = content()
            
            // FIX: Invalidate intrinsic content size to ensure the view resizes
            // to fit the new content (e.g., long pasted text).
            hostingController.view.invalidateIntrinsicContentSize()
            
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()
            
            // FIX: Removed manual assignment of scrollView.contentSize.
            // We rely on Auto Layout constraints (pinned edges) to calculate the
            // content size automatically. Manually setting it here was causing
            // the content to be clipped or centered incorrectly when the size
            // calculation happened before the view fully expanded.
        }
        
        // Only update scroll position if we're programmatically controlling it
        // (not during manual scrolling)
        if !context.coordinator.isManuallyScrolling {
            let targetY = scrollOffset
            
            if abs(scrollView.contentOffset.y - targetY) > 0.1 {
                print("DEBUG: [ScrollView] Setting scroll offset from \(scrollView.contentOffset.y) to \(targetY)")
                scrollView.contentOffset.y = targetY
                print("DEBUG: [ScrollView] After setting, actual offset: \(scrollView.contentOffset.y)")
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(scrollOffset: $scrollOffset)
    }
    
    class Coordinator: NSObject, UIScrollViewDelegate {
        var hostingController: UIHostingController<Content>?
        var scrollView: UIScrollView?
        var scrollOffset: Binding<CGFloat>
        var isManuallyScrolling = false
        
        init(scrollOffset: Binding<CGFloat>) {
            self.scrollOffset = scrollOffset
        }
        
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            print("DEBUG: [Manual Scroll] BEGIN - offset: \(scrollView.contentOffset.y)")
            print("DEBUG: [Manual Scroll] contentSize: \(scrollView.contentSize)")
            print("DEBUG: [Manual Scroll] bounds: \(scrollView.bounds)")
            isManuallyScrolling = true
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if isManuallyScrolling {
                print("DEBUG: [Manual Scroll] SCROLLING - offset: \(scrollView.contentOffset.y)")
            }
        }
        
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                print("DEBUG: [Manual Scroll] END (no decel) - offset: \(scrollView.contentOffset.y)")
                isManuallyScrolling = false
                // Sync the binding with current scroll position
                scrollOffset.wrappedValue = scrollView.contentOffset.y
                print("DEBUG: [Manual Scroll] Updated binding to: \(scrollOffset.wrappedValue)")
            }
        }
        
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            print("DEBUG: [Manual Scroll] END (with decel) - offset: \(scrollView.contentOffset.y)")
            isManuallyScrolling = false
            // Sync the binding with current scroll position
            scrollOffset.wrappedValue = scrollView.contentOffset.y
            print("DEBUG: [Manual Scroll] Updated binding to: \(scrollOffset.wrappedValue)")
        }
    }
}

// Preference key for tracking scroll offset (kept for compatibility)
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
