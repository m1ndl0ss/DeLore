package app.delore.android.instagram

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.Keep
import app.delore.android.domain.HTTPMethod
import app.delore.android.domain.HTTPResponse
import app.delore.android.domain.IntegrationError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Talks to Instagram the same way the signed-in website does: `fetch()` inside a WebView
 * already sitting on instagram.com. OkHttp's TLS stack is often dropped on the floor by
 * Instagram's edge, which is why login (Chromium) worked and inbox reads did not.
 *
 * Surface: www.instagram.com for inbox/thread GETs, GraphQL Unsend, and `fb_dtsg` harvest.
 * GraphQL uses Relay headers only (no X-Requested-With / ig-u-ds-user-id / X-IG-WWW-Claim).
 * Keep the WebView on www — navigating to i.instagram.com breaks subsequent www GraphQL.
 */
class InstagramWebViewGateway {
    private val main = Handler(Looper.getMainLooper())
    private val mutex = Mutex()
    private val pending = ConcurrentHashMap<String, CompletableDeferred<NativeResult>>()
    private var webView: WebView? = null
    @Volatile private var pageReady = false
    private var readySignal: CompletableDeferred<Unit>? = null
    @Volatile private var wwwClaim = "0"
    @Volatile private var asbdID: String? = null
    @Volatile private var ajaxHash: String? = null
    @Volatile private var fbDtsg: String? = null
    @Volatile private var lsdToken: String? = null
    @Volatile private var lastUserID: String? = null
    /** Account whose sessionid we've already committed + loaded a fresh page for. */
    @Volatile private var committedUserId: String? = null

    val isAttached: Boolean get() = webView != null

