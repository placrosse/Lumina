//
//  Camera.swift
//  CameraFramework
//
//  Created by David Okun on 8/31/17.
//  Copyright © 2017 David Okun. All rights reserved.
//

import UIKit
import AVFoundation
import CoreML

protocol LuminaCameraDelegate: class {
    func stillImageCaptured(camera: LuminaCamera, image: UIImage)
    func videoFrameCaptured(camera: LuminaCamera, frame: UIImage)
    func videoFrameCaptured(camera: LuminaCamera, frame: UIImage, predictedObjects: [LuminaPrediction]?)
    func videoRecordingCaptured(camera: LuminaCamera, videoURL: URL)
    func finishedFocus(camera: LuminaCamera)
    func detected(camera: LuminaCamera, metadata: [Any])
    func cameraSetupCompleted(camera: LuminaCamera, result: CameraSetupResult)
}

enum CameraSetupResult: String {
    typealias RawValue = String
    
    case videoPermissionDenied = "Video Permissions Denied"
    case videoPermissionRestricted = "Video Permissions Restricted"
    case videoRequiresAuthorization = "Video Permissions Require Authorization"
    case audioPermissionDenied = "Audio Permissions Denied"
    case audioPermissionRestricted = "Audio Permissions Restricted"
    case audioRequiresAuthorization = "Audio Permissions Require Authorization"
    case unknownError = "Unknown Error"
    case invalidVideoDevice = "Invalid Video Device"
    case invalidAudioDevice = "Invalid Audio Device"
    case requiresUpdate = "Requires AV Update"
    case videoSuccess = "Video Setup Success"
    case audioSuccess = "Audio Setup Success"
    
}

final class LuminaCamera: NSObject {
    weak var delegate: LuminaCameraDelegate?
    
    var torchState = false {
        didSet {
            guard let input = self.videoInput else {
                torchState = false
                return
            }
            do {
                try input.device.lockForConfiguration()
                if torchState == false {
                    if input.device.isTorchModeSupported(.off) {
                        input.device.torchMode = .off
                        input.device.unlockForConfiguration()
                    }
                } else {
                    if input.device.isTorchModeSupported(.on) {
                        input.device.torchMode = .on
                        input.device.unlockForConfiguration()
                    }
                }
            } catch {
                torchState = false
                input.device.unlockForConfiguration()
            }
        }
    }
    
