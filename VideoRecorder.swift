import Foundation
import AVFoundation
import UIKit
import Combine

enum AspectRatio {
    case nineSixteen // Vertical
    case sixteenNine // Horizontal
}

class VideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published private(set) var selectedAspectRatio: AspectRatio = .nineSixteen

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
    
    // MARK: - Optional: Audio Session Configuration (iOS / visionOS)
    /// Configure AVAudioSession so the system's audio stack is in a sane
    /// state before using AVCapture audio. This can reduce internal
    /// FigAudioSession warnings.
    private func configureAudioSessionIfNeeded() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // playAndRecord allows microphone + playback, mode tuned for video.
            try audioSession.setCategory(.playAndRecord,
                                         mode: .videoRecording,
                                         options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            // We don't surface this to the user; failure just means we might
            // see some extra internal warnings.
            print("AVAudioSession configuration failed: \(error)")
        }
        #endif
    }

    // MARK: - Camera Selection
    func getBestFrontCamera() -> AVCaptureDevice? {
        // STRICT PRIORITY: Ultra Wide First
        if let ultraWide = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: .front
        ).devices.first {
            return ultraWide
        }
        
        // Fallback only if Ultra Wide is missing
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
        // ensure audio session is in a reasonable state before capture.
        configureAudioSessionIfNeeded()

        session.beginConfiguration()
        session.sessionPreset = .inputPriority // Allow manual format

        // 1. Video Output Setup (Add this first so connection exists when adding input)
        let videoQueue = DispatchQueue(label: "videoQueue")
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        // 2. Configure Input & Format (This will also set the connection orientation)
        configureCameraForAspectRatio(.nineSixteen)

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
            session.beginConfiguration()
            configureCameraForAspectRatio(ratio)
            session.commitConfiguration()
        }
    }
    
    private func configureCameraForAspectRatio(_ ratio: AspectRatio) {
        guard let videoDevice = getBestFrontCamera() else { return }
        
        // 1. Remove existing video inputs to ensure clean slate
        session.inputs.forEach { input in
            if let devInput = input as? AVCaptureDeviceInput, devInput.device.hasMediaType(.video) {
                session.removeInput(input)
            }
        }
        
        // 2. Add Input
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            return
        }
        
        // 3. Find Best Format
        // 9:16 -> Hunt for 16:9 native (3840x2160)
        // 16:9 -> Hunt for 4:3 native (4032x3024)
        
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
        
        // 4. Re-apply Portrait Orientation to the Connection
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
            
            // NOTE: The buffer coming from captureOutput is now guaranteed to be PORTRAIT.
            // If Format is 4032x3024 (Landscape), Buffer is 3024x4032 (Portrait).
            
            if selectedAspectRatio == .nineSixteen {
                // 9:16 MODE (Vertical 4K)
                let w = nativeFormatHeight // 2160
                let h = nativeFormatWidth  // 3840
                
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: w,
                    AVVideoHeightKey: h,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
                ]
                
            } else {
                // 16:9 MODE (Horizontal Crop)
                let outputWidth = nativeFormatHeight // 3024
                let outputHeight = Int(Double(outputWidth) * 9.0 / 16.0) // 1701
                
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
            videoInput?.transform = CGAffineTransform.identity // No rotation

            if let writer = writer, let videoInput = videoInput, writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
            
            // Audio
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
    /// Cancel the current recording:
    /// - stops writing
    /// - deletes the temporary file
    /// - does NOT save or process anything
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
    
    // MARK: - Video Speed Processing
    func speedUpVideo(inputURL: URL, speedIncreasePercent: Int, completion: @escaping (URL?) -> Void) {
        // If speed increase is 0, just return the original
        guard speedIncreasePercent > 0 else {
            completion(inputURL)
            return
        }
        
        // Calculate the time scale factor
        // If speedIncreasePercent is 10, we want 1.10x speed (play 10% faster)
        let speedMultiplier = 1.0 + (Double(speedIncreasePercent) / 100.0)
        
        let asset = AVAsset(url: inputURL)
        
        // Create composition
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
        
        // Add audio track if exists
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
            
            // Insert video
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            
            // Insert audio if exists
            if let audioTrack = asset.tracks(withMediaType: .audio).first,
               let compositionAudioTrack = compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
            }
            
            // Calculate new duration (shorter because it plays faster)
            let newDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / speedMultiplier)
            
            // Scale video time
            compositionVideoTrack.scaleTimeRange(timeRange, toDuration: newDuration)
            
            // Scale audio time
            if let compositionAudioTrack = compositionAudioTrack {
                compositionAudioTrack.scaleTimeRange(timeRange, toDuration: newDuration)
            }
            
            // Get video properties for proper orientation
            let videoSize = videoTrack.naturalSize
            let transform = videoTrack.preferredTransform
            
            // Calculate the actual render size considering transform
            var renderSize = videoSize
            let angle = atan2(transform.b, transform.a)
            let isPortrait = abs(angle) == .pi / 2
            
            if isPortrait {
                renderSize = CGSize(width: videoSize.height, height: videoSize.width)
            }
            
            // Create video composition
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 30 fps
            
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: newDuration)
            
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            layerInstruction.setTransform(transform, at: .zero)
            
            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]
            
            // Export
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
            
            exportSession.exportAsynchronously {
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
