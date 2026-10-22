import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingErase = false
    @State private var showingPaywall = false
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
                    if !entitlements.isPro {
                        Button("Get Pro") { showingPaywall = true }
                    } else {
                        Button("View plan") { showingPaywall = true }
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

                Section("Instagram") {
                    if model.env.hasLiveSession {
                        Text("Connected · stays on this phone")
                            .foregroundStyle(Palette.secondaryInk)
                        Button("Log out", role: .destructive) {
                            Task {
                                await model.logOutInstagram()
                                dismiss()
                            }
                        }
                    } else {
                        Button("Connect Instagram") {
                            dismiss()
                            model.beginLogin(.connect)
                        }
                    }
                }

                Section("Your data") {
                    NavigationLink("How we handle your data") { PrivacyView() }
                }

                Section("Help") {
                    NavigationLink("Support") { FAQView() }
                    NavigationLink("Privacy policy") { PrivacyView() }
                    NavigationLink("Terms of use") { TermsView() }
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
                    Text("Retract \(appVersion) · We never read your chats. Not affiliated with Instagram or Meta. We are not responsible for anything that happens to your Instagram account.")
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
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
            .alert(
                "Couldn't delete your server data",
                isPresented: Binding(
                    get: { model.eraseServerFailure },
                    set: { model.eraseServerFailure = $0 }
                )
            ) {
                Button("Try again", role: .destructive) { Task { await model.eraseEverything() } }
                Button("Delete from this phone only", role: .destructive) {
                    Task { await model.eraseEverything(skipServerDelete: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Retract server couldn't be reached, so your usage record is still there. Nothing on this phone was removed yet. You can also email contact@kandalintsev.com.")
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(context: .settings)
                    .environment(model)
                    .presentationBackground(Palette.background)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
