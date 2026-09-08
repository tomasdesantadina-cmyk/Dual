import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import DualCore
import Foundation
import ImageIO
import UIKit

/// Owns the AVCaptureSession and the frame pipeline. Public methods are safe to
/// call from any thread; work is serialised onto two queues:
///  - sessionQueue: session/device configuration (slow, blocking calls)
///  - dataQueue:    per-frame processing, previews and recording
/// Results are reported through `eventHandler` on the main queue.
final class CaptureEngine: NSObject {

    // MARK: - Types

    struct Configuration {
        let position: AVCaptureDevice.Position
        let zoomModel: ZoomModel
        let zoom: Double
        let hasTorch: Bool
        let hasAudio: Bool
        let plan: FramingPlan
        let transform: UprightTransform
        let formatLabel: String
    }

    enum Event {
        case configured(Configuration)
        case planChanged(FramingPlan)
        case transformChanged(UprightTransform)
        case zoomChanged(Double)
        case torchChanged(Bool)
        case recordingStarted
        /// Seconds of video written so far, reported a few times per second.
        case recordingProgress(Double)
        case recordingFinished(Result<[DualRecorder.Clip], Error>)
        case snapshotCaptured(Data)
        case interrupted(String)
        case interruptionEnded
        case failed(String)
    }

