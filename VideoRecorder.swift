import Foundation
import AVFoundation
import UIKit
import Combine
import VideoToolbox
import CoreImage // Import CoreImage for cropping

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
    
    // MARK: - FIX: Add CIContext for high-performance cropping
    private let ciContext = CIContext(options: nil)
    
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

        let videoQueue = DispatchQueue(label: "videoQueue")
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        
        configureCameraForAspectRatio(selectedAspectRatio)

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
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                self.session.stopRunning()
                
                DispatchQueue.main.async {
                    self.selectedAspectRatio = ratio
                }
                UserDefaults.standard.set(ratio.rawValue, forKey: self.aspectRatioKey)

                self.session.beginConfiguration()
                self.configureCameraForAspectRatio(ratio)
                self.session.commitConfiguration()
                
                self.session.startRunning()
                print("[DEBUG] --- SWITCH COMPLETE ---\n")
            }
        }
    }
    
    private func configureCameraForAspectRatio(_ ratio: AspectRatio) {
        print("[DEBUG] Configuring camera for \(ratio.description)")
        guard let videoDevice = getBestFrontCamera() else {
            print("❌ Could not get front camera.")
            return
        }
        
        session.removeOutput(videoOutput)
        session.inputs.forEach { input in
            if let devInput = input as? AVCaptureDeviceInput, devInput.device.hasMediaType(.video) {
                session.removeInput(input)
            }
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            print("❌ Failed to create video device input: \(error)")
            return
        }
        
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
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            print("❌ Could not re-add video output to session.")
            return
        }
        
        guard let connection = videoOutput.connection(with: .video) else {
            print("❌ Failed to get new video connection.")
            return
        }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            print("[DEBUG] Connection orientation set to PORTRAIT")
        }
        if connection.isVideoMirroringSupported {
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
            
            // --- THIS IS THE FIX (Part 1) ---
            // We now calculate the final video dimensions based on the user's intent.
            let outputWidth: Int
            let outputHeight: Int
            
            if selectedAspectRatio == .sixteenNine {
                // For 16:9 mode (our square mode), the output must be square.
                // We use the SHORTER of the sensor's dimensions as the side for our square.
                // e.g., for a 1920x1440 sensor, the output will be 1440x1440.
                let squareDim = min(nativeFormatWidth, nativeFormatHeight)
                outputWidth = squareDim
                outputHeight = squareDim
            } else { // .nineSixteen
                // For 9:16, the output is a direct rotation of the sensor.
                outputWidth = nativeFormatHeight
                outputHeight = nativeFormatWidth
            }
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000_000]
            ]
            
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
            
            // Check writer status for debugging
            if writer.status == .failed {
                print("❌ Writer failed with error: \(writer.error?.localizedDescription ?? "Unknown error")")
            }
            
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
        writer.cancelWriting() // Use cancelWriting for faster teardown
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

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            
            // Update the live preview with the original, uncropped buffer
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            DispatchQueue.main.async {
                self.previewImage = cgImage
            }
            
            guard let writer = writer, isRecording, let videoInput = videoInput, videoInput.isReadyForMoreMediaData else { return }
            
            if sessionStartTime == nil {
                sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startSession(atSourceTime: sessionStartTime!)
            }
            
            // --- THIS IS THE FIX (Part 2) ---
            if selectedAspectRatio == .sixteenNine {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)

                if width != height {
                    // This is the fallback case (e.g., 1440x1920 buffer). We must crop it.
                    let shorterSide = min(width, height)
                    let xOffset = (width - shorterSide) / 2
                    let yOffset = (height - shorterSide) / 2
                    
                    let cropRect = CGRect(x: xOffset, y: yOffset, width: shorterSide, height: shorterSide)
                    
                    // Create a new pixel buffer to hold the cropped image
                    var croppedPixelBuffer: CVPixelBuffer?
                    CVPixelBufferCreate(kCFAllocatorDefault, shorterSide, shorterSide, CVPixelBufferGetPixelFormatType(pixelBuffer), nil, &croppedPixelBuffer)
                    
                    guard let destinationPixelBuffer = croppedPixelBuffer else { return }

                    // Use CIImage to perform the crop
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: cropRect)
                    ciContext.render(ciImage, to: destinationPixelBuffer)
                    
                    // Create a new sample buffer with the same timing but new cropped pixel buffer
                    var newSampleBuffer: CMSampleBuffer?
                    var timingInfo: CMSampleTimingInfo = .invalid
                    CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)


                    var videoInfo: CMVideoFormatDescription?
                    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destinationPixelBuffer, formatDescriptionOut: &videoInfo)
                    
                    if let videoInfo = videoInfo {
                        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destinationPixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoInfo, sampleTiming: &timingInfo, sampleBufferOut: &newSampleBuffer)
                    }
                    
                    if let newSampleBuffer = newSampleBuffer {
                        videoInput.append(newSampleBuffer)
                    }
                } else {
                    // Buffer is already square, append directly
                    videoInput.append(sampleBuffer)
                }
            } else {
                // It's 9:16 mode, no cropping needed
                videoInput.append(sampleBuffer)
            }
            
        } else if output == audioOutput {
            guard let writer = writer, isRecording, let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
            if sessionStartTime != nil {
                audioInput.append(sampleBuffer)
            }
        }
    }
}
