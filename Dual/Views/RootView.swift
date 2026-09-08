import SwiftUI

struct RootView: View {
    let model: CameraModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.authorization {
            case .authorized:
                CameraScreen(model: model)
            case .denied:
                PermissionView(model: model, isDenied: true)
            case .unknown, .requesting:
                PermissionView(model: model, isDenied: false)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.handleScenePhase(newPhase)
        }
    }
}