    enum EngineError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
        case noUsableFormat
        case notReady

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera is available on this device."
            case .cannotAddInput: return "The camera could not be attached to the capture session."
            case .cannotAddOutput: return "The video output could not be attached to the capture session."
            case .noUsableFormat: return "The camera has no video format this app can use."
            case .notReady: return "The camera is not ready yet."
            }
        }
    }

    // MARK: - Public surface

    /// Delivered on the main actor.
    var eventHandler: (@MainActor (Event) -> Void)?

    let session = AVCaptureSession()
    let primaryPreview = PreviewTarget()
    let secondaryPreview = PreviewTarget()

    // MARK: - Queues and pipeline

    private let sessionQueue = DispatchQueue(label: "com.intriq.dual.session")
    private let dataQueue = DispatchQueue(label: "com.intriq.dual.data", qos: .userInitiated)
    private let processor = FrameProcessor()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // MARK: - State owned by sessionQueue

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var settings = CaptureSettings.default
    private var isConfigured = false
    private var zoomModel = ZoomModel.singleCamera
    private var formatPlan: FramingPlan?
    private var formatLabel = ""
    private var sessionTransform: UprightTransform = .rotateClockwise
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Clockwise degrees that make raw frames upright in the portrait UI (from the coordinator).
    private var uprightRotationDegrees = 90

    // MARK: - State owned by dataQueue

    private var activeSettings = CaptureSettings.default
    private var orientation: CGImagePropertyOrientation = .right
    /// Orientation to adopt once the current recording ends (orientation is frozen while recording).
    private var pendingOrientation: CGImagePropertyOrientation?
    private var cachedPlan: FramingPlan?
    private var recorder: DualRecorder?
    private var snapshotRequested = false
    private var lastReportedDuration = 0.0
    private(set) var droppedFrameCount = 0

    private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    override init() {
        super.init()
        registerObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Configures (if needed) and starts the session.
    func start(settings: CaptureSettings, position: AVCaptureDevice.Position = .back) {
        sessionQueue.async {
            self.settings = settings
            self.position = position
            self.dataQueue.async {
                self.activeSettings = settings
                self.cachedPlan = nil
            }
            if !self.isConfigured {
                do {
                    try self.configureSession()
                } catch {
                    self.emit(.failed(error.localizedDescription))
                    return
                }
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.emit(.configured(self.makeConfiguration()))
        }
    }

    /// Stops the session (e.g. when the app goes to the background).
    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Pushes new settings. Format-affecting changes reconfigure the device.
    func apply(_ newSettings: CaptureSettings) {
        sessionQueue.async {
            let old = self.settings
            self.settings = newSettings
            self.dataQueue.async {
                self.activeSettings = newSettings
                self.cachedPlan = nil
            }
            let formatChanged = old.quality != newSettings.quality
                || old.frameRate != newSettings.frameRate
                || old.pair != newSettings.pair
            let mirrorChanged = old.mirrorFrontCamera != newSettings.mirrorFrontCamera
            guard self.isConfigured, let device = self.videoDevice, formatChanged || mirrorChanged else { return }

            self.session.beginConfiguration()
            if formatChanged {
                do {
                    try self.applyFormat(to: device)
                } catch {
                    self.emit(.failed(error.localizedDescription))
                }
            }
            self.configureVideoConnection()
            self.session.commitConfiguration()
            self.emit(.configured(self.makeConfiguration()))
        }
    }

    func switchCamera() {
        sessionQueue.async {
            self.position = self.position == .back ? .front : .back
            do {
                try self.configureSession()
                self.emit(.torchChanged(false))
                self.emit(.configured(self.makeConfiguration()))
            } catch {
                self.emit(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Camera controls

    func setZoom(_ rawZoom: Double, animated: Bool) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            let target = CGFloat(self.zoomModel.clamped(rawZoom))
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: target, withRate: 6)
                } else {
                    if device.isRampingVideoZoom {
                        device.cancelVideoZoomRamp()
                    }
                    device.videoZoomFactor = target
                }
                device.unlockForConfiguration()
                self.emit(.zoomChanged(Double(target)))
            } catch {
                self.emit(.failed("Zoom is unavailable right now."))
            }
        }
    }

    func setTorch(_ enabled: Bool) {
        sessionQueue.async {
            guard let device = self.videoDevice, device.hasTorch else {
                self.emit(.torchChanged(false))
                return
            }
            do {
                try device.lockForConfiguration()
                if enabled, device.isTorchModeSupported(.on) {
                    device.torchMode = .on
                } else {
                    device.torchMode = .off
                }
                let isOn = device.torchMode == .on
                device.unlockForConfiguration()
                self.emit(.torchChanged(isOn))
            } catch {
                self.emit(.torchChanged(false))
            }
        }
    }

    /// `point` is in the camera's native coordinate space (see PointMapper).
    func focusAndExpose(atDevicePoint point: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                // Focus is best-effort.
            }
        }
    }

    private func resetFocusToContinuous() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                let centre = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = centre
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = centre
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = false
                device.unlockForConfiguration()
            } catch {
                // Best-effort.
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        dataQueue.async {
            guard self.recorder == nil else { return }
            guard let plan = self.cachedPlan else {
                self.emit(.failed(EngineError.notReady.localizedDescription))
                return
            }
            let recommended = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
            let fallbackAudio: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            do {
                let directory = try TakeStorage.prepareDirectory()
                let recorder = try DualRecorder(plan: plan,
                                                settings: self.activeSettings,
                                                audioSettings: recommended ?? fallbackAudio,
                                                directory: directory,
                                                baseName: TakeStorage.baseName())
                self.recorder = recorder
                self.lastReportedDuration = 0
                self.emit(.recordingStarted)
            } catch {
                self.emit(.failed(error.localizedDescription))
            }
        }
    }

    func stopRecording() {
        dataQueue.async {
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            self.applyPendingOrientation()
            recorder.finish { [weak self] result in
                self?.emit(.recordingFinished(result))
            }
        }
    }

    /// dataQueue only.
    private func applyPendingOrientation() {
        if let pendingOrientation {
            orientation = pendingOrientation
            self.pendingOrientation = nil
            cachedPlan = nil
        }
    }

    func cancelRecording() {
        dataQueue.async {
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            self.applyPendingOrientation()
            recorder.cancel()
            self.emit(.recordingFinished(.failure(DualRecorder.RecorderError.nothingRecorded)))
        }
    }

    /// Saves a still of the next full frame (upright, filtered).
    func captureSnapshot() {
        dataQueue.async {
            self.snapshotRequested = true
        }
    }

    // MARK: - Session configuration (sessionQueue)

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }
        // Keep the pipeline 8-bit sRGB so Core Image never sees wide-colour buffers.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        if let existing = videoInput {
            session.removeInput(existing)
            videoInput = nil
            videoDevice = nil
        }

        guard let device = CaptureEngine.discoverCamera(position: position) else {
            throw EngineError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw EngineError.cannotAddInput }
        session.addInput(input)
        videoInput = input
        videoDevice = device
        installRotationCoordinator(for: device)

        if audioInput == nil,
           CameraAuthorization.status(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio),
           let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(microphoneInput) {
            session.addInput(microphoneInput)
            audioInput = microphoneInput
        }

        if !session.outputs.contains(videoOutput) {
            guard session.canAddOutput(videoOutput) else { throw EngineError.cannotAddOutput }
            session.addOutput(videoOutput)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            let preferred = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if videoOutput.availableVideoPixelFormatTypes.contains(preferred) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: preferred]
            }
            videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        }

        if !session.outputs.contains(audioOutput), audioInput != nil, session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
        }

        try applyFormat(to: device)
        configureVideoConnection()
        isConfigured = true
    }

    /// Picks the best format for the current settings and applies it with the
    /// requested frame rate, continuous focus/exposure and a 1x starting zoom.
    private func applyFormat(to device: AVCaptureDevice) throws {
        let candidates: [CaptureFormatCandidate] = device.formats.enumerated().map { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            return CaptureFormatCandidate(index: index,
                                          width: Int(dimensions.width),
                                          height: Int(dimensions.height),
                                          maxFrameRate: maxRate,
                                          isBinned: format.isVideoBinned,
                                          pixelFormat: CaptureEngine.fourCharCodeString(subtype))
        }

        var requirements = settings.formatRequirements
        var chosen = CaptureFormatSelector.select(from: candidates, requirements: requirements)
        if chosen == nil {
            requirements.targetFrameRate = 30
            chosen = CaptureFormatSelector.select(from: candidates, requirements: requirements)
        }
        if chosen == nil {
            requirements.allowedPixelFormats = Set(candidates.map { $0.pixelFormat })
            requirements.maxLongSide = Int.max
            chosen = CaptureFormatSelector.select(from: candidates, requirements: requirements)
        }
        if chosen == nil, let activeIndex = device.formats.firstIndex(of: device.activeFormat),
           candidates.indices.contains(activeIndex) {
            // Apple gives no format guarantees: fall back to whatever the device already runs.
            chosen = candidates[activeIndex]
        }
        guard let chosen, device.formats.indices.contains(chosen.index) else {
            throw EngineError.noUsableFormat
        }
        let format = device.formats[chosen.index]

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format
        if format.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }

        let requestedRate = Double(settings.frameRate)
        let rate = min(requestedRate, chosen.maxFrameRate)
        if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && rate <= $0.maxFrameRate }) {
            let duration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }

        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        zoomModel = ZoomModel(minZoom: Double(device.minAvailableVideoZoomFactor),
                              maxZoom: Double(device.maxAvailableVideoZoomFactor),
                              switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue },
                              hasUltraWide: hasUltraWide)
        device.videoZoomFactor = CGFloat(zoomModel.clamped(zoomModel.wideFactor))

        let plan = FramingPlanner.plan(sourceSize: chosen.portraitSize, pair: settings.pair, quality: settings.quality)
        formatPlan = plan
        formatLabel = "\(chosen.width)x\(chosen.height) at \(Int(rate.rounded())) fps"
        dataQueue.async {
            self.cachedPlan = plan
            self.processor.resetPools()
        }
    }

    /// Leaves buffers in the sensor's native orientation (rotation is done on
    /// the GPU in FrameProcessor) and records how to make them upright.
    private func configureVideoConnection() {
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .standard
            }
        }
        let mirrored = position == .front && settings.mirrorFrontCamera
        let transform = UprightTransform(rotationDegrees: uprightRotationDegrees, mirrored: mirrored)
        sessionTransform = transform
        let newOrientation = transform.imageOrientation
        dataQueue.async {
            if self.recorder == nil {
                self.orientation = newOrientation
                self.pendingOrientation = nil
                self.cachedPlan = nil
            } else {
                self.pendingOrientation = newOrientation
            }
        }
    }

    /// Asks AVFoundation how much the raw frames must be rotated to appear upright
    /// in this portrait-locked UI. The answer depends on how the sensor is mounted
    /// (e.g. the front camera on iPhone 17 Pro differs), so it is never hard-coded.
    private func installRotationCoordinator(for device: AVCaptureDevice) {
        // The coordinator watches a CALayer, so it is created and observed on the
        // main queue. The `.initial` option reports the starting angle straight away.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rotationObservation = nil
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: self.primaryPreview.layer)
            self.rotationCoordinator = coordinator
            self.rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let degrees = UprightTransform.normalize(Double(coordinator.videoRotationAngleForHorizonLevelPreview))
                self?.rotationAngleDidChange(to: degrees)
            }
        }
    }

    private func rotationAngleDidChange(to degrees: Int) {
        sessionQueue.async {
            guard self.isConfigured, degrees != self.uprightRotationDegrees else { return }
            self.uprightRotationDegrees = degrees
            self.configureVideoConnection()
            self.emit(.transformChanged(self.sessionTransform))
        }
    }

    private func makeConfiguration() -> Configuration {
        let plan = formatPlan ?? FramingPlanner.plan(sourceSize: PixelSize(width: 1944, height: 2592),
                                                     pair: settings.pair,
                                                     quality: settings.quality)
        return Configuration(position: position,
                             zoomModel: zoomModel,
                             zoom: Double(videoDevice?.videoZoomFactor ?? 1),
                             hasTorch: videoDevice?.hasTorch ?? false,
                             hasAudio: audioInput != nil,
                             plan: plan,
                             transform: sessionTransform,
                             formatLabel: formatLabel)
    }

    private static func discoverCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType]
        switch position {
        case .front:
            preferredTypes = [.builtInWideAngleCamera]
        default:
            preferredTypes = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: preferredTypes, mediaType: .video, position: position)
        for type in preferredTypes {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return discovery.devices.first
    }

    private static func fourCharCodeString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Notifications

    private func registerObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .mediaServicesWereReset {
                self.sessionQueue.async {
                    if self.isConfigured, !self.session.isRunning {
                        self.session.startRunning()
                    }
                }
            } else {
                self.emit(.failed(error?.localizedDescription ?? "The camera stopped unexpectedly."))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            var reasonText = "The camera was interrupted."
            if let rawReason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
               let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason) {
                switch reason {
                case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient:
                    reasonText = "Another app is using the camera or microphone."
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    reasonText = "The camera is not available while another app is in the foreground."
                case .videoDeviceNotAvailableInBackground:
                    reasonText = "Recording stopped because the app went to the background."
                case .videoDeviceNotAvailableDueToSystemPressure:
                    reasonText = "The device is under system pressure and paused the camera."
                @unknown default:
                    break
                }
            }
            self.stopRecording()
            self.emit(.interrupted(reasonText))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.emit(.interruptionEnded)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.resetFocusToContinuous()
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.dataQueue.async {
                self.processor.resetPools()
            }
        })
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.eventHandler?(event)
            }
        }
    }

    // MARK: - Frame handling (dataQueue)

    private func resolvePlan(forUprightSize size: PixelSize) -> FramingPlan {
        if let cachedPlan, cachedPlan.sourceSize == size {
            return cachedPlan
        }
        let plan = FramingPlanner.plan(sourceSize: size, pair: activeSettings.pair, quality: activeSettings.quality)
        cachedPlan = plan
        emit(.planChanged(plan))
        return plan
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let upright = processor.uprightImage(from: pixelBuffer, orientation: orientation, filter: activeSettings.filter)
        let uprightSize = PixelSize(width: Int(upright.extent.width.rounded()), height: Int(upright.extent.height.rounded()))
        let plan = resolvePlan(forUprightSize: uprightSize)
        let outputs = processor.render(upright: upright, plan: plan)

        if let primary = plan.primary, let rendered = outputs.first(where: { $0.framing == primary }) {
            primaryPreview.display(rendered.pixelBuffer, presentationTime: time)
        }
        if let secondary = plan.secondary, let rendered = outputs.first(where: { $0.framing == secondary }) {
            secondaryPreview.display(rendered.pixelBuffer, presentationTime: time)
        }

        if let recorder {
            recorder.appendVideo(outputs, at: time)
            let duration = recorder.recordedDuration
            if duration - lastReportedDuration >= 0.2 {
                lastReportedDuration = duration
                emit(.recordingProgress(duration))
            }
        }

        if snapshotRequested {
            snapshotRequested = false
            if let data = processor.jpegData(for: upright) {
                emit(.snapshotCaptured(data))
            } else {
                emit(.failed("Could not capture a snapshot."))
            }
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        recorder?.appendAudio(sampleBuffer)
    }
}

// MARK: - Sample buffer delegates

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            droppedFrameCount += 1
        }
    }
}

// MARK: - Orientation mapping

extension UprightTransform {
    /// The Core Image orientation that applies this transform to a raw camera buffer.
    /// AVFoundation's rotation angles are clockwise degrees; EXIF `.right` means
    /// "rotate 90 degrees clockwise to display upright", so 90 maps to `.right`.
    var imageOrientation: CGImagePropertyOrientation {
        switch (rotationDegrees, mirrored) {
        case (90, false): return .right
        case (90, true): return .leftMirrored
        case (180, false): return .down
        case (180, true): return .downMirrored
        case (270, false): return .left
        case (270, true): return .rightMirrored
        case (_, false): return .up
        case (_, true): return .upMirrored
        }
    }
}
