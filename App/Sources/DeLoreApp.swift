import SwiftUI

@main
struct DeLoreApp: App {
    @State private var model: AppModel

    init() {
        BackgroundWorkCenter.register()
        _model = State(initialValue: AppModel(env: AppEnvironment()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Palette.volt)
                .preferredColorScheme(.dark)
        }
    }
}
