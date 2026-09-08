import Foundation

/// A Core Image filter recipe. Kept as plain data so it can be defined and
/// tested without importing CoreImage; the app turns it into a CIFilter.
public struct VideoFilterPreset: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// CIFilter name, nil for the pass-through "None" preset.
    public let ciFilterName: String?
    /// Numeric filter inputs keyed by CoreImage input key (e.g. "inputIntensity").
    public let parameters: [String: Double]

    public init(id: String, displayName: String, ciFilterName: String?, parameters: [String: Double] = [:]) {
        self.id = id
        self.displayName = displayName
        self.ciFilterName = ciFilterName
        self.parameters = parameters
    }

    public var isIdentity: Bool { ciFilterName == nil }

    public static let passthrough = VideoFilterPreset(id: "none", displayName: "None", ciFilterName: nil)
    public static let vivid = VideoFilterPreset(id: "vivid", displayName: "Vivid", ciFilterName: "CIVibrance", parameters: ["inputAmount": 0.8])
    public static let warm = VideoFilterPreset(id: "warm", displayName: "Warm", ciFilterName: "CISepiaTone", parameters: ["inputIntensity": 0.35])
    public static let chrome = VideoFilterPreset(id: "chrome", displayName: "Chrome", ciFilterName: "CIPhotoEffectChrome")
    public static let fade = VideoFilterPreset(id: "fade", displayName: "Fade", ciFilterName: "CIPhotoEffectFade")
    public static let instant = VideoFilterPreset(id: "instant", displayName: "Instant", ciFilterName: "CIPhotoEffectInstant")
    public static let transfer = VideoFilterPreset(id: "transfer", displayName: "Transfer", ciFilterName: "CIPhotoEffectTransfer")
    public static let mono = VideoFilterPreset(id: "mono", displayName: "Mono", ciFilterName: "CIPhotoEffectMono")
    public static let noir = VideoFilterPreset(id: "noir", displayName: "Noir", ciFilterName: "CIPhotoEffectNoir")

    /// Presets in the order shown by the filter picker.
    public static let all: [VideoFilterPreset] = [.passthrough, .vivid, .warm, .chrome, .fade, .instant, .transfer, .mono, .noir]

    public static func preset(withID id: String) -> VideoFilterPreset {
        all.first { $0.id == id } ?? .passthrough
    }
}
