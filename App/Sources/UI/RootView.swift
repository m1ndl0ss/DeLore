import DeLoreCore
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            InstagramBrowserHost(gateway: model.env.webBrowser)
            switch model.route {
            case .launching:
                SplashView()
                    .transition(.opacity)
            case .home:
                MainTabs()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if model.isDemoMode { DemoBanner() }
        }
        .screenBackground()
        .task { await model.bootstrap() }
        .sheet(item: otherSheetBinding) { sheet in
            SheetContent(sheet: sheet)
                .environment(model)
                .paywallChrome(sheet)
        }
        .fullScreenCover(item: setupSheetBinding) { presented in
            if let overview = model.overview {
                CleanupSetupView(setup: CleanupSetupModel(overview: overview, scope: presented.scope, env: model.env))
                    .environment(model)
                    .presentationBackground(Palette.background)
            }
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

    private var setupSheetBinding: Binding<SetupPresentation?> {
        Binding(
            get: {
                if case let .setup(scope) = model.sheet { return SetupPresentation(scope: scope) }
                return nil
            },
            set: { if $0 == nil { model.sheet = nil } }
        )
    }

    private var otherSheetBinding: Binding<AppModel.Sheet?> {
        Binding(
            get: {
                if case .setup = model.sheet { return nil }
                return model.sheet
            },
            set: { model.sheet = $0 }
        )
    }

    private var inboxSyncBinding: Binding<InboxSyncModel?> {
        Binding(get: { model.inboxSyncModel }, set: { if $0 == nil { model.dismissSync() } })
    }

    private var importBinding: Binding<ImportModel?> {
        Binding(get: { model.importModel }, set: { if $0 == nil { model.dismissImport() } })
    }
}

private struct InstagramBrowserHost: UIViewRepresentable {
    let gateway: InstagramWebViewGateway

    func makeUIView(context: Context) -> UIView {
        let host = gateway.hostView
        host.removeFromSuperview()
        gateway.attachIfNeeded()
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        gateway.attachIfNeeded()
    }
}

private struct SetupPresentation: Identifiable {
    let scope: CleanupScope
    var id: String {
        switch scope {
        case .everything: return "everything"
        case let .conversations(ids): return ids.map(\.rawValue).sorted().joined(separator: ",")
        }
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
        .animation(.easeOut(duration: 0.2), value: model.tab)
        .toolbarBackground(.hidden, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .background { ClearHostingBackground() }
        .onChange(of: model.tab) { _, tab in
            if tab == .activity { model.reloadHistory() }
        }
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
        case .setup:
            EmptyView()
        case let .paywall(context):
            PaywallView(context: context)
        case .unavailable:
            CleanupUnavailableView()
        }
    }
}

/// Persistent reviewer-mode marker shown at the top of every screen in demo mode.
private struct DemoBanner: View {
    var body: some View {
        Text("Sample inbox (reviewer mode)")
            .font(Type.medium(12))
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Palette.accent)
            .allowsHitTesting(false)
    }
}

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Spacing.m) {
            Wordmark()
                .scaleEffect(appeared ? 1.08 : 0.94)
            Text("Take it back.")
                .font(Type.medium(22))
                .foregroundStyle(Palette.ink.opacity(0.72))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Retract is loading")
    }
}

private extension View {
    @ViewBuilder
    func paywallChrome(_ sheet: AppModel.Sheet) -> some View {
        switch sheet {
        case .paywall, .privacy, .support, .terms:
            self.presentationBackground(Palette.background)
        default:
            self
        }
    }
}
