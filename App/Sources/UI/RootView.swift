import DeLoreCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.route {
            case .launching:
                SplashView()
                    .transition(.opacity)
            case .welcome:
                WelcomeView()
                    .transition(.opacity)
            case .connect:
                ConnectView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .home:
                HomeView()
                    .transition(.opacity)
            }
        }
        .screenBackground()
        .task { await model.bootstrap() }
        .sheet(item: $model.sheet) { sheet in
            SheetContent(sheet: sheet)
                .environment(model)
        }
        .fullScreenCover(isPresented: sessionBinding) {
            if let session = model.session {
                CleanupRunView(session: session)
                    .environment(model)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let session = model.session else { return }
            Task { await session.scenePhaseChanged(phase) }
        }
        .onChange(of: model.env.connectivity.isOnline) { _, online in
            guard let session = model.session else { return }
            Task { await session.connectivityChanged(isOnline: online) }
        }
    }

    private var sessionBinding: Binding<Bool> {
        Binding(
            get: { model.session != nil && model.isSessionPresented },
            set: { model.isSessionPresented = $0 }
        )
    }
}

private struct SheetContent: View {
    @Environment(AppModel.self) private var model
    let sheet: AppModel.Sheet

    var body: some View {
        switch sheet {
        case .settings:
            SettingsView()
        case .privacy:
            NavigationStack { PrivacyView() }
        case .chooseChats:
            if let overview = model.overview {
                ChooseChatsView(overview: overview)
            }
        case .included:
            if let overview = model.overview {
                IncludedView(overview: overview)
            }
        case let .setup(scope):
            if let overview = model.overview {
                CleanupSetupView(setup: CleanupSetupModel(overview: overview, scope: scope, env: model.env))
            }
        case let .paywall(context):
            PaywallView(context: context)
        case .unavailable:
            CleanupUnavailableView()
        }
    }
}

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        Wordmark()
            .scaleEffect(appeared ? 1.6 : 1.2)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { appeared = true }
            }
            .accessibilityLabel("DeLore is loading")
    }
}