    var streamFrames = false {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                updateVideo({ result in
                    if result == .videoSuccess {
                        self.start()
                    } else {
                        
                    }
                })
            }
        }
    }
    
    var trackMetadata = false {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                updateVideo({ result in
                    if result == .videoSuccess {
                        self.start()
                    } else {
                        self.delegate?.cameraSetupCompleted(camera: self, result: result)
                    }
                })
            }
        }
    }
    
    private(set) var recordingVideo: Bool = false
    
    var position: CameraPosition = .back {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                updateVideo({ result in
                    if result == .videoSuccess {
                        self.start()
                    } else {
                        self.delegate?.cameraSetupCompleted(camera: self, result: result)
                    }
                })
            }
        }
    }
    
    var resolution: CameraResolution = .highest {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                updateVideo({ result in
                    if result == .videoSuccess {
                        self.start()
                    } else {
                        self.delegate?.cameraSetupCompleted(camera: self, result: result)
                    }
                })
            }
        }
    }
    
    var frameRate: Int = 30 {
        didSet {
            if self.session.isRunning {
                self.session.stopRunning()
                updateVideo({ result in
                    if result == .videoSuccess {
                        self.start()
                    } else {
                        self.delegate?.cameraSetupCompleted(camera: self, result: result)
                    }
                })
            }
        }
    }
    
    var maxZoomScale: Float = MAXFLOAT
    
    var currentZoomScale: Float = 1.0 {
        didSet {
            updateZoom()
        }
    }
    
    fileprivate var recognizer: AnyObject?
    
    private var _streamingModel: AnyObject?
    @available(iOS 11.0, *)
    var streamingModel: MLModel? {
        get {
            return _streamingModel as? MLModel
        }
        set {
            if newValue != nil {
                _streamingModel = newValue
                recognizer = LuminaObjectRecognizer(model: newValue!)
            }
        }
    }
    
    fileprivate var session = AVCaptureSession()
    fileprivate var discoverySession: AVCaptureDevice.DiscoverySession? {
        return AVCaptureDevice.DiscoverySession(deviceTypes: [AVCaptureDevice.DeviceType.builtInWideAngleCamera], mediaType: AVMediaType.video, position: AVCaptureDevice.Position.unspecified)
    }
    fileprivate var videoInput: AVCaptureDeviceInput?
    fileprivate var audioInput: AVCaptureDeviceInput?
    fileprivate var currentCaptureDevice: AVCaptureDevice?
    fileprivate var videoBufferQueue = DispatchQueue(label: "com.Lumina.videoBufferQueue", attributes: .concurrent)
    fileprivate var metadataBufferQueue = DispatchQueue(label: "com.lumina.metadataBufferQueue")
    fileprivate var recognitionBufferQueue = DispatchQueue(label: "com.lumina.recognitionBufferQueue")
    fileprivate var sessionQueue = DispatchQueue(label: "com.lumina.sessionQueue")
    fileprivate var videoOutput: AVCaptureVideoDataOutput {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoBufferQueue)
        return output
    }
    fileprivate var photoOutput = AVCapturePhotoOutput()
    
    private var _metadataOutput: AVCaptureMetadataOutput?
    fileprivate var metadataOutput: AVCaptureMetadataOutput {
        if let existingOutput = _metadataOutput {
            return existingOutput
        }
        let output = AVCaptureMetadataOutput()
        output.setMetadataObjectsDelegate(self, queue: metadataBufferQueue)
        _metadataOutput = output
        return output
    }
    
    private var _videoFileOutput: AVCaptureMovieFileOutput?
    fileprivate var videoFileOutput: AVCaptureMovieFileOutput {
        if let existingOutput = _videoFileOutput {
            return existingOutput
        }
        let output = AVCaptureMovieFileOutput()
        _videoFileOutput = output
        return output
    }
    
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        let previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill        
        return previewLayer
    }
    
    func captureStillImage() {
        let settings = AVCapturePhotoSettings()
        settings.isAutoStillImageStabilizationEnabled = true
        settings.flashMode = self.torchState ? .on : .off
        self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func startVideoRecording() {
        recordingVideo = true
        sessionQueue.async {
            if let connection = self.videoFileOutput.connection(with: AVMediaType.video), let videoConnection = self.videoOutput.connection(with: AVMediaType.video) {
                connection.videoOrientation = videoConnection.videoOrientation
                connection.isVideoMirrored = self.position == .front ? true : false
            }
            let fileName = NSTemporaryDirectory().appending(Date().iso8601 + ".mov")
            self.videoFileOutput.startRecording(to: URL(fileURLWithPath: fileName), recordingDelegate: self)
        }
    }
    
    func stopVideoRecording() {
        recordingVideo = false
        sessionQueue.async {
            self.videoFileOutput.stopRecording()
        }
    }
    
    func updateOutputVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        self.videoBufferQueue.async {
            for output in self.session.outputs {
                guard let connection = output.connection(with: AVMediaType.video) else {
                    continue
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
        }
    }
    
    func updateAudio(_ completion: @escaping (_ result: CameraSetupResult) -> Void) {
        self.sessionQueue.async {
            switch AVCaptureDevice.authorizationStatus(for: AVMediaType.audio) {
            case .authorized:
                guard let audioInput = self.getNewAudioInputDevice() else {
                    completion(CameraSetupResult.invalidAudioDevice)
                    return
                }
                guard self.session.canAddInput(audioInput) else {
                    completion(CameraSetupResult.invalidAudioDevice)
                    return
                }
                self.audioInput = audioInput
                self.session.addInput(audioInput)
                completion(CameraSetupResult.audioSuccess)
                return
            case .denied:
                completion(CameraSetupResult.audioPermissionDenied)
                return
            case .notDetermined:
                completion(CameraSetupResult.audioRequiresAuthorization)
                return
            case .restricted:
                completion(CameraSetupResult.audioPermissionRestricted)
                return
            }
        }
    }
    
    func updateVideo(_ completion: @escaping (_ result: CameraSetupResult) -> Void) {
        self.recycleDeviceIO()
        self.sessionQueue.async {
            switch AVCaptureDevice.authorizationStatus(for: AVMediaType.video) {
            case .authorized:
                self.torchState = false
                self.session.sessionPreset = .high // set to high here so that device input can be added to session. resolution can be checked for update later
                guard let videoInput = self.getNewVideoInputDevice() else {
                    completion(CameraSetupResult.invalidVideoDevice)
                    return
                }
                
                guard self.session.canAddInput(videoInput) else {
                    completion(CameraSetupResult.invalidVideoDevice)
                    return
                }
                
                guard self.session.canAddOutput(self.videoOutput) else {
                    completion(CameraSetupResult.invalidVideoDevice)
                    return
                }
                guard self.session.canAddOutput(self.photoOutput) else {
                    completion(CameraSetupResult.invalidVideoDevice)
                    return
                }
                guard self.session.canAddOutput(self.metadataOutput) else {
                    completion(CameraSetupResult.invalidVideoDevice)
                    return
                }
                guard self.session.canAddOutput(self.videoFileOutput) else {
                    completion(CameraSetupResult.invalidVideoDevice)
                    return
                }
                self.videoInput = videoInput
                self.session.addInput(videoInput)
                if self.streamFrames {
                    self.session.addOutput(self.videoOutput)
                }
                self.session.addOutput(self.photoOutput)
                self.session.addOutput(self.videoFileOutput)
                if self.trackMetadata {
                    self.session.addOutput(self.metadataOutput)
                    self.metadataOutput.metadataObjectTypes = self.metadataOutput.availableMetadataObjectTypes
                }
                
                if self.session.canSetSessionPreset(self.resolution.foundationPreset()) {
                    self.session.sessionPreset = self.resolution.foundationPreset()
                }
                self.configureFrameRate()
                self.session.commitConfiguration()
                break
            case .denied:
                completion(CameraSetupResult.videoPermissionDenied)
                return
            case .notDetermined:
                completion(CameraSetupResult.videoRequiresAuthorization)
                return
            case .restricted:
                completion(CameraSetupResult.videoPermissionRestricted)
                return
            }
        }
    }
    
    func start() {
        self.sessionQueue.async {
            self.session.startRunning()
        }
    }
    
    func pause() {
        self.session.stopRunning()
    }
    
    func requestVideoPermissions() {
        guard let delegate = self.delegate else {
            return
        }
        self.sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: .video) { success in
            if success {
                self.sessionQueue.resume()
                delegate.cameraSetupCompleted(camera: self, result: .requiresUpdate)
            } else {
                delegate.cameraSetupCompleted(camera: self, result: .videoPermissionDenied)
            }
        }
    }
    
    func requestAudioPermissions() {
        guard let delegate = self.delegate else {
            return
        }
        self.sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: AVMediaType.audio) { success in
            if success {
                self.sessionQueue.resume()
                delegate.cameraSetupCompleted(camera: self, result: .requiresUpdate)
            } else {
                delegate.cameraSetupCompleted(camera: self, result: .audioPermissionDenied)
            }
        }
    }
}

