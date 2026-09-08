import AVFoundation
import Foundation

/// Camera and microphone permission helpers.
enum CameraAuthorization {

    enum Status: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    static func status(for mediaType: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Requests camera access (required) and microphone access (optional).
    /// Returns the resulting camera status and whether the microphone is usable.
    static func request() async -> (camera: Status, microphone: Bool) {
        var cameraStatus = status(for: .video)
        if cameraStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraStatus = granted ? .authorized : .denied
        }
        var microphoneGranted = status(for: .audio) == .authorized
        if cameraStatus == .authorized, status(for: .audio) == .notDetermined {
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return (cameraStatus, microphoneGranted)
    }
}
