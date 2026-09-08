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
///  - sessionQueue: session/device configuration (slow, blocking calls), writer creation
///  - dataQueue:    per-frame processing, previews and recording
/// Results are reported through `eventHandler` on the main actor.
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
        case zoomChanged(Double)
        case torchChanged(Bool)
        case exposureFocusLockChanged(Bool)
        case recordingStarted
        /// Seconds of video written so far, reported a few times per second.
        case recordingProgress(Double)
        case recordingFinished(Result<[DualRecorder.Clip], Error>)
        case snapshotCaptured(Data)
        /// Camera system pressure (thermal, power). Critical means recording was stopped.
        case pressureChanged(isSerious: Bool, isCritical: Bool)
        /// The user picked a filter with the Camera Control button (index into VideoFilterPreset.all).
        case filterPicked(Int)
        /// The Camera Control overlay is covering the screen (true) or went away (false).
        case captureControlsFullscreen(Bool)
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

    /// Back-camera device types in preference order. Virtual devices give the
    /// 0.5x / 2x / 3x lens switching users expect; ZoomModel handles their zoom
    /// factor quirks. Use [.builtInWideAngleCamera] to force a single lens.
    static let backCameraTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
    ]
    /// The iPhone 17 family's square Center Stage front camera is exposed as an
    /// ultra-wide device, earlier phones as a wide-angle one.
    static let frontCameraTypes: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera]
    static let stabilizationMode: AVCaptureVideoStabilizationMode = .standard

    // MARK: - Public surface

    /// Delivered on the main actor.
    var eventHandler: (@MainActor (Event) -> Void)?

    let session = AVCaptureSession()
    let primaryPreview = PreviewTarget()
    let secondaryPreview = PreviewTarget()

    // MARK: - Queues and pipeline

    private let sessionQueue = DispatchQueue(label: "com.intriq.dual.session")
    private let dataQueue = DispatchQueue(label: "com.intriq.dual.data", qos: .userInitiated)
    /// Audio is delivered on its own queue so Core Image work never delays it,
    /// then hopped onto dataQueue where the recorder state lives.
    private let audioQueue = DispatchQueue(label: "com.intriq.dual.audio", qos: .userInitiated)
    private let snapshotQueue = DispatchQueue(label: "com.intriq.dual.snapshot", qos: .utility)
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
    private var isExposureFocusLocked = false
    private var lastEmittedZoom = 0.0
    /// The Camera Control filter picker (AVCaptureIndexPicker on iOS 18+), kept untyped
    /// so the property itself needs no availability annotation.
    private var filterControl: AnyObject?
    /// Clockwise degrees that make raw frames upright in this portrait-locked UI.
    /// Derived from how the active sensor is mounted, never from how the phone is
    /// held, so the framing stays fixed the way the two preview panes show it.
    private var uprightRotationDegrees = 90

    // MARK: - State owned by the main queue

    private var pressureObservation: NSKeyValueObservation?
    private var zoomObservation: NSKeyValueObservation?

    // MARK: - State owned by dataQueue

    private var activeSettings = CaptureSettings.default
    private var orientation: CGImagePropertyOrientation = .right
    /// Orientation to adopt once the current recording ends (orientation is frozen while recording).
    private var pendingOrientation: CGImagePropertyOrientation?
    private var cachedPlan: FramingPlan?
    private var recorder: DualRecorder?
    private var isStartingRecorder = false
    private var cancelWhenStarted = false
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
                self.refreshCachedPlan()
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
                self.refreshCachedPlan()
            }
            if old.filterID != newSettings.filterID {
                self.syncFilterControl(to: newSettings.filterID)
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
            let previous = self.position
            self.position = previous == .back ? .front : .back
            do {
                try self.configureSession()
            } catch {
                // Fall back to the camera that was working so the engine never stays wedged.
                self.position = previous
                do {
                    try self.configureSession()
                } catch let fallbackError {
                    self.emit(.failed(fallbackError.localizedDescription))
                    return
                }
                self.emit(.failed(error.localizedDescription))
            }
            guard self.isConfigured else { return }
            self.emit(.torchChanged(false))
            self.emit(.exposureFocusLockChanged(false))
            self.emit(.configured(self.makeConfiguration()))
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
                // No emit here: the videoZoomFactor observer reports the real value,
                // including every step of an animated ramp.
            } catch {
                self.emit(.failed("Zoom is unavailable right now."))
            }
        }
    }

    func setTorch(_ enabled: Bool) {
        sessionQueue.async {
            guard let device = self.videoDevice, device.hasTorch, device.isTorchAvailable else {
                self.emit(.torchChanged(false))
                return
            }
            do {
                try device.lockForConfiguration()
                if enabled, device.isTorchModeSupported(.on) {
                    device.torchMode = .on
                } else if device.isTorchModeSupported(.off) {
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
    /// Tapping to focus also releases an AE/AF lock.
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
                if self.isExposureFocusLocked {
                    self.isExposureFocusLocked = false
                    self.emit(.exposureFocusLockChanged(false))
                }
            } catch {
                // Focus is best-effort.
            }
        }
    }

    /// Freezes (or releases) focus and exposure, like a long press in the system camera.
    func setExposureFocusLocked(_ locked: Bool) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if locked {
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                    device.isSubjectAreaChangeMonitoringEnabled = false
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
                self.isExposureFocusLocked = locked
                self.emit(.exposureFocusLockChanged(locked))
            } catch {
                self.emit(.exposureFocusLockChanged(self.isExposureFocusLocked))
            }
        }
    }

    private func resetFocusToContinuous() {
        sessionQueue.async {
            guard let device = self.videoDevice, !self.isExposureFocusLocked else { return }
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

    /// Creates the two writers on the session queue (encoder start-up is slow),
    /// then installs them on the data queue. A stop that arrives meanwhile
    /// cancels the take.
    func startRecording() {
        dataQueue.async {
            guard self.recorder == nil, !self.isStartingRecorder else { return }
            guard let plan = self.cachedPlan else {
                self.emit(.failed(EngineError.notReady.localizedDescription))
                return
            }
            let settings = self.activeSettings
            let recommended = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
            self.isStartingRecorder = true
            self.cancelWhenStarted = false

            self.sessionQueue.async {
                let fallbackAudio: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                ]
                let audioSettings: [String: Any]? = self.audioInput != nil ? (recommended ?? fallbackAudio) : nil
                let result: Result<DualRecorder, Error>
                do {
                    let directory = try TakeStorage.prepareDirectory()
                    let recorder = try DualRecorder(plan: plan,
                                                    settings: settings,
                                                    audioSettings: audioSettings,
                                                    directory: directory,
                                                    baseName: TakeStorage.baseName())
                    result = .success(recorder)
                } catch {
                    result = .failure(error)
                }

                self.dataQueue.async {
                    self.isStartingRecorder = false
                    switch result {
                    case .success(let recorder):
                        if self.cancelWhenStarted {
                            self.cancelWhenStarted = false
                            recorder.cancel()
                            self.emit(.recordingFinished(.failure(DualRecorder.RecorderError.nothingRecorded)))
                            return
                        }
                        self.recorder = recorder
                        self.lastReportedDuration = 0
                        self.emit(.recordingStarted)
                    case .failure(let error):
                        self.cancelWhenStarted = false
                        self.emit(.failed(error.localizedDescription))
                    }
                }
            }
        }
    }

    func stopRecording() {
        dataQueue.async {
            if self.isStartingRecorder {
                self.cancelWhenStarted = true
                return
            }
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            self.applyPendingOrientation()
            recorder.finish { [weak self, recorder] result in
                _ = recorder // keep the recorder alive until its writers have finished
                self?.emit(.recordingFinished(result))
            }
        }
    }

    func cancelRecording() {
        dataQueue.async {
            if self.isStartingRecorder {
                self.cancelWhenStarted = true
                return
            }
            guard let recorder = self.recorder else { return }
            self.recorder = nil
            self.applyPendingOrientation()
            recorder.cancel()
            self.emit(.recordingFinished(.failure(DualRecorder.RecorderError.nothingRecorded)))
        }
    }

    /// dataQueue only. Keeps the plan usable when only pair/quality changed, so
    /// startRecording never has to wait for the next frame.
    private func refreshCachedPlan() {
        guard let old = cachedPlan else { return }
        cachedPlan = FramingPlanner.plan(sourceSize: old.sourceSize, pair: activeSettings.pair, quality: activeSettings.quality)
    }

    /// dataQueue only.
    private func applyPendingOrientation() {
        if let pendingOrientation {
            orientation = pendingOrientation
            self.pendingOrientation = nil
            cachedPlan = nil
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
        isConfigured = false
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
        isExposureFocusLocked = false
        installObservers(for: device)
        installCaptureControls(for: device)

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
            // Full-resolution buffers, never preview-sized ones (order matters).
            videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            videoOutput.deliversPreviewSizedOutputBuffers = false
            let preferred = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if videoOutput.availableVideoPixelFormatTypes.contains(preferred) {
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: preferred]
            }
            videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        }

        if !session.outputs.contains(audioOutput), audioInput != nil, session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
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
            let maxRate = format.videoSupportedFrameRateRanges.map { Double($0.maxFrameRate) }.max() ?? 0
            return CaptureFormatCandidate(index: index,
                                          width: Int(dimensions.width),
                                          height: Int(dimensions.height),
                                          maxFrameRate: maxRate,
                                          isBinned: format.isVideoBinned,
                                          pixelFormat: CaptureEngine.fourCharCodeString(subtype))
        }

        // Sensor mounting decides the upright rotation, and that in turn decides
        // whether an upright frame is the sensor transposed. Both come from the
        // candidate list, so they are settled before scoring.
        let swapsDimensions = candidates.first.map { UprightTransform.forSensor($0.sensorSize, mirrored: false).swapsDimensions } ?? true

        func requirements(quality: VideoQuality, frameRate: Double) -> CaptureFormatRequirements {
            var value = CaptureFormatRequirements(targetFrameRate: frameRate, quality: quality, pair: settings.pair)
            value.uprightSwapsDimensions = swapsDimensions
            return value
        }

        var chosen = CaptureFormatSelector.select(from: candidates, requirements: requirements(quality: settings.quality, frameRate: Double(settings.frameRate)))
        if chosen == nil {
            chosen = CaptureFormatSelector.select(from: candidates, requirements: requirements(quality: settings.quality, frameRate: 30))
        }
        if chosen == nil {
            chosen = CaptureFormatSelector.select(from: candidates, requirements: requirements(quality: .hd1080, frameRate: 30))
        }
        if chosen == nil {
            // Apple gives no format guarantees, so drop every filter but the frame rate.
            var relaxed = requirements(quality: .hd1080, frameRate: 30)
            relaxed.allowedPixelFormats = Set(candidates.map { $0.pixelFormat })
            relaxed.maxLongSide = Int.max
            relaxed.softMaxPixels = Int.max
            chosen = CaptureFormatSelector.select(from: candidates, requirements: relaxed)
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

        uprightRotationDegrees = UprightTransform.forSensor(chosen.sensorSize, mirrored: false).rotationDegrees

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Re-assigning the active format tears down and rebuilds the stream, so skip
        // it when the device already runs this format.
        let formatIsNew = device.activeFormat != format
        let previousZoom = Double(device.videoZoomFactor)

        if formatIsNew {
            device.activeFormat = format
            if format.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            // HDR video is the default on recent iPhones. The pipeline renders 8-bit
            // BGRA, so keep the camera out of 10-bit HLG rather than tone-map twice.
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
        }

        // Frame durations reset when the format changes, so set them afterwards and
        // only to a value inside a supported range (anything else is an exception).
        let requestedRate = Double(settings.frameRate)
        let timescale = CMTimeScale(max(1, min(requestedRate, chosen.maxFrameRate).rounded()))
        let rate = Double(timescale)
        if format.videoSupportedFrameRateRanges.contains(where: { Double($0.minFrameRate) <= rate && rate <= Double($0.maxFrameRate) }) {
            let duration = CMTime(value: 1, timescale: timescale)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }

        // Focus and exposure modes reset with the format; honour an AE/AF lock the
        // user set rather than silently returning to continuous.
        if isExposureFocusLocked {
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
        } else {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }

        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        zoomModel = ZoomModel(minZoom: Double(device.minAvailableVideoZoomFactor),
                              maxZoom: Double(device.maxAvailableVideoZoomFactor),
                              switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue },
                              hasUltraWide: hasUltraWide)
        // Setting a format can reset the zoom, so restore what the user had; a fresh
        // device starts at the wide lens.
        let restoredZoom = previousZoom > 0 ? previousZoom : zoomModel.wideFactor
        device.videoZoomFactor = CGFloat(zoomModel.clamped(restoredZoom))

        let plan = makeFormatPlan(for: chosen)
        formatPlan = plan
        let upscaleNote = plan.maxScaleFactor > 1.001 ? String(format: ", %.2fx upscale", plan.maxScaleFactor) : ""
        formatLabel = "\(chosen.width)x\(chosen.height) at \(Int(rate.rounded())) fps\(upscaleNote)"
        dataQueue.async {
            self.cachedPlan = plan
            self.processor.resetPools()
        }
    }

    /// The plan for a format's frames once they are upright. A landscape-mounted
    /// sensor is transposed by the quarter turn; a portrait-mounted one is not.
    private func makeFormatPlan(for candidate: CaptureFormatCandidate) -> FramingPlan {
        let swaps = UprightTransform.forSensor(candidate.sensorSize, mirrored: false).swapsDimensions
        let sourceSize = swaps ? candidate.portraitSize : candidate.sensorSize
        return FramingPlanner.plan(sourceSize: sourceSize, pair: settings.pair, quality: settings.quality)
    }

    /// Leaves buffers in the sensor's native orientation (rotation is done on
    /// the GPU in FrameProcessor) and records how to make them upright.
    private func configureVideoConnection() {
        var connectionAngle = 0.0
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            connectionAngle = Double(connection.videoRotationAngle)
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoStabilizationSupported,
               videoDevice?.activeFormat.isVideoStabilizationModeSupported(CaptureEngine.stabilizationMode) == true {
                connection.preferredVideoStabilizationMode = CaptureEngine.stabilizationMode
            }
        }
        let degrees = UprightTransform.normalize(Double(uprightRotationDegrees) - connectionAngle)
        let mirrored = position == .front && settings.mirrorFrontCamera
        let transform = UprightTransform(rotationDegrees: degrees, mirrored: mirrored)
        sessionTransform = transform
        let newOrientation = transform.imageOrientation
        dataQueue.async {
            if self.recorder == nil {
                // Keep the plan seeded by applyFormat unless the orientation really changed,
                // otherwise recording would be refused until the next frame arrives.
                if self.orientation != newOrientation {
                    self.orientation = newOrientation
                    self.cachedPlan = nil
                }
                self.pendingOrientation = nil
            } else {
                self.pendingOrientation = newOrientation
            }
        }
    }

    /// Installs the device observers. KVO is set up on the main queue, which is
    /// where the callbacks arrive.
    private func installObservers(for device: AVCaptureDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Pressure: back off before the system shuts the camera down.
            self.pressureObservation = nil
            self.pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                self?.systemPressureDidChange(to: device.systemPressureState.level)
            }

            // Zoom: ramps and the Camera Control slider change the factor outside setZoom.
            self.zoomObservation = nil
            self.zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
                self?.zoomFactorDidChange(to: Double(device.videoZoomFactor))
            }
        }
    }

    private func zoomFactorDidChange(to zoom: Double) {
        sessionQueue.async {
            guard abs(zoom - self.lastEmittedZoom) > 0.01 else { return }
            self.lastEmittedZoom = zoom
            self.emit(.zoomChanged(zoom))
        }
    }

    // MARK: - Camera Control (iPhone 16 and later, iOS 18+)

    /// Adds the system zoom slider and a filter picker to the Camera Control button.
    /// Controls may be added while the session runs; a delegate is required for
    /// them to become active. sessionQueue only.
    private func installCaptureControls(for device: AVCaptureDevice) {
        guard #available(iOS 18.0, *), session.supportsControls else { return }
        for control in session.controls {
            session.removeControl(control)
        }
        filterControl = nil

        let zoomSlider = AVCaptureSystemZoomSlider(device: device)
        if session.canAddControl(zoomSlider) {
            session.addControl(zoomSlider)
        }

        let titles = VideoFilterPreset.all.map { $0.displayName }
        let picker = AVCaptureIndexPicker("Filter", symbolName: "camera.filters", localizedIndexTitles: titles)
        picker.selectedIndex = VideoFilterPreset.all.firstIndex(where: { $0.id == settings.filterID }) ?? 0
        picker.setActionQueue(sessionQueue) { [weak self] index in
            self?.emit(.filterPicked(index))
        }
        if session.canAddControl(picker) {
            session.addControl(picker)
            filterControl = picker
        }

        session.setControlsDelegate(self, queue: sessionQueue)
    }

    /// sessionQueue only.
    private func syncFilterControl(to filterID: String) {
        guard #available(iOS 18.0, *),
              let picker = filterControl as? AVCaptureIndexPicker,
              let index = VideoFilterPreset.all.firstIndex(where: { $0.id == filterID }),
              picker.selectedIndex != index else { return }
        picker.selectedIndex = index
    }

    private func systemPressureDidChange(to level: AVCaptureDevice.SystemPressureState.Level) {
        // Level is a string-backed struct, not Comparable: compare with == only.
        let isCritical = level == .shutdown
        let isSerious = level == .serious || level == .critical
        if isCritical {
            stopRecording()
        }
        emit(.pressureChanged(isSerious: isSerious || isCritical, isCritical: isCritical))
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
        let preferredTypes = position == .front ? frontCameraTypes : backCameraTypes
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
        guard outputs.count == plan.outputs.count else {
            // A pool hit its threshold: drop the frame for every output so the clips stay identical.
            droppedFrameCount += 1
            return
        }

        if let primary = plan.primary, let rendered = outputs.first(where: { $0.framing == primary }) {
            primaryPreview.display(rendered.pixelBuffer, presentationTime: time)
        }
        if let secondary = plan.secondary, let rendered = outputs.first(where: { $0.framing == secondary }) {
            secondaryPreview.display(rendered.pixelBuffer, presentationTime: time)
        }

        if let recorder {
            recorder.appendVideo(outputs, at: time)
            if let error = recorder.failure {
                // A writer died mid-take: end the take now instead of recording silence.
                self.recorder = nil
                applyPendingOrientation()
                recorder.cancel()
                emit(.recordingFinished(.failure(DualRecorder.RecorderError.writerFailed(error))))
            } else {
                let duration = recorder.recordedDuration
                if duration - lastReportedDuration >= 0.2 {
                    lastReportedDuration = duration
                    emit(.recordingProgress(duration))
                }
            }
        }

        if snapshotRequested {
            snapshotRequested = false
            // JPEG encoding of a full frame takes long enough to drop frames, so it
            // runs off the data queue. CIContext is thread-safe and the CIImage keeps
            // its pixel buffer alive.
            let snapshotImage = upright
            snapshotQueue.async { [processor] in
                if let data = processor.jpegData(for: snapshotImage) {
                    self.emit(.snapshotCaptured(data))
                } else {
                    self.emit(.failed("Could not capture a snapshot."))
                }
            }
        }
    }

    /// Called on audioQueue; the recorder lives on dataQueue.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        dataQueue.async {
            self.recorder?.appendAudio(sampleBuffer)
        }
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

// MARK: - Camera Control delegate

@available(iOS 18.0, *)
extension CaptureEngine: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        emit(.captureControlsFullscreen(true))
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        emit(.captureControlsFullscreen(false))
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        emit(.captureControlsFullscreen(false))
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