// MARK: Zoom Handling

fileprivate extension LuminaCamera {
    func updateZoom() {
        guard let input = self.videoInput else {
            return
        }
        let device = input.device
        do {
            try device.lockForConfiguration()
            let newZoomScale = min(maxZoomScale, max(Float(1.0), min(currentZoomScale, Float(device.activeFormat.videoMaxZoomFactor))))
            device.videoZoomFactor = CGFloat(newZoomScale)
            device.unlockForConfiguration()
        } catch {
            device.unlockForConfiguration()
        }
    }
}

// MARK: Focus Handling

extension LuminaCamera {
    func handleFocus(at focusPoint: CGPoint) {
        self.sessionQueue.async {
            guard let input = self.videoInput else {
                return
            }
            do {
                if input.device.isFocusModeSupported(.autoFocus) && input.device.isFocusPointOfInterestSupported {
                    try input.device.lockForConfiguration()
                    input.device.focusMode = .autoFocus
                    input.device.focusPointOfInterest = CGPoint(x: focusPoint.x, y: focusPoint.y)
                    if input.device.isExposureModeSupported(.autoExpose) && input.device.isExposurePointOfInterestSupported {
                        input.device.exposureMode = .autoExpose
                        input.device.exposurePointOfInterest = CGPoint(x: focusPoint.x, y: focusPoint.y)
                    }
                    input.device.unlockForConfiguration()
                } else {
                    self.delegate?.finishedFocus(camera: self)
                }
            } catch {
                self.delegate?.finishedFocus(camera: self)
            }
        }
    }
    
