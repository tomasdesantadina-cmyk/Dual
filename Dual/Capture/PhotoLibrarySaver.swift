import AVFoundation
import Foundation
import Photos
import UIKit

/// Saves finished clips and snapshots to the Photos library (add-only access).
enum PhotoLibrarySaver {

    enum SaveError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Dual is not allowed to add to your photo library. You can change this in Settings."
            }
        }
    }

    static func ensureAddAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Moves every video file into the library (no duplicate copy on disk). After
    /// this returns successfully the URLs are no longer valid.
    static func saveVideos(at urls: [URL]) async throws {
        guard await ensureAddAccess() else { throw SaveError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
            }
        }
    }

    static func saveImage(data: Data) async throws {
        guard await ensureAddAccess() else { throw SaveError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}

/// Generates poster frames and reads durations for the gallery thumbnail.
enum ThumbnailMaker {
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return 0
        }
    }

    static func thumbnail(for url: URL, maxSide: CGFloat = 240) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
}

/// Where finished takes live on disk before (and after) they are copied to Photos.
enum TakeStorage {
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Takes", isDirectory: true)
    }

    @discardableResult
    static func prepareDirectory() throws -> URL {
        let url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func baseName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Dual-" + formatter.string(from: date)
    }

    /// Deletes every stored take except the given URLs.
    static func removeAllTakes(except keep: [URL] = []) {
        let keepPaths = Set(keep.map { $0.standardizedFileURL.path })
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents where !keepPaths.contains(url.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
