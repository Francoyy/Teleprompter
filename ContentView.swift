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

// MARK: - Timer Controller (class so we can use weak self safely)
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

    private let defaultTeleText = ""

    @State private var teleText: String = ""
    @State private var teleTextSource: String = "Default"
    
    @State private var showClipboardToast = false
    @State private var showProcessingToast = false
    @State private var processingToastMessage = ""
    @State private var showCancelHintToast = false
    
    // Settings UI state
    @State private var isShowingSettings = false

    // Teleprompter font size (now user-adjustable)
    @State private var teleprompterFontSize: CGFloat = 40
    
    // Speed increase percentage (default 4%)
    @State private var speedIncreasePercent: Int = 4
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAttemptedInitialClipboardLoad = false
    
    var body: some View {
        GeometryReader { geo in
            let _ = DispatchQueue.main.async { self.screenHeight = geo.size.height }
            
            ZStack {
                // LAYER 1: Camera preview
                CameraPreviewLayer(recorder: recorder)
                
                // LAYER 2: Teleprompter
                TeleprompterLayer(
                    teleText: teleText,
                    teleprompterFontSize: teleprompterFontSize,
                    autoScroll: autoScroll,
                    geoWidth: geo.size.width
                )
                
                // LAYER 3: Top control bar
                TopControlBar(
                    teleText: teleText,
                    autoScroll: autoScroll,
                    recorder: recorder,
                    isShowingSettings: $isShowingSettings,
                    onClipboardPaste: { loadTeleprompterTextFromClipboard(explicitUserAction: true) }
                )
                
                // LAYER 4: Bottom control bar
                BottomControlBar(
                    recorder: recorder,
                    isShowingSettings: $isShowingSettings,
                    onRecordToggle: handleRecordToggle,
                    onCancelRecording: handleCancelRecording,
                    onCancelHint: showCancelHint,
                    onSave: saveToPhotos
                )
                
                // LAYER 5: Recording Timer Overlay
                if recorder.isRecording {
                    RecordingTimerOverlay(duration: recordingTimerController.duration)
                }
                
                // LAYER 6: Toast Notifications
                if showClipboardToast {
                    ClipboardToast()
                }
                
                if showProcessingToast {
                    ProcessingToast(message: processingToastMessage)
                }
                
                if showCancelHintToast {
                    CancelHintToast()
                }
                
                // LAYER 7: Settings Floating Window
                if isShowingSettings {
                    SettingsPanel(
                        isShowingSettings: $isShowingSettings,
                        recorder: recorder,
                        teleprompterFontSize: $teleprompterFontSize,
                        speedIncreasePercent: $speedIncreasePercent,
                        geoSize: geo.size
                    )
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear {
            teleText = defaultTeleText
            teleTextSource = "Default"

            AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    if videoGranted && audioGranted {
                        DispatchQueue.main.async {
                            recorder.setupSession()
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let spacerHeight = self.screenHeight * 0.5
                                self.autoScroll.contentOffsetY = spacerHeight
                            }
                        }
                    }
                }
            }
        }
        .onDisappear {
            autoScroll.stop()
            recordingTimerController.stop()
        }
        .onChange(of: recorder.isRecording) { isRecording in
            if isRecording {
                isShowingSettings = false
                recordingTimerController.start()
            } else {
                recordingTimerController.stop()
            }
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
                
                // If speed increase is 0%, skip processing and save directly
                if speedIncreasePercent == 0 {
                    saveToPhotos(url: url)
                } else {
                    // Show processing message (stays on screen)
                    showToast("Processing video...", autoDismiss: false)
                    
                    // Speed up the video using the recorder's method
                    recorder.speedUpVideo(inputURL: url, speedIncreasePercent: speedIncreasePercent) { processedURL in
                        guard let finalURL = processedURL else {
                            showToast("Processing failed.", autoDismiss: true)
                            return
                        }
                        
                        // Save to photos
                        saveToPhotos(url: finalURL)
                        
                        // Clean up temporary file if different from original
                        if finalURL != url {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
        } else {
            recorder.startRecording()
            isShowingSettings = false
        }
    }
    
    private func handleCancelRecording() {
        recorder.cancelCurrentRecording()
        recordingTimerController.stop()
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
            self.processingToastMessage = message
            withAnimation {
                self.showProcessingToast = true
            }
            
            if autoDismiss {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        self.showProcessingToast = false
                    }
                }
            }
        }
    }
    
    private func hideToast() {
        DispatchQueue.main.async {
            withAnimation {
                self.showProcessingToast = false
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
                // Hide the processing toast first
                hideToast()
                
                // Then show the result
                if success {
                    showToast("Saved successfully!", autoDismiss: true)
                } else {
                    showToast("Failed to save.", autoDismiss: true)
                }
                
                // Clean up the temporary file
                try? FileManager.default.removeItem(at: url)
            })
        }
    }
}

