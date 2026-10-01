import DeLoreCore
import SwiftUI
import UIKit

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
            case .home:
                MainTabs()
                    .transition(.opacity)
            }
        }
        .screenBackground()
        .task { await model.bootstrap() }
        .sheet(item: $model.sheet) { sheet in
            SheetContent(sheet: sheet)
                .environment(model)
                .paywallChrome(sheet)
        }
        .fullScreenCover(isPresented: sessionBinding) {
            if let session = model.session {
                CleanupRunView(session: session)
                    .environment(model)
                    .presentationBackground(.clear)
            }
        }
        .fullScreenCover(item: $model.termsPrompt) { prompt in
            TermsAcceptView(
                kind: prompt,
                onPrimary: { dontShow in model.acceptTermsPrompt(dontShowAgain: dontShow) },
                onCancel: { model.cancelTermsPrompt() }
            )
            .environment(model)
            .presentationBackground(.clear)
        }
        .fullScreenCover(item: $model.loginPurpose) { purpose in
            InstagramLoginView(
                onComplete: { session in model.handleLogin(session, purpose: purpose) },
                onCancel: { model.cancelLogin() }
            )
            .environment(model)
            .presentationBackground(.clear)
        }
        .fullScreenCover(item: inboxSyncBinding) { sync in
            InboxSyncView(sync: sync)
                .environment(model)
                .presentationBackground(.clear)
        }
        .fullScreenCover(item: importBinding) { importModel in
            ImportProgressView(importModel: importModel)
                .environment(model)
                .presentationBackground(.clear)
        }
        .tint(Palette.volt)
        .onChange(of: scenePhase) { _, phase in
            Task { await model.handleScenePhase(phase) }
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

    private var inboxSyncBinding: Binding<InboxSyncModel?> {
        Binding(get: { model.inboxSyncModel }, set: { if $0 == nil { model.dismissSync() } })
    }

    private var importBinding: Binding<ImportModel?> {
        Binding(get: { model.importModel }, set: { if $0 == nil { model.dismissImport() } })
    }
}

private struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            UnsendingView()
                .tabItem { Label("Unsending", systemImage: "eraser") }
                .tag(AppModel.Tab.unsending)
            ActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(AppModel.Tab.activity)
            SettingsTabView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .toolbarBackground(.hidden, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .background { ClearHostingBackground() }
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = UIColor(Palette.background).withAlphaComponent(0.62)
            appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
            let item = UITabBarItemAppearance()
            item.normal.iconColor = UIColor.white.withAlphaComponent(0.4)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.4)]
            item.selected.iconColor = UIColor(Palette.accent)
            item.selected.titleTextAttributes = [.foregroundColor: UIColor(Palette.accent)]
            appearance.stackedLayoutAppearance = item
            appearance.inlineLayoutAppearance = item
            appearance.compactInlineLayoutAppearance = item
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
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
        case .support:
            NavigationStack { FAQView() }
        case .terms:
            NavigationStack { TermsView() }
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
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.35)) { appeared = true }
            }
            .accessibilityLabel("Retract is loading")
    }
}

private extension View {
    @ViewBuilder
    func paywallChrome(_ sheet: AppModel.Sheet) -> some View {
        if case .paywall = sheet {
            self.presentationBackground(Palette.background)
        } else {
            self
        }
    }
}
