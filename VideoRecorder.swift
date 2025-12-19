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
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            } else {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
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
