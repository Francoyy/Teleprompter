import SwiftUI
import UIKit
import Combine

// MARK: - AutoScrollController

final class AutoScrollController: ObservableObject {
    @Published var isAutoScrolling: Bool = false
    @Published var contentOffsetY: CGFloat = 0
    @Published var autoScrollSpeed: CGFloat = 0.9   // smaller = slower

    private var autoScrollTimer: Timer?
    var tickInterval: TimeInterval = 0.03

    // Limits for UI control (shown as 1–20)
    let minSpeed: CGFloat = 0.1   // shows as 1
    let maxSpeed: CGFloat = 3.0   // shows as 20
    let step: CGFloat = 0.1       // +/-1 in UI

    init() {
    }

    func toggle() {
        isAutoScrolling ? stop() : start()
    }

    func start() {
        guard !isAutoScrolling else {
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
    }

    func stop() {
        guard isAutoScrolling else {
            return
        }
        isAutoScrolling = false
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    func increaseSpeed() {
        autoScrollSpeed = min(maxSpeed, (autoScrollSpeed + step).rounded(toPlaces: 2))
    }

    func decreaseSpeed() {
        autoScrollSpeed = max(minSpeed, (autoScrollSpeed - step).rounded(toPlaces: 2))
    }

    // Display value 1–20 for the UI
    var displaySpeed: Int {
        Int((autoScrollSpeed * 10).rounded())
    }

    deinit {
        autoScrollTimer?.invalidate()
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
    }

    var body: some View {
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
                scrollView.contentOffset.y = targetY
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: CustomScrollView
        var hostingController: UIHostingController<Content>?
        var scrollView: UIScrollView?
        var isManuallyScrolling = false
        
        init(_ parent: CustomScrollView) {
            self.parent = parent
        }
        
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isManuallyScrolling = true
        }
        
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                isManuallyScrolling = false
                parent.scrollOffset = scrollView.contentOffset.y
            }
        }
        
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isManuallyScrolling = false
            parent.scrollOffset = scrollView.contentOffset.y
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if isManuallyScrolling {
                parent.scrollOffset = scrollView.contentOffset.y
            }
        }
    }
}
