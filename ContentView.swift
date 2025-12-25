import SwiftUI
import Combine
import AVFoundation
import Photos
import UIKit

// MARK: - Configuration
private let teleprompterBackgroundOpacity: Double = 0.3

@main
struct Yuan_Teleprompter2App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Timer Controller
final class RecordingTimerController: ObservableObject {
    @Published var duration: TimeInterval = 0
    
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "recordingTimerQueue")
    
    func start() {
        stop()
        duration = 0
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.duration += 1
            }
        }
        self.timer = timer
        timer.resume()
    }
    
    func stop() {
        timer?.cancel()
        timer = nil
    }
}

struct ContentView: View {
    @StateObject private var recorder = VideoRecorder()
    @StateObject private var autoScroll = AutoScrollController()
    @StateObject private var recordingTimerController = RecordingTimerController()
    
    @State private var screenHeight: CGFloat = 0
    @State private var isInitialLoad = true

    private let defaultTeleText = ""

    @AppStorage("teleText") private var teleText: String = ""
    @State private var teleTextSource: String = "Default"
    
    @State private var showClipboardToast = false
    @State private var showCancelHintToast = false
    @State private var toastMessage = ""
    @State private var showGenericToast = false
    
    @State private var isShowingSettings = false

    @AppStorage("teleprompterFontSize") private var storedTeleprompterFontSize: Double = 40
    @State private var teleprompterFontSize: CGFloat = 40
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAttemptedInitialClipboardLoad = false
    
