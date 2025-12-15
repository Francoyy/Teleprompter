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

        // Let the input format drive the session
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }

        let targetFps: Double = 30.0

        if let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: .front) {

            // Log all formats so we can see what the device offers
            print("\n=== FRONT CAMERA AVAILABLE FORMATS ===")
            for (index, format) in videoDevice.formats.enumerated() {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let range = format.videoSupportedFrameRateRanges.first
                let minFps = range?.minFrameRate ?? 0
                let maxFps = range?.maxFrameRate ?? 0
                let fov = format.videoFieldOfView
                let mediaSubtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let fourCC = String(format: "%4.4s",
                                    [UInt8((mediaSubtype >> 24) & 0xff),
                                     UInt8((mediaSubtype >> 16) & 0xff),
                                     UInt8((mediaSubtype >> 8) & 0xff),
                                     UInt8(mediaSubtype & 0xff)])
                let pixels = Int(dims.width) * Int(dims.height)
                print("""
                [Format \(index)]
                  Dimensions: \(dims.width)x\(dims.height) (\(pixels) px)
                  FPS range: \(minFps) - \(maxFps)
                  FOV: \(String(format: "%.2f", fov))°
                  MediaSubType: \(fourCC)
                """)
            }
            print("=== END FRONT CAMERA FORMATS ===\n")

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
                        videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                        videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))

                        let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
                        let fov = bestFormat.videoFieldOfView
                        let pixels = Int(dims.width) * Int(dims.height)
                        print("""
                        USING FRONT FORMAT (max resolution at ~\(targetFps) fps):
                          Dimensions: \(dims.width)x\(dims.height) (\(pixels) px)
                          FOV: \(String(format: "%.2f", fov))°
                          Target FPS: \(targetFps)
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
                    print("Default activeFormat dimensions: \(dims.width)x\(dims.height)")
                }
            } else {
                // Older iOS: just use activeFormat
                let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
                outputWidth = Int(dims.width)
                outputHeight = Int(dims.height)
                print("iOS < 13, using activeFormat: \(dims.width)x\(dims.height)")
            }

            print("Configured output size (from activeFormat): \(outputWidth)x\(outputHeight)")

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
            print("Video connection orientation set to .portrait")
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

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
            print("Capture session running: \(self.session.isRunning)")
            print("Session activeFormat-based output: \(self.outputWidth)x\(self.outputHeight)")
        }
    }

    func startRecording() {
        // Fallback if for some reason not set
        if outputWidth == 0 || outputHeight == 0 {
            if let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                         for: .video,
                                                         position: .front) {
                let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
                outputWidth = Int(dims.width)
                outputHeight = Int(dims.height)
            }
        }

        // Your working logic: compute width from height (3:4 vertical)
        let originalHeight = outputHeight
        let newWidth = Int(round(Double(originalHeight) * 3.0 / 4.0))
        print("Original output from sensor: \(outputWidth)x\(outputHeight)")
        outputWidth = newWidth
        outputHeight = originalHeight
        print("Final writer output (3:4 vertical): \(outputWidth)x\(outputHeight)")

        let filename = "native_\(outputWidth)x\(outputHeight)_\(UUID().uuidString).mov"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        currentOutputURL = url

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            self.writer = writer

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            self.videoInput = videoInput

            if writer.canAdd(videoInput) {
                writer.add(videoInput)
            }

            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    kCVPixelBufferWidthKey as String: outputWidth,
                    kCVPixelBufferHeightKey as String: outputHeight
                ]
            )

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 96_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            self.audioInput = audioInput

            if writer.canAdd(audioInput) {
                writer.add(audioInput)
            }

            sessionStartTime = nil
            writer.startWriting()

            DispatchQueue.main.async {
                self.isRecording = true
            }

            print("Started recording to: \(url.lastPathComponent)")
            print("Recording resolution (writer settings): \(outputWidth)x\(outputHeight)")
        } catch {
            print("Error creating AVAssetWriter: \(error)")
            currentOutputURL = nil
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        isRecording = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        guard let writer = writer else {
            completion(nil)
            return
        }

        let outputURL = currentOutputURL

        writer.finishWriting { [weak self] in
            guard let self = self else { return }

            if writer.status == .completed {
                print("Finished writing. Temp file: \(outputURL?.absoluteString ?? "nil")")
                completion(outputURL)
            } else {
                print("Writer finished with status: \(writer.status), error: \(String(describing: writer.error))")
                completion(nil)
            }

            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.adaptor = nil
            self.currentOutputURL = nil
            self.sessionStartTime = nil
        }
    }

    private func processVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let writer = writer,
              let videoInput = videoInput,
              videoInput.isReadyForMoreMediaData,
              let adaptor = adaptor else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if sessionStartTime == nil {
            sessionStartTime = timestamp
            writer.startSession(atSourceTime: timestamp)
            print("Writer session started at time: \(timestamp.value)/\(timestamp.timescale)")
        }

        // No more horizontal squeeze: pass the buffer through as-is
        let ok = adaptor.append(imageBuffer, withPresentationTime: timestamp)

        if !ok {
            print("WARNING: Failed to append video buffer at \(timestamp) (status: \(writer.status)) error: \(String(describing: writer.error))")
        }
    }

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              sessionStartTime != nil,
              let audioInput = audioInput,
              audioInput.isReadyForMoreMediaData else {
            return
        }

        if !audioInput.append(sampleBuffer) {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            print("WARNING: Failed to append audio buffer at time \(ts)")
        }
    }
}

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        if output === videoOutput {
            processVideoBuffer(sampleBuffer)
        } else if output === audioOutput {
            processAudioBuffer(sampleBuffer)
        }
    }
}
