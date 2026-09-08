import DualCore
import Foundation
import UIKit

/// Summary of the most recent take. The clip files themselves are moved into
/// Photos, so only a poster frame and metadata are kept here.
struct LastTake: Identifiable {
    let id = UUID()
    let outputs: [FramingOutput]
    let thumbnail: UIImage?
    let date: Date
    let duration: Double
    let savedToPhotos: Bool
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct FocusIndicator: Equatable {
    let id: UUID
    let location: CGPoint
    let paneID: String
}
