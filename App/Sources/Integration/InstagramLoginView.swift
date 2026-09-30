import DeLoreCore
import SwiftUI
import WebKit

/// Instagram's own login page, shown in-app. We never collect the password: the user types
/// it into Instagram, and we only keep the session cookies Instagram sets afterwards.
struct InstagramLoginView: View {
    var onComplete: (InstagramWebSession) -> Void
    var onCancel: () -> Void
    @State private var isWorking = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Wordmark()
                Spacer()
                CloseButton(action: onCancel)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.s)

            Text("Sign in with Instagram")
                .font(.title(.headline))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, Spacing.s)

            ZStack {
                LoginWebView(onComplete: onComplete, isWorking: $isWorking)
                if isWorking {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Palette.ink)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, Spacing.m)

            Text("This is Instagram's sign-in page. We never see your password. If Instagram asks you to verify, do that here — we won't skip it.")
                .font(.footnote)
                .foregroundStyle(Palette.secondaryInk)
                .padding(Spacing.screen)
        }
        .screenBackground()
        .accessibilityIdentifier("instagramLogin")
    }
}

private struct LoginWebView: UIViewRepresentable {
    var onComplete: (InstagramWebSession) -> Void
    @Binding var isWorking: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, isWorking: $isWorking)
    }

    func makeUIView(context: Context) -> WKWebView {
        let page = WKWebpagePreferences()
        page.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences = page
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = InstagramWebConstants.safariUserAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = view
        view.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        view.load(URLRequest(url: InstagramWebConstants.loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        coordinator.cancel()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let onComplete: (InstagramWebSession) -> Void
        var isWorking: Binding<Bool>
        weak var webView: WKWebView?
        private var finished = false
        private var requestedInbox = false
        private let lock = NSLock()

        init(onComplete: @escaping (InstagramWebSession) -> Void, isWorking: Binding<Bool>) {
            self.onComplete = onComplete
            self.isWorking = isWorking
        }

        func cancel() {
            lock.withLock { finished = true }
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard let url = webView?.url, InstagramLoginPolicy.isPostLogin(url: url) else { return }
            if !InstagramLoginPolicy.isDirectSurface(url: url) {
                requestInboxIfNeeded()
                return
            }
            capture(from: cookieStore)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isWorking.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isWorking.wrappedValue = false
            guard let url = webView.url, InstagramLoginPolicy.isPostLogin(url: url) else { return }
            if !InstagramLoginPolicy.isDirectSurface(url: url), requestInboxIfNeeded() {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let store = self.webView?.configuration.websiteDataStore.httpCookieStore else { return }
                self.capture(from: store)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isWorking.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isWorking.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url, !InstagramLoginPolicy.allowsNavigation(to: url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        @discardableResult
        private func requestInboxIfNeeded() -> Bool {
            if requestedInbox { return false }
            requestedInbox = true
            webView?.load(URLRequest(url: InstagramWebConstants.inboxReferer, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            return true
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, InstagramLoginPolicy.allowsNavigation(to: url) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func capture(from store: WKHTTPCookieStore) {
            if lock.withLock({ finished }) { return }
            store.getAllCookies { [weak self] cookies in
                self?.completeIfReady(cookies)
            }
        }

        private func completeIfReady(_ cookies: [HTTPCookie]) {
            let mapped = cookies.map {
                InstagramWebSession.Cookie(
                    name: $0.name,
                    value: $0.value,
                    domain: $0.domain,
                    path: $0.path,
                    isSecure: $0.isSecure,
                    expiresAt: $0.expiresDate
                )
            }
            guard let session = InstagramWebSession.from(cookies: mapped) else { return }
            let shouldComplete = lock.withLock { () -> Bool in
                if finished { return false }
                finished = true
                return true
            }
            guard shouldComplete else { return }
            Task { @MainActor in
                self.onComplete(session)
            }
        }
    }
}
