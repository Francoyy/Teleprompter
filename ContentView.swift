import SwiftUI
import Combine
import AVFoundation
import Photos
import UIKit

// MARK: - Configuration
// Adjust this value to change the teleprompter background opacity (0.0 = transparent, 1.0 = opaque)
private let teleprompterBackgroundOpacity: Double = 0.3

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

    private let defaultTeleText = """
    Clipboard content:
    """

    @State private var teleText: String = ""
    @State private var teleTextSource: String = "Default"

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAttemptedInitialClipboardLoad = false

    var body: some View {
        GeometryReader { geo in
            let _ = DispatchQueue.main.async { self.screenHeight = geo.size.height }
            
            ZStack {
                // LAYER 1: Full-screen camera preview (bottom layer)
                CameraPreview(session: recorder.session)
                    .ignoresSafeArea()
                    .onAppear {
                        print("DEBUG: CameraPreview appeared")
                    }
                
                // LAYER 2: Full-screen teleprompter with semi-transparent background
                ZStack {
                    // Semi-transparent black background
                    Color.black.opacity(teleprompterBackgroundOpacity)
                        .ignoresSafeArea()
                    
                    // Scrollable teleprompter text
                    AutoScrollView(contentOffsetY: $autoScroll.contentOffsetY,
                                   isAutoScrolling: autoScroll.isAutoScrolling) {
                        VStack(spacing: 24) {
                            Spacer().frame(height: 40)

                            Text(teleText)
                                .font(.title3)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .frame(maxWidth: geo.size.width * 0.8)
                                .padding(.horizontal)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer().frame(height: 40)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .onAppear {
                        print("DEBUG: AutoScrollView appeared")
                    }
                }
                .onAppear {
                    print("DEBUG: Teleprompter layer appeared")
                }
                
                // LAYER 3: Top control bar (static, no transparency)
                VStack {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Teleprompter")
                                .font(.caption)
                                .foregroundColor(.white)
                            Text("Source: \(teleTextSource)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)

                        Spacer()

                        Button(action: {
                            print("DEBUG: Clipboard button tapped")
                            loadTeleprompterTextFromClipboard(explicitUserAction: true)
                        }) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                        }

                        HStack(spacing: 4) {
                            Button(action: {
                                print("DEBUG: Decrease speed tapped")
                                autoScroll.decreaseSpeed()
                            }) {
                                Text("−")
                                    .font(.caption.bold())
                                    .frame(width: 20, height: 20)
                                    .foregroundColor(.white)
                                    .background(Color.gray.opacity(0.7))
                                    .cornerRadius(4)
                            }

                            Text("\(autoScroll.displaySpeed)")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)

                            Button(action: {
                                print("DEBUG: Increase speed tapped")
                                autoScroll.increaseSpeed()
                            }) {
                                Text("+")
                                    .font(.caption.bold())
                                    .frame(width: 20, height: 20)
                                    .foregroundColor(.white)
                                    .background(Color.gray.opacity(0.7))
                                    .cornerRadius(4)
                            }

                            Button(action: {
                                print("DEBUG: Toggle auto-scroll tapped")
                                autoScroll.toggle()
                            }) {
                                Text(autoScroll.isAutoScrolling ? "Stop Auto-Scroll" : "Auto-Scroll")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(autoScroll.isAutoScrolling ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    
                    Spacer()
                }
                .onAppear {
                    print("DEBUG: Top control bar appeared")
                }
                
                // LAYER 4: Bottom control bar (static, no transparency)
                VStack {
                    Spacer()
                    
                    VStack(spacing: 6) {
                        HStack {
                            Spacer()

                            Button(action: {
                                print("DEBUG: Record button tapped, isRecording: \(recorder.isRecording)")
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
                            .padding(.trailing, 8)
                        }

                        if let saveMessage = saveMessage {
                            HStack {
                                Text(saveMessage)
                                    .font(.footnote)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(.leading, 8)
                        }
                    }
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.9))
                }
                .onAppear {
                    print("DEBUG: Bottom control bar appeared")
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .onAppear {
            print("DEBUG: ContentView onAppear START")
            teleText = defaultTeleText
            teleTextSource = "Default"
            print("DEBUG: Set default teleText")

            AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                print("DEBUG: Video permission granted: \(videoGranted)")
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    print("DEBUG: Audio permission granted: \(audioGranted)")
                    if videoGranted && audioGranted {
                        DispatchQueue.main.async {
                            print("DEBUG: About to call recorder.setupSession()")
                            recorder.setupSession()
                            print("DEBUG: recorder.setupSession() completed")
                            
                            // After a small delay to ensure layout, set initial scroll position
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let spacerHeight = self.screenHeight * 0.5
                                self.autoScroll.contentOffsetY = spacerHeight
                                print("DEBUG: Set initial scroll position to: \(spacerHeight)")
                            }
                        }
                    }
                }
            }
            print("DEBUG: ContentView onAppear END")
        }
        .onDisappear {
            print("DEBUG: ContentView onDisappear")
            autoScroll.stop()
        }
    }

    // MARK: - Teleprompter text loader

    private func loadTeleprompterTextFromClipboard(explicitUserAction: Bool) {
        print("DEBUG: loadTeleprompterTextFromClipboard START (explicit: \(explicitUserAction))")
        
        // Check if pasteboard has strings
        if UIPasteboard.general.hasStrings {
            let rawClipboard = UIPasteboard.general.string
            print("DEBUG: Clipboard has strings. Raw value length: \(rawClipboard?.count ?? 0)")
            print("DEBUG: Clipboard preview: \(rawClipboard?.prefix(100) ?? "nil")")
            
            if let clipboardString = rawClipboard?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clipboardString.isEmpty {
                // Append to existing text instead of replacing
                let beforeLength = teleText.count
                teleText += "\n\n" + clipboardString
                let afterLength = teleText.count
                teleTextSource = "Clipboard Added"
                print("DEBUG: Appended from clipboard. Before: \(beforeLength), After: \(afterLength), Added: \(clipboardString.count)")
                print("DEBUG: New teleText preview: \(teleText.prefix(200))")
                
                // Reset scroll position to the spacer height (where text actually starts)
                // This positions the first line of text in the middle of the screen
                let spacerHeight = screenHeight * 0.5
                autoScroll.contentOffsetY = spacerHeight
                print("DEBUG: Reset scroll position to spacer height: \(spacerHeight)")
                
                if explicitUserAction {
                    saveMessage = "Added clipboard text to teleprompter."
                }
            } else {
                print("DEBUG: Clipboard string was empty after trimming")
                if explicitUserAction {
                    saveMessage = "Clipboard appears empty."
                }
            }
        } else {
            print("DEBUG: Clipboard has no strings")
            if explicitUserAction {
                saveMessage = "No text found in clipboard."
            }
        }
        
        print("DEBUG: loadTeleprompterTextFromClipboard END. Current teleText length: \(teleText.count)")
    }

    // MARK: - Save to Photos

    private func saveToPhotos(url: URL) {
        print("DEBUG: saveToPhotos START with URL: \(url)")
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            print("DEBUG: Photos permission status: \(status.rawValue)")
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.saveMessage = "Photos permission denied."
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                print("DEBUG: Save to photos completed. Success: \(success), Error: \(String(describing: error))")
                DispatchQueue.main.async {
                    self.saveMessage = success ? "Saved to Photos." : "Failed to save."
                }
            })
        }
    }
}