    var body: some View {
        GeometryReader { geo in
            let _ = DispatchQueue.main.async {
                if self.screenHeight != geo.size.height {
                    self.screenHeight = geo.size.height
                }
            }
            
            ZStack {
                CameraPreviewLayer(recorder: recorder)
                
                TeleprompterLayer(
                    teleText: teleText,
                    teleprompterFontSize: teleprompterFontSize,
                    autoScroll: autoScroll,
                    geoWidth: geo.size.width
                )
                
                clearButtonOverlay(for: geo)
                
                // Bottom control area (options bar + recording bar)
                BottomControlArea(
                    teleText: teleText,
                    autoScroll: autoScroll,
                    recorder: recorder,
                    isShowingSettings: $isShowingSettings,
                    onClipboardPaste: { loadTeleprompterTextFromClipboard(explicitUserAction: true) },
                    onRecordToggle: handleRecordToggle,
                    onCancelRecording: handleCancelRecording,
                    onCancelHint: showCancelHint,
                    onSave: saveToPhotos
                )
                
                if recorder.isRecording {
                    RecordingTimerOverlay(duration: recordingTimerController.duration)
                }
                
                if showClipboardToast {
                    ClipboardToast()
                }
                
                if showGenericToast {
                    GenericToast(message: toastMessage)
                }
                
                if showCancelHintToast {
                    CancelHintToast()
                }
                
                if isShowingSettings {
                    SettingsPanel(
                        isShowingSettings: $isShowingSettings,
                        recorder: recorder,
                        teleprompterFontSize: $teleprompterFontSize,
                        geoSize: geo.size
                    )
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear {
            teleprompterFontSize = CGFloat(storedTeleprompterFontSize)

            AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    if videoGranted && audioGranted {
                        DispatchQueue.main.async {
                            recorder.setupSession()
                        }
                    }
                }
            }
        }
        .onChange(of: screenHeight) { newHeight in
            if isInitialLoad && newHeight > 0 {
                let spacerHeight = newHeight * 0.5
                autoScroll.contentOffsetY = spacerHeight
                isInitialLoad = false
            }
        }
        .onDisappear {
            autoScroll.stop()
            recordingTimerController.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: recorder.isRecording) { isRecording in
            if isRecording {
                isShowingSettings = false
                recordingTimerController.start()
                UIApplication.shared.isIdleTimerDisabled = true
            } else {
                recordingTimerController.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onChange(of: teleprompterFontSize) { newValue in
            storedTeleprompterFontSize = Double(newValue)
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
    // --- START OF MODIFICATION: Fixed the helper function to compile correctly ---
    @ViewBuilder
    private func clearButtonOverlay(for geo: GeometryProxy) -> some View {
        if !teleText.isEmpty {
            // By wrapping calculations in an immediately-executing closure assigned to a `let`,
            // we separate the procedural logic from the view declaration, satisfying the compiler.
            let origin: (x: CGFloat, y: CGFloat) = {
                let containerSize = geo.size
                let targetAspectRatio = recorder.selectedAspectRatio == .nineSixteen ? (9.0 / 16.0) : 1.0
                
                var previewWidth = containerSize.width
                var previewHeight = previewWidth / targetAspectRatio
                
                if previewHeight > containerSize.height {
                    previewHeight = containerSize.height
                    previewWidth = previewHeight * targetAspectRatio
                }
                
                let previewOriginX = (containerSize.width - previewWidth) / 2
                let previewOriginY = (containerSize.height - previewHeight) / 2
                return (x: previewOriginX, y: previewOriginY)
            }() // The () executes the closure immediately

            // Now the @ViewBuilder only sees the `let` declaration above and this ZStack below.
            ZStack(alignment: .topLeading) {
                ClearTextButton(onClear: handleClearText)
                    .offset(x: origin.x + 10, y: origin.y - 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyView()
        }
    }
    // --- END OF MODIFICATION ---

    // MARK: - Scene phase handling
    
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            break

        case .inactive, .background:
            if recorder.isRecording {
                recorder.cancelCurrentRecording()
                recordingTimerController.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }

        @unknown default:
            break
        }
    }

    // MARK: - Helpers

    private func handleRecordToggle() {
        if recorder.isRecording {
            recorder.stopRecording { [self] url in
                guard let url = url else {
                    showToast("Recording failed.", autoDismiss: true)
                    return
                }
                
                saveToPhotos(url: url)
            }
        } else {
            recorder.startRecording()
            isShowingSettings = false
        }
    }
    
    private func handleCancelRecording() {
        recorder.cancelCurrentRecording()
        recordingTimerController.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    private func handleClearText() {
        withAnimation {
            teleText = ""
            teleTextSource = "Default"
            autoScroll.stop()
        }
    }

    private func showCancelHint() {
        withAnimation {
            showCancelHintToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCancelHintToast = false
            }
        }
    }
    
    private func showToast(_ message: String, autoDismiss: Bool) {
        DispatchQueue.main.async {
            self.toastMessage = message
            withAnimation {
                self.showGenericToast = true
            }
            
            if autoDismiss {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        self.showGenericToast = false
                    }
                }
            }
        }
    }
    
    private func hideToast() {
        DispatchQueue.main.async {
            withAnimation {
                self.showGenericToast = false
            }
        }
    }

    private func loadTeleprompterTextFromClipboard(explicitUserAction: Bool) {
        var didPaste = false
        if UIPasteboard.general.hasStrings {
            let rawClipboard = UIPasteboard.general.string
            
            if let clipboardString = rawClipboard?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clipboardString.isEmpty {
                teleText = clipboardString
                teleTextSource = "Clipboard"
                
                let spacerHeight = screenHeight * 0.5
                autoScroll.contentOffsetY = spacerHeight
                didPaste = true
            }
        }
        
        if !didPaste {
            withAnimation {
                showClipboardToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showClipboardToast = false
                }
            }
        }
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                showToast("Photos permission denied.", autoDismiss: true)
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                hideToast()
                
                if success {
                    showToast("Saved successfully!", autoDismiss: true)
                } else {
                    showToast("Failed to save.", autoDismiss: true)
                }
                
                try? FileManager.default.removeItem(at: url)
            })
        }
    }
}

// MARK: - Camera Preview Layer
struct CameraPreviewLayer: View {
    @ObservedObject var recorder: VideoRecorder
    
