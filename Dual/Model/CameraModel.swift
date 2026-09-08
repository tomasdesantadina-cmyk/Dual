import AVFoundation
import DualCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The single source of truth for the camera screen. Talks to CaptureEngine and
/// exposes plain observable state to SwiftUI. Everything here runs on the main actor.
@MainActor
@Observable
final class CameraModel {

    enum Phase: Equatable {
        case idle
        /// Record was tapped; the writers are being created.
        case starting
        case recording
        case saving
    }

    enum Authorization: Equatable {
        case unknown
        case requesting
        case authorized
        case denied
    }

    // MARK: - Observable state

    var authorization: Authorization = .unknown
    var phase: Phase = .idle
    var isSessionReady = false
    var elapsedText = RecordingClock.timecode(seconds: 0)
    var isTorchOn = false
    var hasTorch = false
    var hasAudio = true
    var isFrontCamera = false
    var zoomLabel = "1x"
    var formatLabel = ""
    var settings: CaptureSettings
    var lastTake: LastTake?
    var alert: AlertMessage?
    var interruptionMessage: String?
    var focusIndicator: FocusIndicator?
    var isShowingFilterPicker = false
    var isShowingSettings = false
    var isShowingLastTake = false
    var isConfirmingDiscard = false
    var snapshotFlash = false
    var isExposureFocusLocked = false
    var pressureWarning: String?

    var isRecording: Bool { phase == .recording }
    /// A take is in flight: the writers are being created or frames are being written.
    var isCapturing: Bool { phase == .recording || phase == .starting }
    var isBusy: Bool { phase == .saving || !isSessionReady }
    var selectedFilter: VideoFilterPreset { settings.filter }

    /// Crop rectangles for the current source frame; used to map taps to focus points.
    private(set) var plan: FramingPlan?

    // MARK: - Engine

    let engine = CaptureEngine()

