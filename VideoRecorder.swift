import Foundation
import AVFoundation
import UIKit
import Combine
import VideoToolbox

enum AspectRatio: Int, CustomStringConvertible {
    case nineSixteen = 0 // Vertical
    case sixteenNine = 1 // Horizontal (using a 1:1 sensor source)
    
    var description: String {
        switch self {
        case .nineSixteen: return "9:16"
        case .sixteenNine: return "16:9 (1:1)"
        }
    }
}

class VideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published private(set) var selectedAspectRatio: AspectRatio = .nineSixteen
    @Published var previewImage: CGImage?

    private let aspectRatioKey = "selectedAspectRatio"

    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    
    private var nativeFormatWidth: Int = 0
    private var nativeFormatHeight: Int = 0

    private var currentOutputURL: URL?
    private var sessionStartTime: CMTime?
    
    override init() {
        super.init()
        let storedValue = UserDefaults.standard.integer(forKey: aspectRatioKey)
        if let storedRatio = AspectRatio(rawValue: storedValue) {
            selectedAspectRatio = storedRatio
        }
    }
    
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
    
    func setupSession() {
        configureAudioSessionIfNeeded()

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // Configure Video Output settings (but don't add it to the session yet)
        let videoQueue = DispatchQueue(label: "videoQueue")
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        
        // Configure the entire camera pipeline for the initial aspect ratio
        configureCameraForAspectRatio(selectedAspectRatio)

        // Configure Audio Input/Output
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioIn = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioIn) { session.addInput(audioIn) }
            } catch {}
        }
        let audioQueue = DispatchQueue(label: "audioQueue")
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        startSession()
    }
    
    func switchAspectRatio(_ ratio: AspectRatio) {
        guard !isRecording else { return }
        if selectedAspectRatio != ratio {
            print("\n[DEBUG] --- SWITCHING ASPECT RATIO ---")
            print("[DEBUG] From: \(selectedAspectRatio.description) To: \(ratio.description)")
            
            // --- THE DEFINITIVE FIX: STOP THE SESSION COMPLETELY ---
            // This is the critical step to ensure all underlying hardware/software state is cleared.
            session.stopRunning()
            
            self.selectedAspectRatio = ratio
            UserDefaults.standard.set(ratio.rawValue, forKey: aspectRatioKey)

            // Reconfigure the session while it's stopped
            session.beginConfiguration()
            configureCameraForAspectRatio(ratio)
            session.commitConfiguration()
            
            // --- THE DEFINITIVE FIX: RESTART THE SESSION ---
            // Now that the configuration is clean, restart the session.
            session.startRunning()
            print("[DEBUG] --- SWITCH COMPLETE ---\n")
        }
    }
    
    private func configureCameraForAspectRatio(_ ratio: AspectRatio) {
        print("[DEBUG] Configuring camera for \(ratio.description)")
        guard let videoDevice = getBestFrontCamera() else {
            print("❌ Could not get front camera.")
            return
        }
        
        // 1. REMOVE existing video input and output from the session
        session.removeOutput(videoOutput)
        session.inputs.forEach { input in
            if let devInput = input as? AVCaptureDeviceInput, devInput.device.hasMediaType(.video) {
                session.removeInput(input)
            }
        }
        
        // 2. ADD new video input
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            print("❌ Failed to create video device input: \(error)")
            return
        }
        
        // 3. FIND and SET the desired device format
        var bestFormat: AVCaptureDevice.Format?
        if ratio == .sixteenNine {
            bestFormat = videoDevice.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == 3840 && dims.height == 3840
            }
        }
        
        if bestFormat == nil {
            let targetFps: Double = 30.0
            let targetRatio: Double = (ratio == .nineSixteen) ? (16.0/9.0) : (4.0/3.0)
            let candidates = videoDevice.formats.filter { format in
                let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                guard let range = format.videoSupportedFrameRateRanges.first else { return false }
                return pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && range.maxFrameRate >= targetFps
            }
            bestFormat = candidates.sorted(by: { lhs, rhs in
                let dim1 = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let dim2 = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let r1 = Double(dim1.width)/Double(dim1.height)
                let r2 = Double(dim2.width)/Double(dim2.height)
                let diff1 = abs(r1 - targetRatio); let diff2 = abs(r2 - targetRatio)
                if abs(diff1 - diff2) < 0.01 { return dim1.width > dim2.width }
                return diff1 < diff2
            }).first
        }
        
        if let formatToUse = bestFormat {
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.activeFormat = formatToUse
                let duration = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMinFrameDuration = duration
                videoDevice.activeVideoMaxFrameDuration = duration
                videoDevice.unlockForConfiguration()
                
                let dims = CMVideoFormatDescriptionGetDimensions(formatToUse.formatDescription)
                nativeFormatWidth = Int(dims.width)
                nativeFormatHeight = Int(dims.height)
                print("[DEBUG] SENSOR LOCKED: \(nativeFormatWidth)x\(nativeFormatHeight)")
            } catch {
                print("❌ Lock for configuration failed: \(error)")
            }
        }
        
        // 4. ADD the video output back to the session. This creates a new connection.
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            print("❌ Could not re-add video output to session.")
            return
        }
        
        // 5. CONFIGURE the new connection
        guard let connection = videoOutput.connection(with: .video) else {
            print("❌ Failed to get new video connection.")
            return
        }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            print("[DEBUG] Connection orientation set to PORTRAIT")
        }
        if connection.isVideoMirroringSupported {
            // Front camera previews should be mirrored.
            connection.isVideoMirrored = true
        }
    }
    
    func startSession() {
        DispatchQueue.global(qos: .background).async { self.session.startRunning() }
    }
    
    // MARK: - Recording Logic
    func startRecording() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let outputURL = paths[0].appendingPathComponent("\(UUID().uuidString).mov")
        currentOutputURL = outputURL

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            var videoSettings: [String: Any] = [:]
            
            if selectedAspectRatio == .sixteenNine {
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 3840,
                    AVVideoHeightKey: 3840,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
                ]
            } else { // .nineSixteen
                // The output dimensions must match the rotated pixel buffer
                let w = nativeFormatHeight
                let h = nativeFormatWidth
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: w,
                    AVVideoHeightKey: h,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
                ]
            }
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            videoInput?.transform = CGAffineTransform.identity // Transform is handled by buffer orientation

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
            print("❌ Failed to start recording: \(error)")
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
            DispatchQueue.main.async { completion(url) }
        }
    }

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
            DispatchQueue.main.async { completion?() }
        }
    }
}

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                // --- CRITICAL DEBUGGING ---
                // This log shows the actual dimensions of the image data we receive.
                // It will now be correct after every switch.
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                print("[DEBUG] Pixel Buffer Received: \(width)x\(height)")
                
                var cgImage: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
                DispatchQueue.main.async {
                    self.previewImage = cgImage
                }
            }
            
            guard let writer = writer, isRecording, let videoInput = videoInput, videoInput.isReadyForMoreMediaData else { return }
            if sessionStartTime == nil {
                sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startSession(atSourceTime: sessionStartTime!)
            }
            videoInput.append(sampleBuffer)
            
        } else if output == audioOutput {
            guard let writer = writer, isRecording, let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
            if sessionStartTime != nil {
                audioInput.append(sampleBuffer)
            }
        }
    }
}
