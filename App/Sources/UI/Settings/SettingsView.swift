import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingErase = false
    @State private var showingPaywall = false
    @State private var managingSubscription = false
    @State private var restoreMessage: LocalizedStringKey?

    private var entitlements: EntitlementManager { model.entitlements }

    var body: some View {
        NavigationStack {
            List {
                Section("Your plan") {
                    HStack {
                        Group {
                            if entitlements.isPro { Text("Pro") } else { Text("Free") }
                        }
                        .font(.title(.headline))
                        Spacer()
                        if entitlements.isPro, let date = entitlements.state.proRenewsOrExpiresAt {
                            Text("Renews \(date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryInk)
                        } else if !entitlements.isPro {
                            Text("^[\(entitlements.remainingFree) free message](inflect: true) left")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryInk)
                        }
                    }
                    if entitlements.state.cleanupPasses > 0 {
                        Label("^[\(entitlements.state.cleanupPasses) one-time cleanup](inflect: true) ready", systemImage: "ticket.fill")
                    }
                    if entitlements.isPro {
                        Button("Manage subscription") { managingSubscription = true }
                    } else {
                        Button("Get Pro") { showingPaywall = true }
                    }
                    Button("Restore purchases") {
                        Task {
                            if await entitlements.restore() {
                                restoreMessage = "Purchases restored."
                            } else {
                                restoreMessage = "We couldn't reach the App Store. Try again later."
                            }
                        }
                    }
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                }

                Section("Your data") {
                    NavigationLink("How we handle your data") { PrivacyView() }
                    Button("Refresh chats") {
                        dismiss()
                        model.refreshChats()
                    }
                    if !model.env.hasLiveSession {
                        Button("Reconnect Instagram") {
                            dismiss()
                            model.beginLogin(.reconnect)
                        }
                    }
                }

                Section("Help") {
                    Link("Support", destination: model.env.configuration.supportURL)
                    Link("Privacy policy", destination: model.env.configuration.privacyPolicyURL)
                    Link("Terms of use", destination: model.env.configuration.termsURL)
                }

                Section {
                    Button("Disconnect & delete my data", role: .destructive) { confirmingErase = true }
                        .accessibilityIdentifier("eraseData")
                } footer: {
                    Text("Removes your chats, Instagram login, cleanup progress and everything else stored on this phone. Purchases stay with your Apple ID.")
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("DeLore \(appVersion) · Not affiliated with Instagram or Meta.")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete everything on this phone?", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Delete my data", role: .destructive) {
                    Task { await model.eraseEverything() }
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("Any cleanup in progress stops. Messages already unsent stay unsent.")
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(context: .settings)
                    .environment(model)
            }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