    func resetCameraToContinuousExposureAndFocus() {
        do {
            guard let input = self.videoInput else {
                print("Trying to focus, but cannot detect device input!")
                return
            }
            if input.device.isFocusModeSupported(.continuousAutoFocus) {
                try input.device.lockForConfiguration()
                input.device.focusMode = .continuousAutoFocus
                if input.device.isExposureModeSupported(.continuousAutoExposure) {
                    input.device.exposureMode = .continuousAutoExposure
                }
                input.device.unlockForConfiguration()
            }
        } catch {
            print("could not reset to continuous auto focus and exposure!!")
        }
    }
}

// MARK: CaptureDevice Handling

private extension LuminaCamera {
    func getNewVideoInputDevice() -> AVCaptureDeviceInput? {
        do {
            guard let device = getDevice(with: self.position == .front ? AVCaptureDevice.Position.front : AVCaptureDevice.Position.back) else {
                print("could not find valid AVCaptureDevice")
                return nil
            }
            let input = try AVCaptureDeviceInput(device: device)
            return input
        } catch {
            return nil
        }
    }
    
    func getNewAudioInputDevice() -> AVCaptureDeviceInput? {
        do {
            guard let device = AVCaptureDevice.default(for: AVMediaType.audio) else {
                return nil
            }
            let deviceInput = try AVCaptureDeviceInput(device: device)
            return deviceInput
        } catch {
            return nil
        }
    }
    
    func recycleDeviceIO() {
        for oldInput in self.session.inputs {
            self.session.removeInput(oldInput) // TODO: check if type is video, and remove then
        }
        for oldOutput in self.session.outputs {
            self.session.removeOutput(oldOutput)
        }
    }
    
    func getDevice(with position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        guard let discoverySession = self.discoverySession else {
            return nil
        }
        for device in discoverySession.devices {
            if device.position == position {
                self.currentCaptureDevice = device
                return device
            }
        }
        return nil
    }
    
    func configureFrameRate() {
        guard let device = self.currentCaptureDevice else {
            return
        }
        for vFormat in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(vFormat.formatDescription)
            let ranges = vFormat.videoSupportedFrameRateRanges as [AVFrameRateRange]
            guard let frameRate = ranges.first else {
                continue
            }
            if frameRate.maxFrameRate >= Float64(self.frameRate) &&
                frameRate.minFrameRate <= Float64(self.frameRate) &&
                self.resolution.getDimensions().width == dimensions.width &&
                self.resolution.getDimensions().height == dimensions.height &&
                CMFormatDescriptionGetMediaSubType(vFormat.formatDescription) == 875704422  { // meant for full range 420f
                try! device.lockForConfiguration()
                device.activeFormat = vFormat as AVCaptureDevice.Format
                device.activeVideoMinFrameDuration = CMTimeMake(1, Int32(self.frameRate))
                device.activeVideoMaxFrameDuration = CMTimeMake(1, Int32(self.frameRate))
                device.unlockForConfiguration()
                break
            }
        }
    }
}

// MARK: Still Photo Capture

extension LuminaCamera: AVCapturePhotoCaptureDelegate {
    @available (iOS 11.0, *)
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let image = photo.normalizedImage(forCameraPosition: self.position) else {
            return
        }
        delegate?.stillImageCaptured(camera: self, image: image)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
        if #available(iOS 11.0, *) { // make use of AVCapturePhotoOut
            return
        } else {
            guard let buffer = photoSampleBuffer else {
                return
            }
            guard let image = buffer.normalizedStillImage(forCameraPosition: self.position) else {
                return
            }
            delegate?.stillImageCaptured(camera: self, image: image)
        }
    }
}

