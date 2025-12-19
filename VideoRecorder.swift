import Foundation
import AVFoundation
import UIKit
import Combine

enum AspectRatio: Int {
    case nineSixteen = 0 // Vertical
    case sixteenNine = 1 // Horizontal
}

class VideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published private(set) var selectedAspectRatio: AspectRatio = .nineSixteen

    // Export/progress state
    @Published var isExporting: Bool = false
    @Published var exportProgress: Float = 0.0

    private let aspectRatioKey = "selectedAspectRatio"

    let session = AVCaptureSession()

    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    
    // Dimensions of the active format in LANDSCAPE (Sensor native)
    // e.g. 4032 (W) x 3024 (H)
    private var nativeFormatWidth: Int = 0
    private var nativeFormatHeight: Int = 0

    private var currentOutputURL: URL?
    private var sessionStartTime: CMTime?
    
    override init() {
        super.init()

        // Load persisted aspect ratio if present
        let storedValue = UserDefaults.standard.integer(forKey: aspectRatioKey)
        if let storedRatio = AspectRatio(rawValue: storedValue) {
            selectedAspectRatio = storedRatio
        }
    }
    
    // MARK: - Optional: Audio Session Configuration (iOS / visionOS)
    private func configureAudioSessionIfNeeded() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord,
                                         mode: .videoRecording,
                                         options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            print("AVAudioSession configuration failed: \(error)")
        }
        #endif
    }
    
    // MARK: - Camera Selection
    func getBestFrontCamera() -> AVCaptureDevice? {
        if let ultraWide = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: .front
        ).devices.first {
            return ultraWide
        }
        
        if let wide = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices.first {
            return wide
        }
        
        return nil
    }
    
    // MARK: - Session Setup
    func setupSession() {
        configureAudioSessionIfNeeded()

        session.beginConfiguration()
        session.sessionPreset = .inputPriority // Allow manual format

        // 1. Video Output Setup
        let videoQueue = DispatchQueue(label: "videoQueue")
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        // 2. Configure Input & Format using the persisted aspect ratio
        configureCameraForAspectRatio(selectedAspectRatio)

        // 3. Audio
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioIn = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioIn) { session.addInput(audioIn) }
            } catch {
            }
        }
        
        let audioQueue = DispatchQueue(label: "audioQueue")
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        startSession()
    }
    
    // MARK: - Aspect Ratio Switching
    func switchAspectRatio(_ ratio: AspectRatio) {
        guard !isRecording else { return }
        if selectedAspectRatio != ratio {
            self.selectedAspectRatio = ratio
            UserDefaults.standard.set(ratio.rawValue, forKey: aspectRatioKey)

            session.beginConfiguration()
            configureCameraForAspectRatio(ratio)
            session.commitConfiguration()
        }
    }
    
    private func configureCameraForAspectRatio(_ ratio: AspectRatio) {
        guard let videoDevice = getBestFrontCamera() else { return }
        
        // Remove existing video inputs
        session.inputs.forEach { input in
            if let devInput = input as? AVCaptureDeviceInput, devInput.device.hasMediaType(.video) {
                session.removeInput(input)
            }
        }
        
        // Add Input
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            return
        }
        
        // Find Best Format
        let targetFps: Double = 30.0
        let targetRatio: Double = (ratio == .nineSixteen) ? (16.0/9.0) : (4.0/3.0)
        
        let candidates = videoDevice.formats.filter { format in
            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let is420v = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            guard let range = format.videoSupportedFrameRateRanges.first else { return false }
            return is420v && range.maxFrameRate >= targetFps
        }
        
        if let bestFormat = candidates.sorted(by: { lhs, rhs in
            let dim1 = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let dim2 = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            
            let w1 = Double(dim1.width); let h1 = Double(dim1.height)
            let w2 = Double(dim2.width); let h2 = Double(dim2.height)
            
            let r1 = w1/h1; let r2 = w2/h2
            let diff1 = abs(r1 - targetRatio); let diff2 = abs(r2 - targetRatio)
            
            if abs(diff1 - diff2) < 0.01 { return w1 > w2 }
            return diff1 < diff2
        }).first {
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.activeFormat = bestFormat
                let duration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                videoDevice.activeVideoMinFrameDuration = duration
                videoDevice.activeVideoMaxFrameDuration = duration
                videoDevice.videoZoomFactor = 1.0
                videoDevice.unlockForConfiguration()
                
                let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
                nativeFormatWidth = Int(dims.width)
                nativeFormatHeight = Int(dims.height)
                
            } catch {
            }
        }
        
        // Re-apply Portrait Orientation to the Connection
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
    
    func startSession() {
        DispatchQueue.global(qos: .background).async { self.session.startRunning() }
    }
    
    func stopSession() { session.stopRunning() }

    // MARK: - Recording
    func startRecording() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let outputURL = paths[0].appendingPathComponent("\(UUID().uuidString).mov")
        currentOutputURL = outputURL

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            var videoSettings: [String: Any] = [:]
            
            if selectedAspectRatio == .nineSixteen {
                let w = nativeFormatHeight
                let h = nativeFormatWidth
                
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: w,
                    AVVideoHeightKey: h,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
                ]
                
            } else {
                let outputWidth = nativeFormatHeight
                let outputHeight = Int(Double(outputWidth) * 9.0 / 16.0)
                
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: outputWidth,
                    AVVideoHeightKey: outputHeight,
                    AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
                ]
            }
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            videoInput?.transform = CGAffineTransform.identity

            if let writer = writer, let videoInput = videoInput, writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
            
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            
            if let writer = writer, let audioInput = audioInput, writer.canAdd(audioInput) {
                writer.add(audioInput)
            }

            writer?.startWriting()
            isRecording = true
            sessionStartTime = nil
            
        } catch {
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
            guard let self = self else { return }
            let url = self.currentOutputURL
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            
            DispatchQueue.main.async {
                completion(url)
            }
        }
    }

    // MARK: - Cancel Recording (trash icon)
    func cancelCurrentRecording(completion: (() -> Void)? = nil) {
        guard let writer = writer, isRecording else {
            completion?()
            return
        }

        isRecording = false
        sessionStartTime = nil

        let urlToDelete = currentOutputURL

        writer.finishWriting { [weak self] in
            guard let self = self else { return }

            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil

            if let url = urlToDelete {
                try? FileManager.default.removeItem(at: url)
            }
            self.currentOutputURL = nil

            DispatchQueue.main.async {
                completion?()
            }
        }
    }
    
    // MARK: - Video Speed Processing with Progress
    func speedUpVideo(
        inputURL: URL,
        speedIncreasePercent: Int,
        progressHandler: ((Float) -> Void)? = nil,
        completion: @escaping (URL?) -> Void
    ) {
        // If speed increase is 0, just return the original
        guard speedIncreasePercent > 0 else {
            completion(inputURL)
            return
        }
        
        let speedMultiplier = 1.0 + (Double(speedIncreasePercent) / 100.0)
        let asset = AVAsset(url: inputURL)
        
        let composition = AVMutableComposition()
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(nil)
            return
        }
        
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(nil)
            return
        }
        
        var compositionAudioTrack: AVMutableCompositionTrack?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        
        do {
            let duration = asset.duration
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            
            if let audioTrack = asset.tracks(withMediaType: .audio).first,
               let compositionAudioTrack = compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            }
            
            let newDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / speedMultiplier)
            
            compositionVideoTrack.scaleTimeRange(timeRange, toDuration: newDuration)
            if let compositionAudioTrack = compositionAudioTrack {
                compositionAudioTrack.scaleTimeRange(timeRange, toDuration: newDuration)
            }
            
            let videoSize = videoTrack.naturalSize
            let transform = videoTrack.preferredTransform
            
            var renderSize = videoSize
            let angle = atan2(transform.b, transform.a)
            let isPortrait = abs(angle) == .pi / 2
            
            if isPortrait {
                renderSize = CGSize(width: videoSize.height, height: videoSize.width)
            }
            
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: newDuration)
            
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            layerInstruction.setTransform(transform, at: .zero)
            
            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]
            
            let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            
            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                print("Failed to create export session")
                completion(nil)
                return
            }
            
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mov
            exportSession.videoComposition = videoComposition

            // Reset/export state
            DispatchQueue.main.async {
                self.isExporting = true
                self.exportProgress = 0.0
            }

            // Progress polling timer (0.2s)
            let progressTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            progressTimer.schedule(deadline: .now(), repeating: 0.2)
            progressTimer.setEventHandler { [weak self, weak exportSession] in
                guard let self = self,
                      let session = exportSession else {
                    progressTimer.cancel()
                    return
                }
                let p = session.progress
                DispatchQueue.main.async {
                    self.exportProgress = p
                    progressHandler?(p)
                }
                // if finished, we'll cancel in export completion
            }
            progressTimer.resume()
            
            exportSession.exportAsynchronously {
                // Stop the progress timer
                progressTimer.cancel()
                
                DispatchQueue.main.async {
                    self.isExporting = false
                }

                DispatchQueue.main.async {
                    switch exportSession.status {
                    case .completed:
                        print("Export completed successfully")
                        completion(outputURL)
                    case .failed:
                        print("Export failed: \(String(describing: exportSession.error))")
                        completion(nil)
                    case .cancelled:
                        print("Export cancelled")
                        completion(nil)
                    default:
                        completion(nil)
                    }
                }
            }
            
        } catch {
            print("Error creating composition: \(error)")
            completion(nil)
        }
    }
}

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer = writer, isRecording else { return }
        
        if sessionStartTime == nil {
            sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: sessionStartTime!)
        }
        
        if output == videoOutput, let videoInput = videoInput, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        } else if output == audioOutput, let audioInput = audioInput, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }
}
