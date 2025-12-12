import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Combine


// MARK: - VideoRecorder

class VideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false

    let session = AVCaptureSession()

    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let ciContext = CIContext()

    private let outputWidth: Int = 3840
    private let outputHeight: Int = 2160

    private var currentOutputURL: URL?
    private var sessionStartTime: CMTime?

    func setupSession() {
        session.beginConfiguration()

        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else {
            session.sessionPreset = .high
        }

        let targetFps: Double = 30.0

        if let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: .front) {

            if #available(iOS 13.0, *) {
                let candidateFormats = videoDevice.formats.filter { format in
                    guard let range = format.videoSupportedFrameRateRanges.first else { return false }
                    return range.minFrameRate <= targetFps && range.maxFrameRate >= targetFps
                }

                if let bestFormat = candidateFormats.max(by: { lhs, rhs in
                    if lhs.videoFieldOfView != rhs.videoFieldOfView {
                        return lhs.videoFieldOfView < rhs.videoFieldOfView
                    }
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
                        print("Using front format: \(dims.width)x\(dims.height), FOV \(String(format: "%.2f", fov))°, target \(targetFps) fps")

                        videoDevice.unlockForConfiguration()
                    } catch {
                        print("Failed to configure front camera format: \(error)")
                    }
                } else {
                    print("No front formats support target fps \(targetFps); using default.")
                }
            }

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
        }
    }

    func startRecording() {
        let filename = "landscape4k_\(UUID().uuidString).mov"
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
                        kCVPixelFormatType_32BGRA,
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
        }

        let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
        let sourceExtent = sourceImage.extent

        let targetWidth = sourceExtent.height * 16.0 / 9.0
        let cropX = (sourceExtent.width - targetWidth) / 2.0
        let cropRect = CGRect(x: cropX,
                              y: 0,
                              width: targetWidth,
                              height: sourceExtent.height)

        let cropped = sourceImage.cropped(to: cropRect)
        let rotated = cropped.oriented(.right)

        var newBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputWidth,
            outputHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &newBuffer
        )

        guard let newBuffer else { return }

        ciContext.render(rotated, to: newBuffer)

        adaptor.append(newBuffer, withPresentationTime: timestamp)
    }

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              let _ = sessionStartTime,
              let audioInput = audioInput,
              audioInput.isReadyForMoreMediaData else {
            return
        }

        audioInput.append(sampleBuffer)
    }
}

// MARK: - Delegates

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
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
