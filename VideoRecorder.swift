//
//  VideoRecorder.swift
//  Yuan_Teleprompter2
//

import AVFoundation
import Combine

enum AspectRatio: Int {
    case nineSixteen = 0  // 9:16 - Native portrait recording
    case sixteenNine = 1  // 16:9 - Cropped from 4:3 wide FOV
}

class VideoRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var selectedAspectRatio: AspectRatio = .nineSixteen
    
    private let aspectRatioKey = "selectedAspectRatio"
    
    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStartTime: CMTime?
    private var currentOutputURL: URL?
    
    // Format dimensions - used differently based on aspect ratio
    private var nativeFormatWidth: Int = 1920
    private var nativeFormatHeight: Int = 1080
    
    override init() {
        super.init()
        
        // Load persisted aspect ratio if present
        let storedValue = UserDefaults.standard.integer(forKey: aspectRatioKey)
        if let storedRatio = AspectRatio(rawValue: storedValue) {
            selectedAspectRatio = storedRatio
        }
    }
    
    // MARK: - Audio Session Configuration
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
    
    /// Get best front camera based on aspect ratio needs
    /// - For 9:16: Use standard wide-angle camera
    /// - For 16:9: Prefer ultra-wide for better FOV to crop from
    func getBestFrontCamera(for aspectRatio: AspectRatio) -> AVCaptureDevice? {
        if aspectRatio == .sixteenNine {
            // For 16:9, prefer ultra-wide for wider FOV to crop from
            if let ultraWide = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInUltraWideCamera],
                mediaType: .video,
                position: .front
            ).devices.first {
                return ultraWide
            }
        }
        
        // For 9:16 or fallback: use standard wide-angle
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
                print("Audio input setup failed: \(error)")
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
    
    // MARK: - Camera Configuration (Main Router)
    
    private func configureCameraForAspectRatio(_ ratio: AspectRatio) {
        // Remove existing video inputs
        session.inputs.forEach { input in
            if let devInput = input as? AVCaptureDeviceInput, devInput.device.hasMediaType(.video) {
                session.removeInput(input)
            }
        }
        
        switch ratio {
        case .nineSixteen:
            configureNativeNineSixteen()
        case .sixteenNine:
            configureCroppedSixteenNine()
        }
        
        // Apply Portrait Orientation to the Connection
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
    
    // MARK: - 9:16 Configuration (Simple Native)
    
    /// Configure for native 9:16 portrait recording
    /// This is the standard use case - simply use the highest resolution 16:9 format available
    private func configureNativeNineSixteen() {
        guard let videoDevice = getBestFrontCamera(for: .nineSixteen) else {
            print("No front camera available for 9:16")
            return
        }
        
        // Add Input
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            print("Failed to create video input: \(error)")
            return
        }
        
        // Find highest resolution 16:9 format at 30fps
        let targetFps: Double = 30.0
        let targetRatio: Double = 16.0 / 9.0
        let ratioTolerance: Double = 0.01
        
        let candidates = videoDevice.formats.filter { format in
            // Check pixel format
            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let is420v = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            guard is420v else { return false }
            
            // Check frame rate support
            guard let range = format.videoSupportedFrameRateRanges.first,
                  range.maxFrameRate >= targetFps else { return false }
            
            // Check aspect ratio (16:9)
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let formatRatio = Double(dims.width) / Double(dims.height)
            let ratioDiff = abs(formatRatio - targetRatio)
            
            return ratioDiff < ratioTolerance
        }
        
        // Sort by resolution (highest first)
        if let bestFormat = candidates.sorted(by: { lhs, rhs in
            let dim1 = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let dim2 = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let pixels1 = Int(dim1.width) * Int(dim1.height)
            let pixels2 = Int(dim2.width) * Int(dim2.height)
            return pixels1 > pixels2
        }).first {
            applyFormat(bestFormat, to: videoDevice, fps: targetFps)
            
            let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
            print("✅ 9:16 Native: Selected \(dims.width)x\(dims.height) @ \(targetFps)fps")
        } else {
            print("⚠️ No suitable 16:9 format found, using default")
        }
    }
    
    // MARK: - 16:9 Configuration (Complex Cropped)

    /// Configure for 16:9 landscape recording while holding phone vertically
    /// This uses the widest FOV format (closest to 1:1 square) and crops it to 16:9
    private func configureCroppedSixteenNine() {
        guard let videoDevice = getBestFrontCamera(for: .sixteenNine) else {
            print("No front camera available for 16:9")
            return
        }
        
        // Add Input
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            print("Failed to create video input: \(error)")
            return
        }
        
        // Find format closest to 1:1 (square) for maximum horizontal FOV when held vertically
        let targetFps: Double = 30.0
        let targetRatio: Double = 1.0  // 1:1 square ratio
        
        let candidates = videoDevice.formats.filter { format in
            // Check pixel format
            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let is420v = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            guard is420v else { return false }
            
            // Check frame rate support
            guard let range = format.videoSupportedFrameRateRanges.first,
                  range.maxFrameRate >= targetFps else { return false }
            
            return true
        }
        
        // Sort by: 1) closest to 1:1 ratio, 2) highest resolution
        if let bestFormat = candidates.sorted(by: { lhs, rhs in
            let dim1 = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let dim2 = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            
            let w1 = Double(dim1.width); let h1 = Double(dim1.height)
            let w2 = Double(dim2.width); let h2 = Double(dim2.height)
            
            let r1 = w1 / h1; let r2 = w2 / h2
            let diff1 = abs(r1 - targetRatio); let diff2 = abs(r2 - targetRatio)
            
            // If ratios are similar (within 5%), prefer higher resolution
            if abs(diff1 - diff2) < 0.05 {
                let pixels1 = w1 * h1
                let pixels2 = w2 * h2
                return pixels1 > pixels2
            }
            // Otherwise prefer closer ratio match to 1:1
            return diff1 < diff2
        }).first {
            applyFormat(bestFormat, to: videoDevice, fps: targetFps)
            
            let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
            let actualRatio = Double(dims.width) / Double(dims.height)
            print("✅ 16:9 Cropped: Selected \(dims.width)x\(dims.height) (ratio: \(String(format: "%.2f", actualRatio)):1) @ \(targetFps)fps, will crop to 16:9")
        } else {
            print("⚠️ No suitable format found for 16:9 cropping")
        }
    }

    
    // MARK: - Format Application Helper
    
    private func applyFormat(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice, fps: Double) {
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.videoZoomFactor = 1.0
            
            device.unlockForConfiguration()
            
            // Store native format dimensions
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            nativeFormatWidth = Int(dims.width)
            nativeFormatHeight = Int(dims.height)
            
        } catch {
            print("Failed to apply format: \(error)")
        }
    }
    
    func startSession() {
        DispatchQueue.global(qos: .background).async {
            self.session.startRunning()
        }
    }
    
    func stopSession() {
        session.stopRunning()
    }

    // MARK: - Recording
    
    func startRecording() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let outputURL = paths[0].appendingPathComponent("\(UUID().uuidString).mov")
        currentOutputURL = outputURL

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            let videoSettings = createVideoSettings(for: selectedAspectRatio)
            
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
            print("Failed to start recording: \(error)")
        }
    }
    
    // MARK: - Video Settings Creation
    
    /// Create appropriate video settings based on aspect ratio mode
    private func createVideoSettings(for ratio: AspectRatio) -> [String: Any] {
        switch ratio {
        case .nineSixteen:
            return createNativeNineSixteenSettings()
        case .sixteenNine:
            return createCroppedSixteenNineSettings()
        }
    }
    
    /// Video settings for native 9:16 recording
    /// Simply swap width/height since we're in portrait orientation
    private func createNativeNineSixteenSettings() -> [String: Any] {
        // Native format is 16:9 landscape (e.g., 1920x1080)
        // In portrait orientation, this becomes 1080x1920 (9:16)
        let outputWidth = nativeFormatHeight
        let outputHeight = nativeFormatWidth
        
        print("📹 9:16 Recording: \(outputWidth)x\(outputHeight)")
        
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
        ]
    }
    
    /// Video settings for cropped 16:9 recording
    /// Crop 4:3 format to 16:9, then rotate for portrait orientation
    private func createCroppedSixteenNineSettings() -> [String: Any] {
        // Native format is 4:3 (e.g., 1440x1080)
        // In portrait, height becomes width: 1080
        // Calculate 16:9 height from that width: 1080 * 9/16 = 607.5 ≈ 608
        let outputWidth = nativeFormatHeight
        let outputHeight = Int(Double(outputWidth) * 9.0 / 16.0)
        
        print("📹 16:9 Cropped Recording: \(outputWidth)x\(outputHeight) (cropped from \(nativeFormatWidth)x\(nativeFormatHeight))")
        
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill, // Crop to fit
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
        ]
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

    // MARK: - Cancel Recording
    
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
}

// MARK: - AVCapture Delegates

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
