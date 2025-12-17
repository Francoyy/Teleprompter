import SwiftUI
import Combine
import AVFoundation
import Photos
import UIKit

// MARK: - Configuration
private let teleprompterBackgroundOpacity: Double = 0.3
private let teleprompterFontSize: CGFloat = 40

@main
struct Yuan_Teleprompter2App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var recorder = VideoRecorder()
    @StateObject private var autoScroll = AutoScrollController()
    @State private var saveMessage: String?
    @State private var screenHeight: CGFloat = 0

    private let defaultTeleText = ""

    @State private var teleText: String = ""
    @State private var teleTextSource: String = "Default"
    
    @State private var showClipboardToast = false
    
    // Settings UI state
    @State private var isShowingSettings = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAttemptedInitialClipboardLoad = false
    
    // MARK: - Timer State
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordingTimer: Timer?

    var body: some View {
        GeometryReader { geo in
            let _ = DispatchQueue.main.async { self.screenHeight = geo.size.height }
            
            ZStack {
                // LAYER 1: Camera preview + optional 16:9 crop bars, shifted down
                GeometryReader { previewGeo in
                    let verticalOffset: CGFloat = 88  // push preview down so it doesn't go under top bar
                    
                    ZStack {
                        // Base camera preview
                        CameraPreview(session: recorder.session)
                            .frame(
                                width: previewGeo.size.width,
                                height: previewGeo.size.height - verticalOffset
                            )
                            .offset(y: verticalOffset)
                            .clipped()
                        
                        // 16:9 mask: center visible area, black bars top/bottom
                        if recorder.selectedAspectRatio == .sixteenNine {
                            let fullWidth = previewGeo.size.width
                            let fullHeight = previewGeo.size.height - verticalOffset

                            // Desired on-screen visible window: full width, 16:9 height
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
                            .frame(
                                width: previewGeo.size.width,
                                height: previewGeo.size.height - verticalOffset
                            )
                            .offset(y: verticalOffset)
                            .allowsHitTesting(false)
                        }
                    }
                }
                .ignoresSafeArea()
                
                // LAYER 2: Teleprompter
                ZStack {
                    // Only apply opacity if there is text content
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
                                .frame(maxWidth: geo.size.width * 0.8)
                                .padding(.horizontal)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer().frame(height: 40)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                
                // LAYER 3: Top control bar
                VStack {
                    HStack(spacing: 12) {
                        // 1. Clipboard Button
                        Button(action: {
                            loadTeleprompterTextFromClipboard(explicitUserAction: true)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.clipboard")
                                Text("Paste from\nClipboard")
                                    .multilineTextAlignment(.leading)
                            }
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 44) // Fixed height for alignment
                            .background(Color.black.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray, lineWidth: 2)
                            )
                            .cornerRadius(6)
                        }

                        // 2. Speed & Auto Scroll (only when teleprompter has content)
                        if !teleText.isEmpty {
                            // Speed Controls (compact, same height & border style)
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

                            // Auto Scroll Button
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
                        
                        Spacer()
                        
                        // 4. Settings Button (gear icon, top-right)
                        Button(action: {
                            // No animation, just present instantly
                            isShowingSettings = true
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray, lineWidth: 2)
                                )
                                .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .background(Color.black.opacity(0.6))

                    Spacer()
                }
                
                // LAYER 4: Bottom control bar (9:16, 16:9, Record in one row)
                VStack {
                    Spacer()
                    
                    VStack(spacing: 6) {
                        HStack(spacing: 16) {
                            // Aspect ratio buttons on the left (only when not recording)
                            if !recorder.isRecording {
                                Button(action: {
                                    recorder.switchAspectRatio(.nineSixteen)
                                }) {
                                    Text("9:16")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .frame(width: 50, height: 30)
                                        .background(Color.black.opacity(0.5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(recorder.selectedAspectRatio == .nineSixteen ? Color.blue : Color.gray, lineWidth: 2)
                                        )
                                        .cornerRadius(6)
                                }
                                
                                Button(action: {
                                    recorder.switchAspectRatio(.sixteenNine)
                                }) {
                                    Text("16:9")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .frame(width: 50, height: 30)
                                        .background(Color.black.opacity(0.5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(recorder.selectedAspectRatio == .sixteenNine ? Color.blue : Color.gray, lineWidth: 2)
                                        )
                                        .cornerRadius(6)
                                }
                            }
                            
                            Spacer()
                            
                            // Record button on the right
                            Button(action: {
                                if recorder.isRecording {
                                    recorder.stopRecording { url in
                                        guard let url = url else {
                                            saveMessage = "Recording failed."
                                            return
                                        }
                                        saveToPhotos(url: url)
                                    }
                                } else {
                                    recorder.startRecording()
                                }
                            }) {
                                ZStack {
                                    Circle()
                                        .stroke(Color.white, lineWidth: 3)
                                        .frame(width: 52, height: 52)

                                    if recorder.isRecording {
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
                        .padding(.horizontal, 16)
                        
                        if let saveMessage = saveMessage {
                            HStack {
                                Text(saveMessage)
                                    .font(.footnote)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.9))
                }
                
                // LAYER 5: Recording Timer Overlay
                if recorder.isRecording {
                    VStack {
                        Spacer()
                        Text(formattedDuration(recordingDuration))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                            .padding(.bottom, 120)
                            .shadow(color: .black, radius: 1, x: 1, y: 1)
                    }
                }
                
                // LAYER 6: Toast Notification
                if showClipboardToast {
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
                
                // LAYER 7: Settings Floating Window (highest priority, no background overlay)
                if isShowingSettings {
                    VStack {
                        Spacer()
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Settings:")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Button(action: {
                                    // Close instantly, no animation
                                    isShowingSettings = false
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.white)
                                }
                            }
                            
                            // Placeholder for future settings content
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .frame(
                            width: min(geo.size.width * 0.85, 360),
                            height: min(geo.size.height * 0.4, 260)
                        )
                        .background(Color.black.opacity(0.9))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.gray.opacity(0.7), lineWidth: 1.5)
                        )
                        
                        Spacer()
                    }
                    .zIndex(200) // above everything else
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
        }
        .onChange(of: recorder.isRecording) { isRecording in
            if isRecording {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }

    // MARK: - Helpers

    private func loadTeleprompterTextFromClipboard(explicitUserAction: Bool) {
        var didPaste = false
        if UIPasteboard.general.hasStrings {
            let rawClipboard = UIPasteboard.general.string
            
            if let clipboardString = rawClipboard?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clipboardString.isEmpty {
                teleText = clipboardString // Replaces entire text
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
                DispatchQueue.main.async {
                    self.saveMessage = "Photos permission denied."
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    self.saveMessage = success ? nil : "Failed to save."
                }
            })
        }
    }
    
    // MARK: - Timer Helpers
    
    private func startTimer() {
        stopTimer()
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.recordingDuration += 1
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func formattedDuration(_ totalSeconds: TimeInterval) -> String {
        let seconds = Int(totalSeconds) % 60
        let minutes = Int(totalSeconds) / 60 % 60
        let hours = Int(totalSeconds) / 3600
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
