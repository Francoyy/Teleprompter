import Foundation
import AVFoundation
import UIKit
import Combine

class VideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false

    let session = AVCaptureSession()

    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Set from selected activeFormat
    private var outputWidth: Int = 0
    private var outputHeight: Int = 0

    private var currentOutputURL: URL?
    private var sessionStartTime: CMTime?

    func setupSession() {
        session.beginConfiguration()

        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        let targetFps: Double = 30.0

        if let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: .front) {

            // Active format BEFORE we touch anything (sensor space)
            let activeDims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            let activeRange = videoDevice.activeFormat.videoSupportedFrameRateRanges.first
            let activeMinFps = activeRange?.minFrameRate ?? 0
            let activeMaxFps = activeRange?.maxFrameRate ?? 0
            print("""
            [Front Camera] Current activeFormat BEFORE configuration (sensor space, landscape):
              Resolution: \(activeDims.width)x\(activeDims.height)
              FPS range: \(String(format: "%.2f", activeMinFps))-\(String(format: "%.2f", activeMaxFps))
            """)
            
            // Log available formats that support the target FPS
            let formatsSupporting30Fps = videoDevice.formats.filter { format in
                guard let range = format.videoSupportedFrameRateRanges.first else { return false }
                return range.maxFrameRate >= targetFps
            }

            let resolutions = formatsSupporting30Fps.map { format -> String in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return "\(dims.width)x\(dims.height)"
            }.joined(separator: ", ")

            print("\n=== FRONT CAMERA: RESOLUTIONS SUPPORTING \(targetFps)fps (SENSOR SPACE / LANDSCAPE) ===")
            print(resolutions)
            print("====================================================================================\n")


            // Pick the highest pixel count format that supports targetFps
            if #available(iOS 13.0, *) {
                let fpsCapable = videoDevice.formats.filter { format in
                    guard let range = format.videoSupportedFrameRateRanges.first else { return false }
                    return range.minFrameRate <= targetFps && range.maxFrameRate >= targetFps
                }

                if let bestFormat = fpsCapable.max(by: { lhs, rhs in
                    let ld = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                    let rd = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                    let lPixels = Int(ld.width) * Int(ld.height)
                    let rPixels = Int(rd.width) * Int(rd.height)
                    return lPixels < rPixels
                }) {

                    do {
                        try videoDevice.lockForConfiguration()
                        videoDevice.activeFormat = bestFormat
                        
                        // Lock the frame rate to 30fps. This is the correct way to prevent
                        // the frame rate from dropping in low light conditions.
                        videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                        videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))

                        let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
                        let range = bestFormat.videoSupportedFrameRateRanges.first
                        let minFps = range?.minFrameRate ?? 0
                        let maxFps = range?.maxFrameRate ?? 0
                        let fov = bestFormat.videoFieldOfView
                        let pixels = Int(dims.width) * Int(dims.height)

                        let w = Int(dims.width)
                        let h = Int(dims.height)
                        let g = gcd(w, h)
                        let arW = w / g
                        let arH = h / g

                        print("""
                        USING FRONT FORMAT (max resolution that supports ~\(targetFps) fps, sensor space):
                          Resolution: \(dims.width)x\(dims.height) (\(pixels) px)
                          Aspect ratio (sensor/landscape): \(arW):\(arH)
                          FPS range: \(String(format: "%.2f", minFps)) - \(String(format: "%.2f", maxFps))
                          FOV: \(String(format: "%.2f", fov))°
                        """)

                        outputWidth = Int(dims.width)
                        outputHeight = Int(dims.height)

                        videoDevice.unlockForConfiguration()
                    } catch {
                        print("Failed to configure front camera format: \(error)")
                    }
                } else {
                    print("No front formats support target fps \(targetFps); using default activeFormat.")
                    let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
                    outputWidth = Int(dims.width)
                    outputHeight = Int(dims.height)
                    print("Default activeFormat resolution (sensor): \(dims.width)x\(dims.height)")
                }
            } else {
                // Older iOS: just use activeFormat
                let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
                outputWidth = Int(dims.width)
                outputHeight = Int(dims.height)
                print("iOS < 13, using activeFormat (sensor): \(dims.width)x\(dims.height)")
            }

            print("Configured output size from activeFormat (sensor/landscape): \(outputWidth)x\(outputHeight)")

            do {
                let videoInputDevice = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(videoInputDevice) {
                    session.addInput(videoInputDevice)
                } else {
                    print("Cannot add video input.")
                }
            } catch {
                print("Error creating video input: \(error)")
            }
        } else {
            print("No front camera available.")
        }

        // Audio input
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInputDevice = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInputDevice) {
                    session.addInput(audioInputDevice)
                } else {
                    print("Cannot add audio input.")
                }
            } catch {
                print("Error creating audio input: \(error)")
            }
        } else {
            print("No audio device available.")
        }

        // Video output
        let videoQueue = DispatchQueue(label: "videoQueue")
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            print("Cannot add video output.")
        }

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        // Audio output
        let audioQueue = DispatchQueue(label: "audioQueue")
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        } else {
            print("Cannot add audio output.")
        }

        session.commitConfiguration()
        
        // --- ADDED: Start the session after configuration ---
        startSession()
    }

    func startRecording() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let outputURL = documentsDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        currentOutputURL = outputURL

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            // Video input settings
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputHeight, // Portrait
                AVVideoHeightKey: outputWidth,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            if let videoInput = videoInput, writer?.canAdd(videoInput) ?? false {
                writer?.add(videoInput)
            }

            // Audio input settings
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            if let audioInput = audioInput, writer?.canAdd(audioInput) ?? false {
                writer?.add(audioInput)
            }

            writer?.startWriting()
            isRecording = true

        } catch {
            print("Error setting up asset writer: \(error)")
            isRecording = false
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard let writer = writer, isRecording else {
            completion(nil)
            return
        }

        isRecording = false
        sessionStartTime = nil

        writer.finishWriting { [weak self] in
            self?.writer = nil
            self?.videoInput = nil
            self?.audioInput = nil

            if let url = self?.currentOutputURL {
                print("Video saved to: \(url.path)")
                DispatchQueue.main.async {
                    completion(url)
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    func startSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }
}

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard isRecording, let writer = writer else {
            return
        }

        if sessionStartTime == nil {
            sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: sessionStartTime!)
        }

        if output == videoOutput {
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        } else if output == audioOutput {
            if let audioInput = audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }
}

// Helper to find GCD for aspect ratio
private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = a
    var b = b
    while b != 0 {
        let temp = b
        b = a % b
        a = temp
    }
    return a
}
