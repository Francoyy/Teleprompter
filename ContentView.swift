import SwiftUI
import Combine
import AVFoundation
import Photos
import UIKit

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

    private let defaultTeleText = """
    Clipboard content:
    """

    @State private var teleText: String = ""
    @State private var teleTextSource: String = "Default"

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAttemptedInitialClipboardLoad = false

    var body: some View {
        GeometryReader { geo in
            let teleHeight = geo.size.height / 3
            let edgeOffset: CGFloat = 80

            VStack(spacing: 0) {

                // TOP: Teleprompter with optional auto-scroll
                ZStack {
                    AutoScrollView(contentOffsetY: $autoScroll.contentOffsetY,
                                   isAutoScrolling: autoScroll.isAutoScrolling) {

                        VStack(spacing: 24) {

                            // ⬇️ REPLACED: the huge top/bottom padding that blocked scrolling
                            Spacer().frame(height: 40)

                            Text(teleText)
                                .font(.title3)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .frame(maxWidth: geo.size.width * 0.8)
                                .padding(.horizontal)

                            Spacer().frame(height: 40)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.9))
                    }
                    .frame(height: teleHeight)
                    .clipped()

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
                                Button(action: { autoScroll.decreaseSpeed() }) {
                                    Text("–")
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

                                Button(action: { autoScroll.increaseSpeed() }) {
                                    Text("+")
                                        .font(.caption.bold())
                                        .frame(width: 20, height: 20)
                                        .foregroundColor(.white)
                                        .background(Color.gray.opacity(0.7))
                                        .cornerRadius(4)
                                }

                                Button(action: { autoScroll.toggle() }) {
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
                }

                // MIDDLE: Camera preview
                CameraPreview(session: recorder.session)
                    .background(Color.black)

                // BOTTOM: Controls
                VStack(spacing: 6) {
                    HStack {
                        Spacer()

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
                        }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, !hasAttemptedInitialClipboardLoad {
                hasAttemptedInitialClipboardLoad = true
                loadTeleprompterTextFromClipboard(explicitUserAction: false)
            }
        }
        .onDisappear {
            autoScroll.stop()
        }
    }

    // MARK: - Teleprompter text loader

    private func loadTeleprompterTextFromClipboard(explicitUserAction: Bool) {
        let rawClipboard = UIPasteboard.general.string
        print("Clipboard raw value: \(String(describing: rawClipboard))")

        teleText = defaultTeleText

        if let clipboardString = rawClipboard?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clipboardString.isEmpty {
            teleText += "\n\n" + clipboardString
            teleTextSource = "Clipboard"
        } else {
            teleTextSource = "Default"
        }

        if explicitUserAction {
            saveMessage = (teleTextSource == "Clipboard")
                ? "Loaded teleprompter text from clipboard."
                : "Clipboard empty; using default text."
        }
    }

    // MARK: - Save to Photos

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
                    self.saveMessage = success ? "Saved to Photos." : "Failed to save."
                }
            })
        }
    }
}