    var body: some View {
        Color.black
            .ignoresSafeArea() // This allows the camera to extend into safe areas
            .overlay(
                GeometryReader { previewGeo in
                    ZStack {
                        CameraPreview(image: recorder.previewImage)
                            .aspectRatio(
                                recorder.selectedAspectRatio == .nineSixteen ? (9.0 / 16.0) : 1.0,
                                contentMode: .fit
                            )
                            .frame(
                                maxWidth: previewGeo.size.width,
                                maxHeight: previewGeo.size.height
                            )
                            .clipped()
                    }
                    .frame(width: previewGeo.size.width, height: previewGeo.size.height)
                }
                .ignoresSafeArea() // Camera preview extends into safe areas (under dynamic island)
            )
    }
}

// MARK: - Teleprompter Layer
struct TeleprompterLayer: View {
    let teleText: String
    let teleprompterFontSize: CGFloat
    @ObservedObject var autoScroll: AutoScrollController
    let geoWidth: CGFloat
    
    var body: some View {
        ZStack {
            Color.black.opacity(teleText.isEmpty ? 0 : teleprompterBackgroundOpacity)
                .ignoresSafeArea()
            
            AutoScrollView(contentOffsetY: $autoScroll.contentOffsetY,
                           isAutoScrolling: autoScroll.isAutoScrolling) {
                VStack(spacing: 24) {
                    Spacer().frame(height: 40)
                    
                    Text(teleText)
                        .font(.system(size: teleprompterFontSize))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .frame(maxWidth: geoWidth * 0.8)
                        .padding(.horizontal)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer().frame(height: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Bottom Control Area (Options Bar + Recording Bar)
struct BottomControlArea: View {
    let teleText: String
    @ObservedObject var autoScroll: AutoScrollController
    @ObservedObject var recorder: VideoRecorder
    @Binding var isShowingSettings: Bool
    let onClipboardPaste: () -> Void
    let onRecordToggle: () -> Void
    let onCancelRecording: () -> Void
    let onCancelHint: () -> Void
    let onSave: (URL) -> Void
    
    var body: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 0) {
                // Options Bar (formerly top bar)
                OptionsBar(
                    teleText: teleText,
                    autoScroll: autoScroll,
                    recorder: recorder,
                    isShowingSettings: $isShowingSettings,
                    onClipboardPaste: onClipboardPaste
                )
                
                // Recording Bar (formerly bottom bar)
                RecordingBar(
                    recorder: recorder,
                    onRecordToggle: onRecordToggle,
                    onCancelRecording: onCancelRecording,
                    onCancelHint: onCancelHint
                )
            }
            .padding(.bottom, 8) // Minimal padding - let safe area handle the rest
        }
        .ignoresSafeArea(edges: .bottom) // Allow bars to extend into bottom safe area
    }
}

// MARK: - Options Bar (formerly Top Control Bar)
struct OptionsBar: View {
    let teleText: String
    @ObservedObject var autoScroll: AutoScrollController
    @ObservedObject var recorder: VideoRecorder
    @Binding var isShowingSettings: Bool
    let onClipboardPaste: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ClipboardButton(onPaste: onClipboardPaste)
            
            if !teleText.isEmpty {
                SpeedControl(autoScroll: autoScroll)
                AutoScrollButton(autoScroll: autoScroll)
            }
            
            Spacer()
            
            SettingsButton(
                isRecording: recorder.isRecording,
                isShowingSettings: $isShowingSettings
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
    }
}

// MARK: - Recording Bar (formerly Bottom Control Bar)
struct RecordingBar: View {
    @ObservedObject var recorder: VideoRecorder
    let onRecordToggle: () -> Void
    let onCancelRecording: () -> Void
    let onCancelHint: () -> Void
    
    var body: some View {
        ZStack {
            RecordButton(
                isRecording: recorder.isRecording,
                onToggle: onRecordToggle
            )
            
            if recorder.isRecording {
                HStack {
                    Spacer()
                    CancelRecordingButton(
                        onCancel: onCancelRecording,
                        onShortPress: onCancelHint
                    )
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

// MARK: - Clear Text Button
struct ClearTextButton: View {
    let onClear: () -> Void
    
    var body: some View {
        Button(action: onClear) {
            ZStack {
                Color.black.opacity(0.001)
                    .frame(width: 44, height: 44)
                
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                        .font(.system(size: 10, weight: .bold))
                }
            }
        }
    }
}

// MARK: - Clipboard Button
struct ClipboardButton: View {
    let onPaste: () -> Void
    
    var body: some View {
        Button(action: onPaste) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                Text("Paste from\nClipboard")
                    .multilineTextAlignment(.leading)
            }
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Color.black.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray, lineWidth: 2)
            )
            .cornerRadius(6)
        }
    }
}

// MARK: - Speed Control
struct SpeedControl: View {
    @ObservedObject var autoScroll: AutoScrollController
    
    var body: some View {
        HStack(spacing: 0) {
            Button(action: { autoScroll.decreaseSpeed() }) {
                Text("−")
                    .font(.headline.bold())
                    .frame(width: 26, height: 44)
                    .contentShape(Rectangle())
            }
            
            Text("Speed\n\(autoScroll.displaySpeed)")
                .font(.caption2.bold())
                .multilineTextAlignment(.center)
                .frame(width: 46)
                .lineLimit(2)
            
            Button(action: { autoScroll.increaseSpeed() }) {
                Text("+")
                    .font(.headline.bold())
                    .frame(width: 26, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 4)
        .background(Color.black.opacity(0.5))
        .frame(height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray, lineWidth: 2)
        )
        .cornerRadius(6)
    }
}

// MARK: - Auto Scroll Button
struct AutoScrollButton: View {
    @ObservedObject var autoScroll: AutoScrollController
    
    var body: some View {
        Button(action: { autoScroll.toggle() }) {
            Text("Auto\nScroll")
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(Color.black.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(autoScroll.isAutoScrolling ? Color.blue : Color.gray,
                                lineWidth: 2)
                )
                .cornerRadius(6)
        }
    }
}

// MARK: - Settings Button
struct SettingsButton: View {
    let isRecording: Bool
    @Binding var isShowingSettings: Bool
    
    var body: some View {
        Button(action: {
            if !isRecording {
                isShowingSettings = true
            }
        }) {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .foregroundColor(isRecording ? Color.gray.opacity(0.5) : .white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray, lineWidth: 2)
                )
                .cornerRadius(6)
        }
        .disabled(isRecording)
    }
}

// MARK: - Record Button
struct RecordButton: View {
    let isRecording: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 52, height: 52)
                
                if isRecording {
                    RoundedRectangle(cornerRadius: 4)
                    .fill(Color.red)
                    .frame(width: 26, height: 26)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                }
            }
        }
    }
}

