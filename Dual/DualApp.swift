import SwiftUI

@main
struct DualApp: App {
    @State private var model = CameraModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