// MARK: - Camera Preview Layer
struct CameraPreviewLayer: View {
    @ObservedObject var recorder: VideoRecorder
    
    var body: some View {
        GeometryReader { previewGeo in
            let verticalOffset: CGFloat = 88
            
            ZStack {
                // Base camera preview
                CameraPreview(session: recorder.session)
                    .frame(
                        width: previewGeo.size.width,
                        height: recorder.selectedAspectRatio == .nineSixteen
                            ? (previewGeo.size.height - verticalOffset)
                            : previewGeo.size.height
                    )
                    .offset(y: recorder.selectedAspectRatio == .nineSixteen ? verticalOffset : 0)
                    .clipped()
                
                // 16:9 mask
                if recorder.selectedAspectRatio == .sixteenNine {
                    SixteenNineMask(geoSize: previewGeo.size)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 16:9 Mask
struct SixteenNineMask: View {
    let geoSize: CGSize
    
    var body: some View {
        let fullWidth = geoSize.width
        let fullHeight = geoSize.height
        let visibleHeight = fullWidth * 9.0 / 16.0
        let clampedVisibleHeight = min(visibleHeight, fullHeight)
        let hiddenTotal = fullHeight - clampedVisibleHeight
        let halfHidden = max(hiddenTotal / 2.0, 0)
        
        VStack(spacing: 0) {
            Color.black
                .frame(height: halfHidden)
            
            Spacer(minLength: 0)
            
            Color.black
                .frame(height: halfHidden)
        }
        .frame(width: geoSize.width, height: geoSize.height)
        .allowsHitTesting(false)
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

// MARK: - Top Control Bar
struct TopControlBar: View {
    let teleText: String
    @ObservedObject var autoScroll: AutoScrollController
    @ObservedObject var recorder: VideoRecorder
    @Binding var isShowingSettings: Bool
    let onClipboardPaste: () -> Void
    
    var body: some View {
        VStack {
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
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(Color.black.opacity(0.6))
            
            Spacer()
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

// MARK: - Bottom Control Bar
struct BottomControlBar: View {
    @ObservedObject var recorder: VideoRecorder
    @Binding var isShowingSettings: Bool
    let onRecordToggle: () -> Void
    let onCancelRecording: () -> Void
    let onCancelHint: () -> Void
    let onSave: (URL) -> Void

    var body: some View {
        VStack {
            Spacer()
            
            ZStack {
                // Centered record button
                RecordButton(
                    isRecording: recorder.isRecording,
                    onToggle: onRecordToggle
                )
                
                // Right-aligned trash button (only while recording)
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
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.9))
        }
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

// MARK: - Cancel Recording Button (Trash)
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
        // Long press recognizer (2 seconds)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 2.0)
                .onChanged { _ in
                    // reset when finger goes down
                    didFireLongPress = false
                }
                .onEnded { finished in
                    if finished {
                        didFireLongPress = true
                        onCancel()
                    }
                }
        )
        // Short tap / short press recognizer
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
                .padding(.bottom, 120)
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
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
                .padding(.bottom, 150)
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

// MARK: - Processing Toast
struct ProcessingToast: View {
    let message: String
    
    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
                .padding(.bottom, 150)
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
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
                .padding(.bottom, 150)
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

// MARK: - Settings Panel & related views
struct SettingsPanel: View {
    @Binding var isShowingSettings: Bool
    @ObservedObject var recorder: VideoRecorder
    @Binding var teleprompterFontSize: CGFloat
    @Binding var speedIncreasePercent: Int
    let geoSize: CGSize
    
    var body: some View {
        VStack {
            Spacer()
            
            VStack(alignment: .leading, spacing: 16) {
                SettingsHeader(isShowingSettings: $isShowingSettings)
                
                AspectRatioRow(recorder: recorder)
                
                TeleprompterFontSizeRow(teleprompterFontSize: $teleprompterFontSize)
                
                SpeedIncreaseRow(speedIncreasePercent: $speedIncreasePercent)
                
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

// MARK: - Speed Increase Row
struct SpeedIncreaseRow: View {
    @Binding var speedIncreasePercent: Int
    
    var body: some View {
        HStack(spacing: 8) {
            Text("Speed increase %:")
                .font(.subheadline)
                .foregroundColor(.white)
            
            PlusMinusControl(
                value: speedIncreasePercent,
                minValue: 0,
                maxValue: 20,
                step: 1,
                displaySuffix: "%"
            ) { newValue in
                withAnimation(.easeInOut(duration: 0.1)) {
                    speedIncreasePercent = newValue
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
