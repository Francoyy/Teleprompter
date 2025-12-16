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

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAttemptedInitialClipboardLoad = false

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
                    Color.black.opacity(teleprompterBackgroundOpacity)
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
                        // Clipboard
                        Button(action: {
                            loadTeleprompterTextFromClipboard(explicitUserAction: true)
                        }) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(6)
                        }

                        // Speed Controls
                        HStack(spacing: 6) {
                            Button(action: { autoScroll.decreaseSpeed() }) {
                                Text("−")
                                    .font(.headline.bold())
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(.white)
                                    .background(Color.gray.opacity(0.7))
                                    .cornerRadius(6)
                            }

                            Text("\(autoScroll.displaySpeed)")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(6)

                            Button(action: { autoScroll.increaseSpeed() }) {
                                Text("+")
                                    .font(.headline.bold())
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(.white)
                                    .background(Color.gray.opacity(0.7))
                                    .cornerRadius(6)
                            }

                            Button(action: { autoScroll.toggle() }) {
                                Text(autoScroll.isAutoScrolling ? "Stop Auto-Scroll" : "Auto-Scroll")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .background(autoScroll.isAutoScrolling ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
                                    .cornerRadius(6)
                            }
                        }
                        Spacer()
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
    }

    // MARK: - Helpers

    private func loadTeleprompterTextFromClipboard(explicitUserAction: Bool) {
        if UIPasteboard.general.hasStrings {
            let rawClipboard = UIPasteboard.general.string
            
            if let clipboardString = rawClipboard?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clipboardString.isEmpty {
                teleText += "\n\n" + clipboardString
                teleTextSource = "Clipboard Added"
                
                let spacerHeight = screenHeight * 0.5
                autoScroll.contentOffsetY = spacerHeight
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
}