// MARK: - Cancel Recording Button
struct CancelRecordingButton: View {
    let onCancel: () -> Void
    let onShortPress: () -> Void

    @State private var didFireLongPress = false

    var body: some View {
        Button(action: {}) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 44, height: 44)

                Image(systemName: "trash")
                    .foregroundColor(.white)
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 2.0)
                .onChanged { _ in
                    didFireLongPress = false
                }
                .onEnded { finished in
                    if finished {
                        didFireLongPress = true
                        onCancel()
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    if !didFireLongPress {
                        onShortPress()
                    }
                }
        )
    }
}

// MARK: - Recording Timer Overlay
struct RecordingTimerOverlay: View {
    let duration: TimeInterval
    
    var body: some View {
        VStack {
            Spacer()
            Text(formattedDuration(duration))
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.red)
                .padding(.bottom, 230) // Adjusted for pushed-down layout
                .shadow(color: .black, radius: 1, x: 1, y: 1)
        }
    }
    
    private func formattedDuration(_ totalSeconds: TimeInterval) -> String {
        let seconds = Int(totalSeconds) % 60
        let minutes = Int(totalSeconds) / 60 % 60
        let hours = Int(totalSeconds) / 3600
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

// MARK: - Clipboard Toast
struct ClipboardToast: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Clipboard is empty")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
                .padding(.bottom, 250) // Adjusted for pushed-down layout
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

// MARK: - Generic Toast
struct GenericToast: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
                .padding(.bottom, 250) // Adjusted for pushed-down layout
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

// MARK: - Cancel Hint Toast
struct CancelHintToast: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Press 2 seconds to cancel recording")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
                .padding(.bottom, 250) // Adjusted for pushed-down layout
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

// MARK: - Settings Panel
struct SettingsPanel: View {
    @Binding var isShowingSettings: Bool
    @ObservedObject var recorder: VideoRecorder
    @Binding var teleprompterFontSize: CGFloat
    let geoSize: CGSize
    
    var body: some View {
        VStack {
            Spacer()
            
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader(isShowingSettings: $isShowingSettings)
                
                AspectRatioRow(recorder: recorder)
                
                TeleprompterFontSizeRow(teleprompterFontSize: $teleprompterFontSize)
                
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(
                width: min(geoSize.width * 0.85, 360),
                height: min(geoSize.height * 0.45, 300)
            )
            .background(Color.black.opacity(0.9))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.gray.opacity(0.7), lineWidth: 1.5)
            )
            
            Spacer()
        }
        .zIndex(200)
    }
}

