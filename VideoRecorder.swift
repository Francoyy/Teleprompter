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
    
    // Set from selected activeFormat
    private var outputWidth: Int = 0
    private var outputHeight: Int = 0

    private var currentOutputURL: URL?
    private var sessionStartTime: CMTime?
    
    // MARK: - Debugging / Discovery
    func logAvailableFrontCameras() {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera,
            .builtInLiDARDepthCamera
        ]
        
        if #available(iOS 16.0, *) {
            deviceTypes.append(.continuityCamera)
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .front
        )

        print("\n========== FRONT CAMERA DISCOVERY ==========")
        if discoverySession.devices.isEmpty {
            print("No front cameras found.")
        } else {
            for device in discoverySession.devices {
                print("Device Name: \(device.localizedName)")
                print("Device Type: \(device.deviceType.rawValue)")
                print("Unique ID:   \(device.uniqueID)")
                print("--------------------------------------------")
            }
        }
        print("============================================\n")
    }

    // MARK: - Camera Selection Logic
    func getBestFrontCamera() -> AVCaptureDevice? {
        // 1. Try Ultra Wide first (Preferred)
        if let ultraWide = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera],
            mediaType: .video,
            position: .front
        ).devices.first {
            print("✅ Using Front Ultra Wide Camera")
            return ultraWide
        }
        
        // 2. Fallback to Wide Angle
        if let wide = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices.first {
            print("⚠️ Front Ultra Wide not found. Falling back to Standard Front Wide Camera.")
            return wide
        }
        
        return nil
    }

    func setupSession() {
        session.beginConfiguration()
        
        // 0. Log available cameras for debugging
        logAvailableFrontCameras()
        
        // Use Input Priority to respect our custom format settings
        session.sessionPreset = .inputPriority

        // 1. Find the Best Available Front Camera
        if let videoDevice = getBestFrontCamera() {
            
            // 2. Configure Format: 420v @ 4K (16:9 Priority)
            let targetFps: Double = 30.0
            
            // Filter for formats that support '420v' and our FPS
            let candidates = videoDevice.formats.filter { format in
                let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                // 420v = Video Range (Standard)
                let is420v = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                
                guard let range = format.videoSupportedFrameRateRanges.first else { return false }
                let supportsFps = range.minFrameRate <= targetFps && range.maxFrameRate >= targetFps
                
                return is420v && supportsFps
            }
            
            // Sort by Aspect Ratio (16:9 Priority) THEN Resolution
            if let bestFormat = candidates.sorted(by: { lhs, rhs in
                let dim1 = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let dim2 = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                
                let ratio1 = Double(dim1.width) / Double(dim1.height)
                let ratio2 = Double(dim2.width) / Double(dim2.height)
                let targetRatio = 16.0 / 9.0
                
                // Check if format is close to 16:9
                let is16by9_1 = abs(ratio1 - targetRatio) < 0.1
                let is16by9_2 = abs(ratio2 - targetRatio) < 0.1
                
                // Priority 1: Prefer 16:9
                if is16by9_1 && !is16by9_2 { return true }
                if !is16by9_1 && is16by9_2 { return false }
                
                // Priority 2: Higher Resolution (Width)
                return dim1.width > dim2.width
            }).first {
                
                do {
                    try videoDevice.lockForConfiguration()
                    videoDevice.activeFormat = bestFormat
                    
                    // Set FPS
                    let duration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                    videoDevice.activeVideoMinFrameDuration = duration
                    videoDevice.activeVideoMaxFrameDuration = duration
                    
                    // Ensure no digital zoom is applied
                    videoDevice.videoZoomFactor = 1.0
                    
                    videoDevice.unlockForConfiguration()
                    
                    let dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
                    outputWidth = Int(dims.width)
                    outputHeight = Int(dims.height)
                    
                    print("Selected Format: \(dims.width)x\(dims.height)")
                    
                } catch {
                    print("Error locking configuration: \(error)")
                }
            }
            
            // Add Video Input
            do {
                let input = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            } catch {
                print("Error creating video input: \(error)")
            }
            
        } else {
            print("❌ Could not find ANY front camera")
        }

        // Audio Input
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInputDevice = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInputDevice) {
                    session.addInput(audioInputDevice)
                }
            } catch {
                print("Error creating audio input: \(error)")
            }
        }

        // Video Output
        let videoQueue = DispatchQueue(label: "videoQueue")
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        // Ensure Output matches the Format (420v)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        // Rotate output for Portrait recording
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        // Audio Output
        let audioQueue = DispatchQueue(label: "audioQueue")
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        startSession()
    }
    
    func startSession() {
        DispatchQueue.global(qos: .background).async {
            self.session.startRunning()
        }
    }
    
    func stopSession() {
        session.stopRunning()
    }

    func startRecording() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let outputURL = documentsDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        currentOutputURL = outputURL

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

            // Video Settings: H.264, 4K, 420v
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputHeight, // Swap for Portrait
                AVVideoHeightKey: outputWidth,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 32_000_000, // 32 Mbps for 4K
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            
            // Expects media data in real time
            videoInput?.expectsMediaDataInRealTime = true
            
            // Rotate the metadata (not the buffer) if needed
            videoInput?.transform = CGAffineTransform.identity

            if let writer = writer, let videoInput = videoInput, writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
            
            // Audio Settings
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 64000
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true
            
            if let writer = writer, let audioInput = audioInput, writer.canAdd(audioInput) {
                writer.add(audioInput)
            }

            writer?.startWriting()
            isRecording = true
            sessionStartTime = nil // Reset time
            
        } catch {
            print("Error setting up writer: \(error)")
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
            self?.writer = nil
            self?.videoInput = nil
            self?.audioInput = nil

            if let url = self?.currentOutputURL {
                print("Video saved to: \(url.path)")
                DispatchQueue.main.async {
                    completion(url)
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil)
                }
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
        
        if output == videoOutput {
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        } else if output == audioOutput {
            if let audioInput = audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }
    }
}