    @SuppressLint("SetJavaScriptEnabled")
    fun attach(context: Context): WebView {
        webView?.let { return it }
        val view = WebView(context.applicationContext).apply {
            settings.applyInstagramWebsiteDefaults()
            settings.offscreenPreRaster = true
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            addJavascriptInterface(NativeBridge(), "DeloreNative")
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    return !InstagramLoginPolicy.allowsNavigation(request.url.toString())
                }

                override fun onPageFinished(view: WebView, url: String) {
                    Log.i("Retract", "IG webview page $url")
                    if (!InstagramLoginPolicy.isPostLogin(url)) {
                        if (url.contains("/accounts/login", ignoreCase = true) ||
                            url.contains("/challenge", ignoreCase = true) ||
                            url.contains("/two_factor", ignoreCase = true)
                        ) {
                            pageReady = false
                            readySignal?.completeExceptionally(IntegrationError.SessionExpired)
                            readySignal = null
                        }
                        return
                    }
                    main.postDelayed({
                        pageReady = true
                        readySignal?.complete(Unit)
                        readySignal = null
                    }, 900)
                }
            }
        }
        view.measure(
            android.view.View.MeasureSpec.makeMeasureSpec(1080, android.view.View.MeasureSpec.EXACTLY),
            android.view.View.MeasureSpec.makeMeasureSpec(1920, android.view.View.MeasureSpec.EXACTLY),
        )
        view.layout(0, 0, 1080, 1920)
        webView = view
        wake()
        return view
    }

    fun wake() {
        val run = {
            webView?.onResume()
            webView?.resumeTimers()
            Unit
        }
        if (Looper.myLooper() == Looper.getMainLooper()) run() else main.post(run)
    }

    fun destroy() {
        pending.values.forEach { it.cancel() }
        pending.clear()
        readySignal?.cancel()
        readySignal = null
        pageReady = false
        wwwClaim = "0"
        asbdID = null
        ajaxHash = null
        fbDtsg = null
        lsdToken = null
        lastUserID = null
        committedUserId = null
        InstagramRequestHost.reset()
        main.post {
            // Wipe cookies so logout cannot leave a reusable Instagram sessionid behind.
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
            webView?.destroy()
            webView = null
        }
    }

    suspend fun send(request: InstagramAPIRequest, session: InstagramWebSession): HTTPResponse {
        if (!session.hasLiveSession) throw IntegrationError.SessionExpired
        val csrf = session.csrfToken?.takeIf { it.isNotEmpty() } ?: throw IntegrationError.SessionExpired
        if (lastUserID != session.userID) {
            InstagramRequestHost.reset()
            lastUserID = session.userID
        }
        val url = InstagramHTTPClient.instagramUrl(request.path, request.query, request.host)
        return mutex.withLock {
            ensureReady(session, request)
            val id = UUID.randomUUID().toString()
            val deferred = CompletableDeferred<NativeResult>()
            pending[id] = deferred
            val script = fetchScript(id, request, url, csrf, session.userID)
            withContext(Dispatchers.Main) {
                val view = webView ?: throw IntegrationError.Unavailable
                view.evaluateJavascript(script, null)
            }
            val result = try {
                withTimeout(25_000) { deferred.await() }
            } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
                pending.remove(id)
                    Log.e("Retract", "IG webview fetch timed out ${request.host}${request.path}")
                throw IntegrationError.TransportFailure(request.destructive)
            } finally {
                pending.remove(id)
            }
            when (result) {
                is NativeResult.Failed -> {
                    Log.e("Retract", "IG webview fetch ${request.host}${request.path} failed")
                    throw IntegrationError.TransportFailure(request.destructive)
                }
                is NativeResult.Ok -> {
                    val headers = parseHeaders(result.headersJson)
                    headers["x-ig-set-www-claim"]?.takeIf { it.isNotEmpty() }?.let { wwwClaim = it }
                    Log.i(
                        "Retract",
                        "IG webview ${request.method} ${request.host}${request.path} -> ${result.status} bytes=${result.body.length} keys=${InstagramWebFormat.topKeys(result.body.toByteArray())} claim=${wwwClaim != "0"} dtsg=${!fbDtsg.isNullOrBlank()} prefix=${result.body.take(80).replace('\n', ' ')}",
                    )
                    val mapped = HTTPResponse(result.status, headers, result.body.toByteArray())
                    try {
                        InstagramResponseClassifier.throwIfNeeded(mapped, request.destructive)
                    } catch (error: IntegrationError.UnexpectedResponse) {
                        Log.e(
                            "Retract",
                            "IG unexpected ${request.host}${request.path} status=${result.status} body=${result.body.take(240)}",
                        )
                        throw error
                    }
                    mapped
                }
            }
        }
    }

    /** True when the shared CookieManager already holds a non-empty sessionid for www. */
    private fun cookieJarHasSession(): Boolean {
        val jar = CookieManager.getInstance().getCookie("https://www.instagram.com") ?: return false
        return Regex("(?:^|; )sessionid=[^;\\s]+").containsMatchIn(jar)
    }

    /**
     * Awaits the sessionid cookie commit (setCookie's callback form) before the
     * caller navigates, so the loaded page is authenticated. SameSite=None
     * matches Instagram's own sessionid so it rides cross-site navigations too.
     */
    private suspend fun commitSessionCookie(session: InstagramWebSession) {
        val sessionCookie = session.cookies.firstOrNull {
            it.name.equals("sessionid", ignoreCase = true) && it.value.isNotBlank()
        } ?: return
        val value = "${sessionCookie.name}=${sessionCookie.value}; Domain=.instagram.com; Path=/; Secure; SameSite=None"
        withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                CookieManager.getInstance().setCookie("https://www.instagram.com", value) { _ ->
                    CookieManager.getInstance().flush()
                    if (cont.isActive) cont.resume(Unit)
                }
            }
        }
    }

    private suspend fun awaitAttached(): WebView {
        if (webView != null) return webView!!
        try {
            withTimeout(12_000) {
                while (webView == null) delay(40)
            }
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            Log.e("Retract", "IG webview never attached")
            throw IntegrationError.Unavailable
        }
        return webView ?: throw IntegrationError.Unavailable
    }

    private suspend fun ensureReady(session: InstagramWebSession, request: InstagramAPIRequest) {
        val view = awaitAttached()
        // Both WebViews share the global CookieManager, so after an in-process
        // login the jar already holds Instagram's own cookies with their real
        // attributes (httpOnly sessionid, SameSite=None, host-scoped datr/mid).
        // Re-injecting the flattened vault copy here OVERWRITES those and makes
        // IG treat the session as logged-out (viewerId=0). Only seed the jar
        // from the vault on a cold restore, where no login WebView populated it.
        if (committedUserId != session.userID) {
            val jarHasSession = withContext(Dispatchers.Main) { cookieJarHasSession() }
            if (!jarHasSession) {
                withContext(Dispatchers.Main) { session.installIntoCookieManager() }
                commitSessionCookie(session)
                withContext(Dispatchers.Main) { pageReady = false }
            }
            committedUserId = session.userID
        }
        session.wwwClaimCookie?.takeIf { it.isNotBlank() && it != "0" }?.let { wwwClaim = it }
        val wantApiHost = request.host == InstagramWebConstants.API_HOST
        val mutatingApi = wantApiHost && request.method != HTTPMethod.GET
        val alreadyReady = withContext(Dispatchers.Main) {
            val url = view.url.orEmpty()
            val onApi = InstagramLoginPolicy.isApiSurface(url)
            val onWeb = InstagramLoginPolicy.isWebSurface(url)
            // www GraphQL/inbox must not run from i.instagram.com — fetch to www fails
            // ("Failed to fetch") after a REST delete navigates the WebView there.
            pageReady && when {
                mutatingApi -> onApi
                wantApiHost -> onApi
                else -> onWeb
            }
        }
        if (!alreadyReady) {
            val wait = CompletableDeferred<Unit>()
            readySignal = wait
            pageReady = false
            val loadUrl = if (wantApiHost) InstagramWebConstants.API_INBOX else InstagramWebConstants.INBOX_REFERER
            withContext(Dispatchers.Main) {
                Log.i("Retract", "IG webview loading $loadUrl")
                view.loadUrl(loadUrl)
            }
            try {
                withTimeout(22_000) { wait.await() }
            } catch (error: IntegrationError.SessionExpired) {
                readySignal = null
                throw error
            } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                readySignal = null
                val current = withContext(Dispatchers.Main) { view.url.orEmpty() }
                Log.e("Retract", "IG webview page timed out at $current")
                throw IntegrationError.TransportFailure(false)
            }
            val landed = withContext(Dispatchers.Main) { view.url.orEmpty() }
            if (wantApiHost && !InstagramLoginPolicy.isApiSurface(landed)) {
                Log.e("Retract", "IG api surface landed on $landed")
                throw IntegrationError.TransportFailure(request.destructive)
            }
            if (!wantApiHost && !InstagramLoginPolicy.isWebSurface(landed)) {
                Log.e("Retract", "IG web surface landed on $landed")
                throw IntegrationError.TransportFailure(request.destructive)
            }
        }
        val onWww = withContext(Dispatchers.Main) {
            InstagramLoginPolicy.isWebSurface(view.url.orEmpty())
        }
        // Skip JS harvest when tokens are already warm — it was firing after every thread page.
        if (onWww && (fbDtsg.isNullOrBlank() || lsdToken.isNullOrBlank())) {
            harvestTokens(view)
        }
    }

    private suspend fun harvestTokens(view: WebView) {
        val deferred = CompletableDeferred<String>()
        val storedDtsg = JSONObject.quote(fbDtsg.orEmpty())
        val storedLsd = JSONObject.quote(lsdToken.orEmpty())
        val script = """
            (function(){
              function decodeMeta(t) { return String(t || '').replace(/\\${"u0022"}/g, '"').replace(/\\"/g, '"'); }
              function grab(html, re) {
                var m = decodeMeta(html).match(re);
                return (m && m[1]) ? m[1] : '';
              }
              var dtsg = '';
              var src = '';
              try {
                if (typeof require === 'function') {
                  dtsg = (require('DTSGInitialData') || {}).token || (require('DTSGInitData') || {}).token || '';
                  if (dtsg) src = 'require';
                }
              } catch (e) {}
              var html = '';
              try { html = document.documentElement.innerHTML; } catch (e) {}
              if (!dtsg) { dtsg = grab(html, /"DTSGInitialData"\s*,\s*\[\s*\]\s*,\s*\{[^}]{0,500}?"token"\s*:\s*"([^"]+)"/); if (dtsg) src = 'init'; }
              if (!dtsg) { dtsg = grab(html, /"DTSGInitData"\s*,\s*\[\s*\]\s*,\s*\{[^}]{0,500}?"token"\s*:\s*"([^"]+)"/); if (dtsg) src = 'init2'; }
              if (!dtsg) { dtsg = grab(html, /"dtsg"\s*:\s*\{\s*"token"\s*:\s*"([^"]+)"/); if (dtsg) src = 'obj'; }
              if (!dtsg) { dtsg = grab(html, /name="fb_dtsg"[^>]*value="([^"]+)"/); if (dtsg) src = 'input'; }
              var lsd = '';
              try { if (typeof require === 'function') lsd = (require('LSD') || {}).token || ''; } catch (e) {}
              if (!lsd) lsd = grab(html, /"LSD"\s*,\s*\[\s*\]\s*,\s*\{[^}]{0,200}?"token"\s*:\s*"([^"]+)"/)
                || grab(html, /name="lsd"[^>]*value="([^"]+)"/);
              if (!dtsg) dtsg = $storedDtsg;
              if (!lsd) lsd = $storedLsd;
              var appId = '';
              try { appId = localStorage.getItem('instagramWebFBAppId') || ''; } catch (e) {}
              return JSON.stringify({dtsg: dtsg || '', lsd: lsd || '', src: src, require: typeof require === 'function', appId: !!appId});
            })();
        """.trimIndent()
        withContext(Dispatchers.Main) {
            view.evaluateJavascript(script) { result -> deferred.complete(result ?: "null") }
        }
        val raw = try {
            withTimeout(4_000) { deferred.await() }
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            Log.w("Retract", "IG harvest timed out")
            return
        }
        val payload = runCatching {
            JSONObject("{\"v\":$raw}").getString("v")
        }.getOrNull() ?: return
        val json = runCatching { JSONObject(payload) }.getOrNull() ?: return
        json.optString("dtsg").takeIf { it.isNotBlank() }?.let { fbDtsg = it }
        json.optString("lsd").takeIf { it.isNotBlank() }?.let { lsdToken = it }
        Log.i(
            "Retract",
            "IG harvest dtsg=${!fbDtsg.isNullOrBlank()} len=${fbDtsg?.length ?: 0} src=${json.optString("src")} require=${json.optBoolean("require")} lsd=${!lsdToken.isNullOrBlank()} appId=${json.optBoolean("appId")}",
        )
    }

    private fun fetchScript(
        id: String,
        request: InstagramAPIRequest,
        url: String,
        csrf: String,
        userID: String,
    ): String {
        val crossSite = request.host == InstagramWebConstants.API_HOST
        val graphql = request.path.contains("graphql")
        val headers = JSONObject()
            .put("X-CSRFToken", csrf)
            .put("X-IG-App-ID", InstagramWebConstants.WEB_APP_ID)
            .put("Accept", "*/*")
        if (graphql) {
            headers.put("X-FB-Friendly-Name", "direct_unsend_message")
            lsdToken?.takeIf { it.isNotBlank() }?.let { headers.put("X-FB-LSD", it) }
        } else {
            headers.put("X-Requested-With", "XMLHttpRequest")
            headers.put("X-IG-WWW-Claim", wwwClaim)
            // www/api/v1 serves the logged-out "Page Not Found" HTML shell when
            // Accept allows text/html (*/*); application/json routes to the JSON
            // API. Matches the iOS gateway (InstagramAPIClient Accept: json).
            headers.put("Accept", "application/json")
            headers.put("Accept-Language", "en-US,en;q=0.9")
            if (!crossSite) {
                asbdID?.let { headers.put("X-ASBD-ID", it) }
                ajaxHash?.let { headers.put("X-Instagram-AJAX", it) }
            }
        }
        val emptyBody = request.emptyBody
        val mutating = request.method == HTTPMethod.POST || request.method == HTTPMethod.DELETE
        if (mutating && !emptyBody) {
            headers.put("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
        }
        val formFields = if (emptyBody) {
            emptyMap()
        } else {
            InstagramHTTPClient.signedForm(request.form, csrf, request.destructive).toMutableMap().also { fields ->
                if (graphql) {
                    fbDtsg?.takeIf { it.isNotBlank() }?.let { token ->
                        fields.putIfAbsent("fb_dtsg", token)
                        fields.putIfAbsent("jazoest", InstagramWebBootstrap.jazoest(token))
                    }
                    lsdToken?.takeIf { it.isNotBlank() }?.let { fields.putIfAbsent("lsd", it) }
                }
            }
        }
        val formBody = InstagramForm.encode(formFields)
        val storedDtsg = JSONObject.quote(fbDtsg.orEmpty())
        val storedLsd = JSONObject.quote(lsdToken.orEmpty())
        val userIdLit = JSONObject.quote(userID)
        return """
            (function(){
              var headers = $headers;
              var body = ${JSONObject.quote(formBody)};
              var graphql = ${if (graphql) "true" else "false"};
              var emptyBody = ${if (emptyBody) "true" else "false"};
              var crossSite = ${if (crossSite) "true" else "false"};
              var userId = $userIdLit;
              function decodeMeta(t) {
                return String(t || '').replace(/\\${"u0022"}/g, '"').replace(/\\"/g, '"');
              }
              function grab(html, re) {
                var m = decodeMeta(html).match(re);
                return (m && m[1]) ? m[1] : '';
              }
              function findTokens() {
                var dtsg = '';
                var lsd = '';
                try {
                  if (typeof require === 'function') {
                    dtsg = (require('DTSGInitialData') || {}).token || (require('DTSGInitData') || {}).token || '';
                    lsd = (require('LSD') || {}).token || '';
                  }
                } catch (e) {}
                var html = '';
                try { html = document.documentElement.innerHTML; } catch (e) {}
                if (!dtsg) dtsg = grab(html, /"DTSGInitialData"\s*,\s*\[\s*\]\s*,\s*\{[^}]{0,500}?"token"\s*:\s*"([^"]+)"/)
                  || grab(html, /"DTSGInitData"\s*,\s*\[\s*\]\s*,\s*\{[^}]{0,500}?"token"\s*:\s*"([^"]+)"/)
                  || grab(html, /"dtsg"\s*:\s*\{\s*"token"\s*:\s*"([^"]+)"/)
                  || grab(html, /name="fb_dtsg"[^>]*value="([^"]+)"/);
                if (!lsd) lsd = grab(html, /"LSD"\s*,\s*\[\s*\]\s*,\s*\{[^}]{0,200}?"token"\s*:\s*"([^"]+)"/)
                  || grab(html, /name="lsd"[^>]*value="([^"]+)"/);
                if (!dtsg) dtsg = $storedDtsg;
                if (!lsd) lsd = $storedLsd;
                return {dtsg: dtsg || '', lsd: lsd || ''};
              }
              try {
                var html = document.documentElement.innerHTML;
                if (!graphql) {
                  var claim = (html.match(/"www_claim"\s*:\s*"([^"]+)"/) || [])[1];
                  if (claim && claim !== '0') headers['X-IG-WWW-Claim'] = claim;
                  var asbd = (html.match(/"ASBD_ID"\s*:\s*"(\d+)"/) || [])[1];
                  if (asbd && !crossSite) headers['X-ASBD-ID'] = asbd;
                  var ajax = (html.match(/"rollout_hash"\s*:\s*"([^"]+)"/) || [])[1];
                  if (ajax && !crossSite) headers['X-Instagram-AJAX'] = ajax;
                  var cookieClaim = document.cookie.match(/(?:^|; )ig_www_claim=([^;]*)/);
                  if (cookieClaim) {
                    var value = decodeURIComponent(cookieClaim[1]);
                    if (value && value !== '0') headers['X-IG-WWW-Claim'] = value;
                  }
                  try {
                    var storedClaim = sessionStorage.getItem('www-claim-v2');
                    if (storedClaim && storedClaim !== '0') headers['X-IG-WWW-Claim'] = storedClaim;
                  } catch (e) {}
                }
                var csrfCookie = document.cookie.match(/(?:^|; )csrftoken=([^;]*)/);
                if (csrfCookie) headers['X-CSRFToken'] = decodeURIComponent(csrfCookie[1]);
                if (csrfCookie && body.indexOf('_csrftoken=') !== -1) {
                  body = body.replace(/_csrftoken=[^&]*/, '_csrftoken=' + encodeURIComponent(decodeURIComponent(csrfCookie[1])));
                }
                try {
                  var appId = localStorage.getItem('instagramWebFBAppId');
                  if (appId) headers['X-IG-App-ID'] = appId;
                } catch (e) {}
                var tok = findTokens();
                if (graphql) {
                  var dtsg = tok.dtsg;
                  var lsd = tok.lsd;
                  if (!dtsg) {
                    DeloreNative.fail(${JSONObject.quote(id)}, 'missing fb_dtsg');
                    return;
                  }
                  var docId = grab(html, /"direct_unsend_message"[\s\S]{0,240}?"(\d{10,})"/);
                  var params = new URLSearchParams();
                  var actor = userId;
                  try {
                    if (typeof require === 'function') {
                      var current = require('CurrentUserInitialData') || {};
                      actor = current.USER_ID || current.ACCOUNT_ID || actor;
                    }
                  } catch (e) {}
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
                  if (docId) params.set('doc_id', docId);
                  if (dtsg) {
                    params.set('fb_dtsg', dtsg);
                    var sum = 0;
                    for (var j = 0; j < dtsg.length; j++) sum += dtsg.charCodeAt(j);
                    params.set('jazoest', '2' + String(sum));
                  }
                  if (lsd) {
                    params.set('lsd', lsd);
                    headers['X-FB-LSD'] = lsd;
                  }
                  try {
                    if (typeof require === 'function') {
                      var site = require('SiteData') || {};
                      if (site.__spin_r) params.set('__spin_r', String(site.__spin_r));
                      if (site.hsi) params.set('__hsi', String(site.hsi));
                      if (site.server_revision) params.set('__rev', String(site.server_revision));
                    }
                  } catch (e) {}
                  body = params.toString();
                }
              } catch (e) {}
              var tokOut = {dtsg: '', lsd: ''};
              try { tokOut = findTokens(); } catch (e) {}
              var opts = {
                method: ${JSONObject.quote(request.method.name)},
                credentials: 'include',
                mode: 'cors',
                headers: headers
              };
              if ((opts.method === 'POST' || opts.method === 'DELETE') && !emptyBody) {
                headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
                opts.body = body;
              }
              fetch(${JSONObject.quote(url)}, opts).then(function(r){
                var headerBag = {};
                try { r.headers.forEach(function(v, k){ headerBag[String(k).toLowerCase()] = v; }); } catch (e) {}
                return r.text().then(function(t){
                  DeloreNative.ok(${JSONObject.quote(id)}, r.status, t, JSON.stringify({
                    response: headerBag,
                    claim: headers['X-IG-WWW-Claim'] || '',
                    asbd: headers['X-ASBD-ID'] || '',
                    ajax: headers['X-Instagram-AJAX'] || '',
                    dtsg: tokOut.dtsg || '',
                    lsd: tokOut.lsd || ''
                  }));
                });
              }).catch(function(e){
                DeloreNative.fail(${JSONObject.quote(id)}, String(e && e.message ? e.message : e));
              });
            })();
        """.trimIndent()
    }

    private fun parseHeaders(raw: String): Map<String, String> {
        val json = runCatching { JSONObject(raw) }.getOrNull() ?: return emptyMap()
        json.optString("claim").takeIf { it.isNotBlank() && it != "0" }?.let { wwwClaim = it }
        json.optString("asbd").takeIf { it.isNotBlank() }?.let { asbdID = it }
        json.optString("ajax").takeIf { it.isNotBlank() }?.let { ajaxHash = it }
        json.optString("dtsg").takeIf { it.isNotBlank() }?.let { fbDtsg = it }
        json.optString("lsd").takeIf { it.isNotBlank() }?.let { lsdToken = it }
        val response = json.optJSONObject("response") ?: json
        val mapped = mutableMapOf<String, String>()
        response.keys().forEach { key ->
            val value = response.optString(key)
            if (value.isNotEmpty()) mapped[key.lowercase()] = value
        }
        mapped["x-ig-set-www-claim"]?.takeIf { it.isNotEmpty() }?.let { wwwClaim = it }
        return mapped
    }

    @Keep
    private inner class NativeBridge {
        @JavascriptInterface
        fun ok(id: String, status: Int, body: String, headersJson: String) {
            pending.remove(id)?.complete(NativeResult.Ok(status, body, headersJson))
        }

        @JavascriptInterface
        fun fail(id: String, message: String) {
            pending.remove(id)?.complete(NativeResult.Failed(message))
        }
    }

    private sealed class NativeResult {
        data class Ok(val status: Int, val body: String, val headersJson: String) : NativeResult()
        data class Failed(val message: String) : NativeResult()
    }
}