// MARK: - Settings Header
struct SettingsHeader: View {
    @Binding var isShowingSettings: Bool
    
    var body: some View {
        HStack {
            Text("Settings:")
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
            Button(action: {
                isShowingSettings = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Aspect Ratio Row
struct AspectRatioRow: View {
    @ObservedObject var recorder: VideoRecorder
    
    var body: some View {
        HStack(spacing: 8) {
            Text("Aspect Ratio:")
                .font(.subheadline)
                .foregroundColor(.white)
            
            AspectRatioButton(
                title: "9:16",
                isSelected: recorder.selectedAspectRatio == .nineSixteen,
                isDisabled: recorder.isRecording
            ) {
                recorder.switchAspectRatio(.nineSixteen)
            }
            
            AspectRatioButton(
                title: "16:9",
                isSelected: recorder.selectedAspectRatio == .sixteenNine,
                isDisabled: recorder.isRecording
            ) {
                recorder.switchAspectRatio(.sixteenNine)
            }
            
            Spacer()
        }
    }
}

// MARK: - Aspect Ratio Button
struct AspectRatioButton: View {
    let title: String
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 50, height: 30)
                .background(Color.black.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isSelected ? Color.blue : Color.gray,
                            lineWidth: 2
                        )
                )
                .cornerRadius(6)
        }
        .disabled(isDisabled)
    }
}

// MARK: - Teleprompter Font Size Row
struct TeleprompterFontSizeRow: View {
    @Binding var teleprompterFontSize: CGFloat
    
    var body: some View {
        HStack(spacing: 8) {
            Text("Teleprompter text size:")
                .font(.subheadline)
                .foregroundColor(.white)
            
            PlusMinusControl(
                value: Int(teleprompterFontSize),
                minValue: 20,
                maxValue: 80,
                step: 2,
                displaySuffix: ""
            ) { newValue in
                withAnimation(.easeInOut(duration: 0.1)) {
                    teleprompterFontSize = CGFloat(newValue)
                }
            }
            
            Spacer()
        }
    }
}

// MARK: - Plus Minus Control
struct PlusMinusControl: View {
    let value: Int
    let minValue: Int
    let maxValue: Int
    let step: Int
    let displaySuffix: String
    let onChange: (Int) -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            Button(action: {
                let newValue = max(minValue, value - step)
                onChange(newValue)
            }) {
                Text("−")
                    .font(.headline.bold())
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
            
            Text("\(value)\(displaySuffix)")
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .frame(width: 40, height: 32)
            
            Button(action: {
                let newValue = min(maxValue, value + step)
                onChange(newValue)
            }) {
                Text("+")
                    .font(.headline.bold())
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 4)
        .background(Color.black.opacity(0.5))
        .frame(height: 32)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray, lineWidth: 2)
        )
        .cornerRadius(6)
    }
}
