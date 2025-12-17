import Foundation
import AVFoundation
import UIKit
import Combine
import Vision
import CoreImage // Added CoreImage for blur processing

enum AspectRatio {
    case nineSixteen // Vertical
    case sixteenNine // Horizontal
}

class VideoRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published private(set) var selectedAspectRatio: AspectRatio = .nineSixteen
    @Published var isBackgroundBlurEnabled = false

    let session = AVCaptureSession()

    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    // Dimensions of the active format in LANDSCAPE (Sensor native)
    // e.g. 4032 (W) x 3024 (H)
    private var nativeFormatWidth: Int = 0
    private var nativeFormatHeight: Int = 0

    private var currentOutputURL: URL?
    private var sessionStartTime: CMTime?
    
    // Vision framework for person segmentation
    private let segmentationQueue = DispatchQueue(label: "segmentationQueue", qos: .userInitiated)
    private var segmentationRequest: VNGeneratePersonSegmentationRequest?
    
    // Optimization: Frame skipping and buffer reuse
    private var frameCounter: Int = 0
    private var lastMask: CVPixelBuffer?
    private var pixelBufferPool: CVPixelBufferPool?
    
    // Core Image Context for GPU rendering
    private let ciContext = CIContext()
    
    // MARK: - Background Blur Control
    func setBackgroundBlur(_ enabled: Bool) {
        isBackgroundBlurEnabled = enabled
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
        session.sessionPreset = .inputPriority

        let videoQueue = DispatchQueue(label: "videoQueue", qos: .userInitiated)
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        configureCameraForAspectRatio(.nineSixteen)

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
        
        // Initialize segmentation request with FAST quality for better performance
        if #available(iOS 15.0, *) {
            segmentationRequest = VNGeneratePersonSegmentationRequest()
            segmentationRequest?.qualityLevel = .fast  // Changed from .balanced to .fast
            segmentationRequest?.outputPixelFormat = kCVPixelFormatType_OneComponent8
        }
        
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
            return
        }
        
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
        
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
    
    func startSession() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
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
            
            // When background blur is enabled, use 1080p for better performance
            if isBackgroundBlurEnabled {
                if selectedAspectRatio == .nineSixteen {
                    // 9:16 portrait at 1080p (1080x1920)
                    videoSettings = [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: 1080,
                        AVVideoHeightKey: 1920,
                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000]
                    ]
                } else {
                    // 16:9 landscape at 1080p (1920x1080)
                    videoSettings = [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: 1920,
                        AVVideoHeightKey: 1080,
                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000]
                    ]
                }
            } else {
                // Original 4K settings when blur is disabled
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
            }
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            videoInput?.transform = CGAffineTransform.identity

            if let writer = writer, let videoInput = videoInput, writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
            
            // Create pixel buffer adaptor for blur processing
            if isBackgroundBlurEnabled {
                let outputWidth = selectedAspectRatio == .nineSixteen ? 1080 : 1920
                let outputHeight = selectedAspectRatio == .nineSixteen ? 1920 : 1080
                
                let sourcePixelBufferAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: outputWidth,
                    kCVPixelBufferHeightKey as String: outputHeight,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput!,
                    sourcePixelBufferAttributes: sourcePixelBufferAttributes
                )
                
                // Create pixel buffer pool for reuse (OPTIMIZATION)
                let poolAttributes: [String: Any] = [
                    kCVPixelBufferPoolMinimumBufferCountKey as String: 3
                ]
                CVPixelBufferPoolCreate(
                    kCFAllocatorDefault,
                    poolAttributes as CFDictionary,
                    sourcePixelBufferAttributes as CFDictionary,
                    &pixelBufferPool
                )
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
            frameCounter = 0
            lastMask = nil
            
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard let writer = writer, isRecording else {
            completion(nil)
            return
        }

        isRecording = false
        sessionStartTime = nil
        lastMask = nil
        pixelBufferPool = nil

        writer.finishWriting { [weak self] in
            self?.writer = nil
            self?.videoInput = nil
            self?.audioInput = nil
            self?.pixelBufferAdaptor = nil
            
            DispatchQueue.main.async { completion(self?.currentOutputURL) }
        }
    }
    
    // MARK: - Background Blur Processing
    @available(iOS 15.0, *)
    private func applyTestSegmentation(to pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let request = segmentationRequest else { return }
        
        // 1. Perform Vision Segmentation
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return }
            lastMask = result.pixelBuffer
        } catch {
            print("Segmentation error: \(error)")
            return
        }
        
        guard let maskBuffer = lastMask else { return }
        
        // 2. Prepare Output Buffer (Reuse from pool)
        var outputPixelBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        }
        
        guard let finalBuffer = outputPixelBuffer else { return }
        
        // 3. Core Image Processing Pipeline
        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        
        // Get dimensions
        let targetWidth = CGFloat(CVPixelBufferGetWidth(finalBuffer))
        let targetHeight = CGFloat(CVPixelBufferGetHeight(finalBuffer))
        
        let inputWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let inputHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        let maskWidth = CGFloat(CVPixelBufferGetWidth(maskBuffer))
        let maskHeight = CGFloat(CVPixelBufferGetHeight(maskBuffer))
        
        // Scale Input to Target Size (1080p)
        let inputScaleX = targetWidth / inputWidth
        let inputScaleY = targetHeight / inputHeight
        let scaledInput = inputImage.transformed(by: CGAffineTransform(scaleX: inputScaleX, y: inputScaleY))
        
        // Scale Mask to Target Size
        let maskScaleX = targetWidth / maskWidth
        let maskScaleY = targetHeight / maskHeight
        let scaledMask = maskImage.transformed(by: CGAffineTransform(scaleX: maskScaleX, y: maskScaleY))
        
        // Apply Gaussian Blur to the Background
        let blurFilter = CIFilter(name: "CIGaussianBlur")
        blurFilter?.setValue(scaledInput, forKey: kCIInputImageKey)
        blurFilter?.setValue(20.0, forKey: kCIInputRadiusKey) // Adjust blur strength (radius) here
        
        guard let blurredBackground = blurFilter?.outputImage else { return }
        
        // Blend Foreground and Background using Mask
        // Mask: White (1.0) = Foreground (Person), Black (0.0) = Background (Blur)
        let blendFilter = CIFilter(name: "CIBlendWithMask")
        blendFilter?.setValue(scaledInput, forKey: kCIInputImageKey) // Foreground (Original Color)
        blendFilter?.setValue(blurredBackground, forKey: kCIInputBackgroundImageKey) // Background (Blurred)
        blendFilter?.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        
        guard let outputImage = blendFilter?.outputImage else { return }
        
        // 4. Render to Output Buffer
        // CIContext handles color conversion (YUV -> BGRA) automatically
        ciContext.render(outputImage, to: finalBuffer)
        
        // 5. Pass to Writer
        appendProcessedBuffer(finalBuffer, presentationTime: presentationTime)
    }
    
    private func appendProcessedBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let adaptor = pixelBufferAdaptor,
              let videoInput = videoInput,
              videoInput.isReadyForMoreMediaData else {
            return
        }
        
        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }
}

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer = writer, isRecording else { return }
        
        if sessionStartTime == nil {
            sessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: sessionStartTime!)
        }
        
        if output == videoOutput {
            if isBackgroundBlurEnabled, #available(iOS 15.0, *) {
                // Apply background blur processing
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                applyTestSegmentation(to: pixelBuffer, presentationTime: presentationTime)
            } else {
                // Normal recording without blur
                if let videoInput = videoInput, videoInput.isReadyForMoreMediaData {
                    videoInput.append(sampleBuffer)
                }
            }
        } else if output == audioOutput, let audioInput = audioInput, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }
}
