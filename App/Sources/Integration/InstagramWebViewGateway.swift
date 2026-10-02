import DeLoreCore
import Foundation
import UIKit
import WebKit

/// Hidden www.instagram.com WKWebView that runs inbox/GraphQL via in-page `fetch`,
/// matching Android's InstagramWebViewGateway. URLSession alone is often dropped by IG's edge.
@MainActor
final class InstagramWebViewGateway: NSObject, WKScriptMessageHandler {
    private let httpFallback: InstagramHTTPClient
    private var webView: WKWebView?
    private var pageReady = false
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var pending: [String: CheckedContinuation<HTTPResponse, Error>] = [:]
    private var fbDtsg: String?
    private var lsdToken: String?
    private var lastUserID: String?

    /// Off-screen host so WKWebView can run network/JS with a real window.
    let hostView: UIView = {
        let view = UIView(frame: CGRect(x: -4800, y: 0, width: 360, height: 640))
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }()

    init(sessionVault: SessionVault, logger: AppLogger) {
        httpFallback = InstagramHTTPClient(
            transport: URLSessionTransport(),
            sessionProvider: { try sessionVault.loadSession() },
            logger: logger
        )
        super.init()
    }

    @discardableResult
    func attachIfNeeded() -> WKWebView {
        if let webView { return webView }
        let page = WKWebpagePreferences()
        page.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences = page
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "retractNative")
        let view = WKWebView(frame: hostView.bounds, configuration: config)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.navigationDelegate = self
        view.customUserAgent = InstagramWebConstants.safariUserAgent
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.addSubview(view)
        webView = view
        return view
    }

    func destroy() {
        pending.values.forEach { $0.resume(throwing: IntegrationError.unavailable) }
        pending.removeAll()
        readyContinuation?.resume(throwing: IntegrationError.unavailable)
        readyContinuation = nil
        pageReady = false
        fbDtsg = nil
        lsdToken = nil
        lastUserID = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "retractNative")
        webView?.removeFromSuperview()
        webView = nil
    }

    func send(_ request: InstagramAPIRequest, session: InstagramWebSession) async throws -> HTTPResponse {
        let view = attachIfNeeded()
        do {
            try await ensureReady(session: session)
            return try await fetchInPage(webView: view, request: request, session: session)
        } catch let error as IntegrationError where error == .unavailable || isTransport(error) {
            if request.path.contains("graphql") { throw error }
            return try await httpFallback.send(request)
        } catch {
            if request.path.contains("graphql") { throw error }
            return try await httpFallback.send(request)
        }
    }

    private func isTransport(_ error: IntegrationError) -> Bool {
        if case .transportFailure = error { return true }
        return false
    }

    private func ensureReady(session: InstagramWebSession) async throws {
        try await installCookies(session)
        if lastUserID != session.userID {
            lastUserID = session.userID
            pageReady = false
        }
        let urlString = webView?.url?.absoluteString ?? ""
        let onWww = urlString.contains("instagram.com") && !urlString.contains("i.instagram.com")
        if pageReady && onWww {
            await harvestTokens()
            return
        }
        pageReady = false
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuation?.resume(throwing: IntegrationError.transportFailure(requestMayHaveBeenApplied: false))
            readyContinuation = cont
            webView?.load(URLRequest(url: InstagramWebConstants.inboxReferer))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if let stuck = self.readyContinuation {
                    self.readyContinuation = nil
                    stuck.resume(throwing: IntegrationError.transportFailure(requestMayHaveBeenApplied: false))
                }
            }
        }
        await harvestTokens()
    }

    private func installCookies(_ session: InstagramWebSession) async throws {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in session.cookies {
            var domain = cookie.domain
            if !domain.hasPrefix(".") { domain = ".\(domain)" }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name,
                .value: cookie.value,
                .domain: domain,
                .path: cookie.path.isEmpty ? "/" : cookie.path,
            ]
            if cookie.isSecure { properties[.secure] = "TRUE" }
            if let httpCookie = HTTPCookie(properties: properties) {
                await store.setCookie(httpCookie)
            }
        }
    }

    private func harvestTokens() async {
        guard let webView else { return }
        let storedDtsg = JSONSerialization.string(fbDtsg ?? "")
        let storedLsd = JSONSerialization.string(lsdToken ?? "")
        let script = """
        (function(){
          function decodeMeta(t){return String(t||'').replace(/\\\\u0022/g,'"').replace(/\\\\"/g,'"');}
          function grab(html,re){var m=decodeMeta(html).match(re);return (m&&m[1])?m[1]:'';}
          var dtsg='', lsd='';
          try{ if(typeof require==='function'){ dtsg=(require('DTSGInitialData')||{}).token||(require('DTSGInitData')||{}).token||''; lsd=(require('LSD')||{}).token||''; } }catch(e){}
          var html=''; try{ html=document.documentElement.innerHTML; }catch(e){}
          if(!dtsg) dtsg=grab(html,/"DTSGInitialData"[\\s\\S]{0,400}?"token"\\s*:\\s*"([^"]+)"/)||grab(html,/"dtsg"\\s*:\\s*\\{\\s*"token"\\s*:\\s*"([^"]+)"/)||grab(html,/name="fb_dtsg"[^>]*value="([^"]+)"/);
          if(!lsd) lsd=grab(html,/"LSD"[\\s\\S]{0,200}?"token"\\s*:\\s*"([^"]+)"/)||grab(html,/name="lsd"[^>]*value="([^"]+)"/);
          if(!dtsg) dtsg=\(storedDtsg);
          if(!lsd) lsd=\(storedLsd);
          return JSON.stringify({dtsg:dtsg||'',lsd:lsd||''});
        })();
        """
        guard let raw = try? await webView.evaluateJavaScript(script) as? String,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        if let dtsg = json["dtsg"], !dtsg.isEmpty { fbDtsg = dtsg }
        if let lsd = json["lsd"], !lsd.isEmpty { lsdToken = lsd }
    }

    private func fetchInPage(webView: WKWebView, request: InstagramAPIRequest, session: InstagramWebSession) async throws -> HTTPResponse {
        let csrf = session.csrfToken ?? ""
        guard !csrf.isEmpty else { throw IntegrationError.sessionExpired }
        let url = try InstagramHTTPClient.instagramURL(path: request.path, query: request.query, host: request.host)
        let graphql = request.path.contains("graphql")
        if graphql, (fbDtsg ?? "").isEmpty {
            await harvestTokens()
            if (fbDtsg ?? "").isEmpty { throw IntegrationError.unavailable }
        }

        let id = UUID().uuidString
        var headers: [String: String] = [
            "X-CSRFToken": csrf,
            "X-IG-App-ID": InstagramWebConstants.webAppID,
            "Accept": "*/*",
        ]
        if graphql {
            headers["X-FB-Friendly-Name"] = "direct_unsend_message"
            if let lsd = lsdToken, !lsd.isEmpty { headers["X-FB-LSD"] = lsd }
        } else {
            headers["X-Requested-With"] = "XMLHttpRequest"
            headers["Accept"] = "application/json"
        }

        var form = request.form
        if graphql {
            let dtsg = fbDtsg ?? ""
            form["fb_dtsg"] = dtsg
            form["jazoest"] = "2" + String(dtsg.unicodeScalars.reduce(0) { $0 + Int($1.value) })
            if form["lsd"] == nil, let lsd = lsdToken, !lsd.isEmpty { form["lsd"] = lsd }
        }
        if request.method == .post {
            form["_csrftoken"] = csrf
        }
        let body = InstagramHTTPClient.encodeForm(form)
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        let headersJSON = (try? String(data: JSONSerialization.data(withJSONObject: headers), encoding: .utf8)) ?? "{}"
        let storedDtsg = JSONSerialization.string(fbDtsg ?? "")
        let storedLsd = JSONSerialization.string(lsdToken ?? "")
        let userIdLit = JSONSerialization.string(session.userID)
        let idLit = JSONSerialization.string(id)
        let urlLit = JSONSerialization.string(url.absoluteString)
        let methodLit = JSONSerialization.string(request.method.rawValue)

        let script = """
        (function(){
          var headers = \(headersJSON);
          var body = \(JSONSerialization.string(bodyString));
          var graphql = \(graphql ? "true" : "false");
          var userId = \(userIdLit);
          function decodeMeta(t){return String(t||'').replace(/\\\\u0022/g,'"').replace(/\\\\"/g,'"');}
          function grab(html,re){var m=decodeMeta(html).match(re);return (m&&m[1])?m[1]:'';}
          function findTokens(){
            var dtsg='', lsd='';
            try{ if(typeof require==='function'){ dtsg=(require('DTSGInitialData')||{}).token||(require('DTSGInitData')||{}).token||''; lsd=(require('LSD')||{}).token||''; } }catch(e){}
            var html=''; try{ html=document.documentElement.innerHTML; }catch(e){}
            if(!dtsg) dtsg=grab(html,/"DTSGInitialData"[\\s\\S]{0,400}?"token"\\s*:\\s*"([^"]+)"/)||grab(html,/"dtsg"\\s*:\\s*\\{\\s*"token"\\s*:\\s*"([^"]+)"/)||grab(html,/name="fb_dtsg"[^>]*value="([^"]+)"/);
            if(!lsd) lsd=grab(html,/"LSD"[\\s\\S]{0,200}?"token"\\s*:\\s*"([^"]+)"/)||grab(html,/name="lsd"[^>]*value="([^"]+)"/);
            if(!dtsg) dtsg=\(storedDtsg);
            if(!lsd) lsd=\(storedLsd);
            return {dtsg:dtsg||'',lsd:lsd||''};
          }
          try {
            var csrfCookie = document.cookie.match(/(?:^|; )csrftoken=([^;]*)/);
            if (csrfCookie) headers['X-CSRFToken'] = decodeURIComponent(csrfCookie[1]);
            if (csrfCookie && body.indexOf('_csrftoken=') !== -1) {
              body = body.replace(/_csrftoken=[^&]*/, '_csrftoken=' + encodeURIComponent(decodeURIComponent(csrfCookie[1])));
            }
            if (graphql) {
              var tok = findTokens();
              if (!tok.dtsg) {
                window.webkit.messageHandlers.retractNative.postMessage({id:\(idLit), ok:false, message:'missing fb_dtsg'});
                return;
              }
              var params = new URLSearchParams();
              var actor = userId;
              try { if (typeof require==='function'){ var current=require('CurrentUserInitialData')||{}; actor=current.USER_ID||current.ACCOUNT_ID||actor; } } catch(e){}
              if (actor) { params.set('av', actor); params.set('__user', actor); }
              params.set('fb_api_caller_class', 'RelayModern');
              params.set('fb_api_req_friendly_name', 'direct_unsend_message');
              var existing = body.split('&');
              for (var i = 0; i < existing.length; i++) {
                var pair = existing[i].split('=');
                if (pair.length >= 2 && pair[0] === 'variables') params.set('variables', decodeURIComponent(pair.slice(1).join('=')));
                if (pair.length >= 2 && pair[0] === 'doc_id') params.set('doc_id', decodeURIComponent(pair[1]));
              }
              params.set('server_timestamps', 'true');
              params.set('fb_dtsg', tok.dtsg);
              var sum = 0;
              for (var j = 0; j < tok.dtsg.length; j++) sum += tok.dtsg.charCodeAt(j);
              params.set('jazoest', '2' + String(sum));
              if (tok.lsd) { params.set('lsd', tok.lsd); headers['X-FB-LSD'] = tok.lsd; }
              body = params.toString();
            }
          } catch (e) {}
          var opts = { method: \(methodLit), credentials:'include', mode:'cors', headers: headers };
          if (opts.method === 'POST' && body) {
            headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
            opts.body = body;
          }
          fetch(\(urlLit), opts).then(function(r){
            return r.text().then(function(t){
              window.webkit.messageHandlers.retractNative.postMessage({id:\(idLit), ok:true, status:r.status, body:t, destructive:\(request.destructive ? "true" : "false")});
            });
          }).catch(function(e){
            window.webkit.messageHandlers.retractNative.postMessage({id:\(idLit), ok:false, message:String(e&&e.message?e.message:e)});
          });
        })();
        """

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            webView.evaluateJavaScript(script) { _, error in
                Task { @MainActor in
                    if error != nil, let stuck = self.pending.removeValue(forKey: id) {
                        stuck.resume(throwing: IntegrationError.transportFailure(requestMayHaveBeenApplied: request.destructive))
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if let stuck = self.pending.removeValue(forKey: id) {
                    stuck.resume(throwing: IntegrationError.transportFailure(requestMayHaveBeenApplied: request.destructive))
                }
            }
        }
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard message.name == "retractNative",
                  let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  let cont = pending.removeValue(forKey: id) else { return }
            if body["ok"] as? Bool == true {
                let status = body["status"] as? Int ?? 0
                let text = body["body"] as? String ?? ""
                let destructive = body["destructive"] as? Bool ?? false
                let response = HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
                do {
                    try InstagramResponseClassifier.throwIfNeeded(response, destructive: destructive)
                    cont.resume(returning: response)
                } catch {
                    cont.resume(throwing: error)
                }
            } else {
                cont.resume(throwing: IntegrationError.transportFailure(requestMayHaveBeenApplied: false))
            }
        }
    }
}

extension InstagramWebViewGateway: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        readyContinuation?.resume()
        readyContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        readyContinuation?.resume(throwing: IntegrationError.transportFailure(requestMayHaveBeenApplied: false))
        readyContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        readyContinuation?.resume(throwing: IntegrationError.transportFailure(requestMayHaveBeenApplied: false))
        readyContinuation = nil
    }
}

/// InstagramAPIClient that prefers the www WebView fetch path.
final class InstagramWebViewAPIClient: InstagramAPIClient, @unchecked Sendable {
    private let gateway: InstagramWebViewGateway
    private let sessionVault: SessionVault

    init(gateway: InstagramWebViewGateway, sessionVault: SessionVault) {
        self.gateway = gateway
        self.sessionVault = sessionVault
    }

    func send(_ request: InstagramAPIRequest) async throws -> HTTPResponse {
        guard let session = try sessionVault.loadSession(), session.hasLiveSession else {
            throw IntegrationError.sessionExpired
        }
        return try await gateway.send(request, session: session)
    }
}

private extension JSONSerialization {
    static func string(_ value: String) -> String {
        guard let data = try? data(withJSONObject: value, options: [.fragmentsAllowed]),
              let out = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return out
    }
}