// MARK: AVCapturePhoto Methods
@available (iOS 11.0, *)
extension AVCapturePhoto {
    func normalizedImage(forCameraPosition position: CameraPosition) -> UIImage? {
        guard let cgImage = self.cgImageRepresentation() else {
            return nil
        }
        return UIImage(cgImage: cgImage.takeUnretainedValue() , scale: 1.0, orientation: getImageOrientation(forCamera: position))
    }
    
    private func getImageOrientation(forCamera: CameraPosition) -> UIImageOrientation {
        switch UIApplication.shared.statusBarOrientation {
        case .landscapeLeft:
            return forCamera == .back ? .down : .upMirrored
        case .landscapeRight:
            return forCamera == .back ? .up : .downMirrored
        case .portraitUpsideDown:
            return forCamera == .back ? .left : .rightMirrored
        case .portrait:
            return forCamera == .back ? .right : .leftMirrored
        case .unknown:
            return forCamera == .back ? .right : .leftMirrored
        }
    }
}

// MARK: Video Frame Streaming

extension LuminaCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = sampleBuffer.normalizedVideoFrame() else {
            return
        }
        if #available(iOS 11.0, *) {
            guard let recognizer = self.recognizer as? LuminaObjectRecognizer else {
                DispatchQueue.main.async {
                    self.delegate?.videoFrameCaptured(camera: self, frame: image)
                }
                return
            }
            recognizer.recognize(from: image, completion: { predictions in
                DispatchQueue.main.async {
                    self.delegate?.videoFrameCaptured(camera: self, frame: image, predictedObjects: predictions)
                }
            })
        } else {
            DispatchQueue.main.async {
                self.delegate?.videoFrameCaptured(camera: self, frame: image)
            }
        }
    }
}

// MARK: Image Normalization Methods

extension CMSampleBuffer {
    func normalizedStillImage(forCameraPosition position: CameraPosition) -> UIImage? {
        guard let imageData = AVCapturePhotoOutput.jpegPhotoDataRepresentation(forJPEGSampleBuffer: self, previewPhotoSampleBuffer: nil) else {
            return nil
        }
        guard let dataProvider = CGDataProvider(data: imageData as CFData) else {
            return nil
        }
        guard let cgImageRef = CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: CGColorRenderingIntent.defaultIntent) else {
            return nil
        }
        return UIImage(cgImage: cgImageRef, scale: 1.0, orientation: getImageOrientation(forCamera: position))
    }
    
    func normalizedVideoFrame() -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(self) else {
            return nil
        }
        let coreImage: CIImage = CIImage(cvPixelBuffer: imageBuffer)
        let context: CIContext = CIContext()
        guard let sample: CGImage = context.createCGImage(coreImage, from: coreImage.extent) else {
            return nil
        }
        return UIImage(cgImage: sample)
    }
    
    private func getImageOrientation(forCamera: CameraPosition) -> UIImageOrientation {
        switch UIApplication.shared.statusBarOrientation {
        case .landscapeLeft:
            return forCamera == .back ? .down : .upMirrored
        case .landscapeRight:
            return forCamera == .back ? .up : .downMirrored
        case .portraitUpsideDown:
            return forCamera == .back ? .left : .rightMirrored
        case .portrait:
            return forCamera == .back ? .right : .leftMirrored
        case .unknown:
            return forCamera == .back ? .right : .leftMirrored
        }
    }
}

extension LuminaCamera: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard case self.trackMetadata = true else {
            return
        }
        DispatchQueue.main.async {
            self.delegate?.detected(camera: self, metadata: metadataObjects)
        }
    }
}

extension LuminaCamera: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            if error == nil, let delegate = self.delegate {
                delegate.videoRecordingCaptured(camera: self, videoURL: outputFileURL)
            }
        }
    }
}

extension Formatter {
    static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
}
extension Date {
    var iso8601: String {
        return Formatter.iso8601.string(from: self)
    }
}