    // Internal bookkeeping that no view reads; kept out of observation tracking.
    private let store: SettingsStore
    @ObservationIgnored private var zoomModel = ZoomModel.singleCamera
    @ObservationIgnored private var currentZoom = 1.0
    @ObservationIgnored private var pinchStartZoom = 1.0
    @ObservationIgnored private var isPinching = false
    @ObservationIgnored private var transform: UprightTransform = .rotateClockwise
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        let store = SettingsStore()
        self.store = store
        self.settings = store.load()
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.thermalStateChanged()
            }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    // MARK: - Lifecycle

    /// Requests permissions and starts the camera. Safe to call repeatedly.
    func start() async {
        if authorization == .authorized {
            engine.start(settings: settings, position: isFrontCamera ? .front : .back)
            return
        }
        guard authorization != .requesting else { return }
        authorization = .requesting
        let result = await CameraAuthorization.request()
        hasAudio = result.microphone
        switch result.camera {
        case .authorized:
            authorization = .authorized
            engine.start(settings: settings, position: .back)
            await recoverOrphanedTake()
        case .denied, .notDetermined:
            authorization = .denied
        }
    }

    /// Clips left on disk by an earlier run (a failed Photos save, or a take cut
    /// short by a crash) are offered for saving instead of being deleted. Files
    /// that cannot be played (an unfinished fragment) are removed.
    private func recoverOrphanedTake() async {
        guard lastTake == nil else { return }
        var files: [URL] = []
        for url in TakeStorage.existingTakeFiles() {
            let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            if playable {
                files.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let first = files.first else { return }
        let thumbnail = await ThumbnailMaker.thumbnail(for: first)
        let duration = await ThumbnailMaker.duration(of: first)
        let modified = (try? first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        lastTake = LastTake(outputs: [],
                            thumbnail: thumbnail,
                            date: modified,
                            duration: duration,
                            savedToPhotos: false,
                            pendingURLs: files)
    }

    private func thermalStateChanged() {
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            if isCapturing {
                interruptionMessage = "The phone is too hot. Recording was stopped to protect it."
                engine.stopRecording()
            } else {
                interruptionMessage = "The phone is too hot. Let it cool down before recording."
            }
        case .serious:
            interruptionMessage = "The phone is getting hot. Consider a short break."
        default:
            if interruptionMessage?.contains("hot") == true {
                interruptionMessage = nil
            }
        }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            if authorization == .authorized {
                engine.start(settings: settings, position: isFrontCamera ? .front : .back)
            }
        case .background:
            if phase == .recording || phase == .starting || phase == .saving {
                // Keep running long enough to finalise and save the clips.
                beginBackgroundTask()
            }
            if phase == .recording || phase == .starting {
                engine.stopRecording()
            }
            engine.stop()
            isSessionReady = false
        default:
            break
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishRecording") { [weak self] in
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Recording

    func toggleRecording() {
        switch phase {
        case .idle:
            guard isSessionReady else { return }
            isShowingFilterPicker = false
            phase = .starting
            engine.startRecording()
        case .starting, .recording:
            engine.stopRecording()
        case .saving:
            break
        }
    }

    func discardRecording() {
        guard phase == .recording || phase == .starting else { return }
        engine.cancelRecording()
    }

    func captureSnapshot() {
        guard isSessionReady else { return }
        engine.captureSnapshot()
        snapshotFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            snapshotFlash = false
        }
    }

    // MARK: - Camera controls

    func flipCamera() {
        guard phase == .idle, isSessionReady else { return }
        isSessionReady = false
        isFrontCamera.toggle()
        engine.switchCamera()
    }

    func toggleTorch() {
        guard hasTorch else { return }
        engine.setTorch(!isTorchOn)
    }

    /// Long press on a preview: freeze focus and exposure (tap to release).
    func toggleExposureFocusLock() {
        guard isSessionReady else { return }
        engine.setExposureFocusLocked(!isExposureFocusLocked)
    }

    func cycleZoomPreset() {
        let next = zoomModel.nextPresetZoom(after: currentZoom)
        currentZoom = next
        zoomLabel = zoomModel.label(forZoom: next)
        engine.setZoom(next, animated: true)
    }

    /// `magnification` is relative to the start of the current pinch gesture.
    func pinchChanged(_ magnification: CGFloat) {
        if !isPinching {
            isPinching = true
            pinchStartZoom = currentZoom
        }
        let target = zoomModel.zoom(forPinchScale: Double(magnification), startZoom: pinchStartZoom)
        currentZoom = target
        zoomLabel = zoomModel.label(forZoom: target)
        engine.setZoom(target, animated: false)
    }

    func pinchEnded() {
        isPinching = false
        pinchStartZoom = currentZoom
    }

    /// `point` is normalised (0...1) inside the preview pane showing `output`.
    func focus(atPreviewPoint point: UnitPoint2D, in output: FramingOutput, indicatorLocation: CGPoint, paneID: String) {
        guard let plan else { return }
        let devicePoint = PointMapper.devicePoint(fromPreviewPoint: point,
                                                  crop: output.cropRect,
                                                  uprightSize: plan.sourceSize,
                                                  transform: transform)
        engine.focusAndExpose(atDevicePoint: CGPoint(x: devicePoint.x, y: devicePoint.y))

        let indicator = FocusIndicator(id: UUID(), location: indicatorLocation, paneID: paneID)
        focusIndicator = indicator
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if focusIndicator == indicator {
                focusIndicator = nil
            }
        }
    }

    /// The current framing output shown by the pane with this aspect.
    func output(for aspect: AspectRatio) -> FramingOutput? {
        plan?.outputs.first { $0.aspect == aspect }
    }

    // MARK: - Settings

    func cycleFormatPair() {
        guard phase == .idle else { return }
        var updated = settings
        updated.pair = settings.pair.nextPreset
        updateSettings(updated)
    }

    func select(filter: VideoFilterPreset) {
        var updated = settings
        updated.filterID = filter.id
        updateSettings(updated)
    }

    func toggleLayout() {
        var updated = settings
        updated.landscapeOnTop.toggle()
        updateSettings(updated)
    }

    /// Applies new settings. Format-affecting changes are ignored while recording.
    func updateSettings(_ newSettings: CaptureSettings) {
        var accepted = newSettings.sanitized()
        if phase != .idle {
            accepted.quality = settings.quality
            accepted.frameRate = settings.frameRate
            accepted.pair = settings.pair
            accepted.codec = settings.codec
        }
        guard accepted != settings else { return }
        let formatChanged = accepted.quality != settings.quality
            || accepted.frameRate != settings.frameRate
            || accepted.pair != settings.pair
        settings = accepted
        store.save(accepted)
        if formatChanged {
            isSessionReady = false
        }
        engine.apply(accepted)
    }

    // MARK: - Engine events

    private func handle(_ event: CaptureEngine.Event) {
        switch event {
        case .configured(let configuration):
            zoomModel = configuration.zoomModel
            currentZoom = configuration.zoom
            pinchStartZoom = configuration.zoom
            isPinching = false
            zoomLabel = zoomModel.label(forZoom: configuration.zoom)
            hasTorch = configuration.hasTorch
            hasAudio = configuration.hasAudio
            isFrontCamera = configuration.position == .front
            plan = configuration.plan
            transform = configuration.transform
            formatLabel = configuration.formatLabel
            isSessionReady = true

        case .planChanged(let newPlan):
            plan = newPlan

        case .transformChanged(let newTransform):
            transform = newTransform

        case .zoomChanged(let zoom):
            // While the user pinches, the model already holds the newest value;
            // echoes from the session queue would only make the label jitter.
            guard !isPinching else { break }
            currentZoom = zoom
            zoomLabel = zoomModel.label(forZoom: zoom)

        case .torchChanged(let isOn):
            isTorchOn = isOn

        case .exposureFocusLockChanged(let isLocked):
            isExposureFocusLocked = isLocked

        case .pressureChanged(let isSerious, let isCritical):
            if isCritical {
                pressureWarning = "The camera is overheating. Recording was stopped."
            } else if isSerious {
                pressureWarning = "The camera is getting hot. Consider a short break."
            } else {
                pressureWarning = nil
            }

        case .recordingStarted:
            phase = .recording
            elapsedText = RecordingClock.timecode(seconds: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        case .recordingProgress(let seconds):
            elapsedText = RecordingClock.timecode(seconds: seconds)

        case .recordingFinished(let result):
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            switch result {
            case .success(let clips):
                phase = .saving
                Task { await save(clips) }
            case .failure(let error):
                phase = .idle
                endBackgroundTask()
                if let recorderError = error as? DualRecorder.RecorderError, case .nothingRecorded = recorderError {
                    // Discarded or empty take: nothing to report.
                } else {
                    alert = AlertMessage(title: "Recording failed", message: error.localizedDescription)
                }
            }

        case .snapshotCaptured(let data):
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task {
                do {
                    try await PhotoLibrarySaver.saveImage(data: data)
                } catch {
                    alert = AlertMessage(title: "Snapshot not saved", message: error.localizedDescription)
                }
            }

        case .interrupted(let message):
            interruptionMessage = message

        case .interruptionEnded:
            interruptionMessage = nil

        case .failed(let message):
            if phase == .starting {
                phase = .idle
                endBackgroundTask()
            }
            alert = AlertMessage(title: "Camera problem", message: message)
        }
    }

    /// Generates the thumbnail first (the files move into Photos and are gone
    /// afterwards), then hands both clips to the library. On failure the files
    /// stay on disk so the save can be retried from the last-take sheet.
    private func save(_ clips: [DualRecorder.Clip]) async {
        let urls = clips.map { $0.url }
        var thumbnail: UIImage?
        var duration = 0.0
        if let first = urls.first {
            thumbnail = await ThumbnailMaker.thumbnail(for: first)
            duration = await ThumbnailMaker.duration(of: first)
        }
        do {
            try await PhotoLibrarySaver.saveVideos(at: urls)
            lastTake = LastTake(outputs: clips.map { $0.framing },
                                thumbnail: thumbnail,
                                date: Date(),
                                duration: duration,
                                savedToPhotos: true,
                                pendingURLs: [])
        } catch {
            // Files that did move are gone; whatever is left can be retried.
            lastTake = LastTake(outputs: clips.map { $0.framing },
                                thumbnail: thumbnail,
                                date: Date(),
                                duration: duration,
                                savedToPhotos: false,
                                pendingURLs: urls.filter { FileManager.default.fileExists(atPath: $0.path) })
            alert = AlertMessage(title: "Could not save to Photos", message: error.localizedDescription)
        }
        phase = .idle
        endBackgroundTask()
    }

    /// Retries a failed Photos save for the last take.
    func retrySavingLastTake() async {
        guard let take = lastTake, !take.pendingURLs.isEmpty, phase == .idle else { return }
        phase = .saving
        beginBackgroundTask()
        do {
            try await PhotoLibrarySaver.saveVideos(at: take.pendingURLs)
            lastTake = LastTake(outputs: take.outputs,
                                thumbnail: take.thumbnail,
                                date: take.date,
                                duration: take.duration,
                                savedToPhotos: true,
                                pendingURLs: [])
        } catch {
            let remaining = take.pendingURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if remaining.isEmpty {
                // Nothing left on disk to retry: the take is gone, do not describe it as saved.
                lastTake = nil
            } else {
                lastTake = LastTake(outputs: take.outputs,
                                    thumbnail: take.thumbnail,
                                    date: take.date,
                                    duration: take.duration,
                                    savedToPhotos: false,
                                    pendingURLs: remaining)
            }
            alert = AlertMessage(title: "Could not save to Photos", message: error.localizedDescription)
        }
        phase = .idle
        endBackgroundTask()
    }

    /// Deletes the clips of a take whose Photos save failed.
    func discardPendingTake() {
        guard let take = lastTake, !take.pendingURLs.isEmpty, phase == .idle else { return }
        for url in take.pendingURLs {
            try? FileManager.default.removeItem(at: url)
        }
        lastTake = nil
        isShowingLastTake = false
    }
}
