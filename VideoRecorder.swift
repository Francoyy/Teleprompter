import Foundation
import AVFoundation
import UIKit
import Combine
import VideoToolbox

// --- MODIFICATION: Renamed enum case and updated description ---
enum AspectRatio: Int, CustomStringConvertible {
    case nineSixteen = 0 // Vertical
    case oneOne = 1      // Square (using a 1:1 sensor source)
    
    var description: String {
        switch self {
        case .nineSixteen: return "9:16"
        case .oneOne: return "1:1"
        }
    }
}

class VideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published private(set) var selectedAspectRatio: AspectRatio = .nineSixteen
    @Published var previewImage: CGImage?
    // --- MODIFICATION: New published property to inform the UI about hardware support ---
    @Published var isOneOneModeAvailable: Bool = false

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
    
    // --- MODIFICATION: New helper to check for 1:1 hardware support ---
    private func checkIfOneOneModeIsAvailable() {
        guard let videoDevice = getBestFrontCamera() else {
            DispatchQueue.main.async { self.isOneOneModeAvailable = false }
            return
        }
        
        let hasOneOneFormat = videoDevice.formats.contains { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Specifically look for a square format. 3840x3840 is common on modern devices.
            return dims.width == dims.height && dims.width >= 1920
        }
        
        DispatchQueue.main.async {
            self.isOneOneModeAvailable = hasOneOneFormat
        }
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
        // --- MODIFICATION: Check for hardware capabilities on setup ---
        checkIfOneOneModeIsAvailable()

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
        // --- MODIFICATION: Prevent switching to an unavailable mode ---
        if ratio == .oneOne && !isOneOneModeAvailable {
            print("Cannot switch to 1:1 mode, not supported by this device.")
            return
        }
        
        if selectedAspectRatio != ratio {
            print("\n[DEBUG] --- SWITCHING ASPECT RATIO ---")
            print("[DEBUG] From: \(selectedAspectRatio.description) To: \(ratio.description)")
            
            session.stopRunning()
            
            self.selectedAspectRatio = ratio
            UserDefaults.standard.set(ratio.rawValue, forKey: aspectRatioKey)

            session.beginConfiguration()
            configureCameraForAspectRatio(ratio)
            session.commitConfiguration()
            
            DispatchQueue.global(qos: .background).async {
                self.session.startRunning()
            }
            print("[DEBUG] --- SWITCH COMPLETE ---\n")
        }
    }
    
    private func configureCameraForAspectRatio(_ ratio: AspectRatio) {
        print("[DEBUG] Configuring camera for \(ratio.description)")
        guard let videoDevice = getBestFrontCamera() else {
            print("â Œ Could not get front camera.")
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
            print("â Œ Failed to create video device input: \(error)")
            return
        }
        
        var bestFormat: AVCaptureDevice.Format?
        
        if ratio == .oneOne {
            bestFormat = videoDevice.formats.first { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == dims.height && dims.width == 3840
            }
        } else { // .nineSixteen
            let targetFps: Double = 30.0
            let targetRatio: Double = 16.0 / 9.0
            let candidates = videoDevice.formats.filter { format in
                let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                guard let range = format.videoSupportedFrameRateRanges.first else { return false }
                return pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
                       range.maxFrameRate >= targetFps
            }
            bestFormat = candidates.sorted(by: { lhs, rhs in
                let dim1 = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let dim2 = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let r1 = Double(dim1.width) / Double(dim1.height)
                let r2 = Double(dim2.width) / Double(dim2.height)
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
                print("â Œ Lock for configuration failed: \(error)")
            }
        } else {
            print("[DEBUG] No specific format found for \(ratio.description); using device default.")
            // --- THIS IS THE CORRECTED PART ---
            // 'activeFormat' is not optional, so we access it directly.
            let format = videoDevice.activeFormat
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            nativeFormatWidth = Int(dims.width)
            nativeFormatHeight = Int(dims.height)
            // --- END OF CORRECTION ---
        }
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            print("â Œ Could not re-add video output to session.")
            return
        }
        
        guard let connection = videoOutput.connection(with: .video) else {
            print("â Œ Failed to get new video connection.")
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
    
    func startRecording() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let outputURL = paths[0].appendingPathComponent("\(UUID().uuidString).mov")
        currentOutputURL = outputURL

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            var videoSettings: [String: Any] = [:]
            
            // --- MODIFICATION: Updated logic for .oneOne ---
            if selectedAspectRatio == .oneOne {
                // Use the native sensor dimensions, which should be square
                videoSettings = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: nativeFormatWidth,
                    AVVideoHeightKey: nativeFormatHeight,
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
            print("â Œ Failed to start recording: \(error)")
        }
    }
    
    // ... (rest of the file is unchanged: stopRecording, cancelCurrentRecording, captureOutput delegate)
    // ...
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
