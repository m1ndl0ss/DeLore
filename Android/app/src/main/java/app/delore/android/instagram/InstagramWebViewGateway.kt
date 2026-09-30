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
import app.delore.android.domain.HTTPResponse
import app.delore.android.domain.IntegrationError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Talks to Instagram the same way the signed-in website does: `fetch()` inside a WebView
 * already sitting on instagram.com. OkHttp's TLS stack is often dropped on the floor by
 * Instagram's edge, which is why login (Chromium) worked and inbox reads did not.
 */
class InstagramWebViewGateway {
    private val main = Handler(Looper.getMainLooper())
    private val mutex = Mutex()
    private val pending = ConcurrentHashMap<String, CompletableDeferred<NativeResult>>()
    private var webView: WebView? = null
    @Volatile private var pageReady = false
    private var readySignal: CompletableDeferred<Unit>? = null

    val isAttached: Boolean get() = webView != null

    @SuppressLint("SetJavaScriptEnabled")
    fun attach(context: Context): WebView {
        webView?.let { return it }
        val view = WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.userAgentString = InstagramWebConstants.CHROME_USER_AGENT
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
        webView = view
        return view
    }

    fun destroy() {
        pending.values.forEach { it.cancel() }
        pending.clear()
        readySignal?.cancel()
        readySignal = null
        pageReady = false
        main.post {
            webView?.destroy()
            webView = null
        }
    }

    suspend fun send(request: InstagramAPIRequest, session: InstagramWebSession): HTTPResponse {
        if (!session.hasLiveSession) throw IntegrationError.SessionExpired
        val csrf = session.csrfToken?.takeIf { it.isNotEmpty() } ?: throw IntegrationError.SessionExpired
        val url = InstagramHTTPClient.instagramUrl(request.path, request.query)
        return mutex.withLock {
            ensureReady(session)
            val id = UUID.randomUUID().toString()
            val deferred = CompletableDeferred<NativeResult>()
            pending[id] = deferred
            val script = fetchScript(id, request.method.name, url, csrf)
            withContext(Dispatchers.Main) {
                val view = webView ?: throw IntegrationError.Unavailable
                view.evaluateJavascript(script, null)
            }
            val result = try {
                withTimeout(25_000) { deferred.await() }
            } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
                pending.remove(id)
                Log.e("Retract", "IG webview fetch timed out ${request.path}")
                throw IntegrationError.TransportFailure(request.destructive)
            } finally {
                pending.remove(id)
            }
            when (result) {
                is NativeResult.Failed -> {
                    Log.e("Retract", "IG webview fetch ${request.path}: ${result.message}")
                    throw IntegrationError.TransportFailure(request.destructive)
                }
                is NativeResult.Ok -> {
                    Log.i(
                        "Retract",
                        "IG webview ${request.method} ${request.path} -> ${result.status} bytes=${result.body.length} keys=${InstagramWebFormat.topKeys(result.body.toByteArray())}",
                    )
                    val mapped = HTTPResponse(result.status, emptyMap(), result.body.toByteArray())
                    InstagramResponseClassifier.throwIfNeeded(mapped, request.destructive)
                    mapped
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

    private suspend fun ensureReady(session: InstagramWebSession) {
        val view = awaitAttached()
        withContext(Dispatchers.Main) {
            session.installIntoCookieManager()
        }
        val alreadyReady = withContext(Dispatchers.Main) {
            pageReady && InstagramLoginPolicy.isDirectSurface(view.url.orEmpty())
        }
        if (alreadyReady) return
        val wait = CompletableDeferred<Unit>()
        readySignal = wait
        pageReady = false
        withContext(Dispatchers.Main) {
            Log.i("Retract", "IG webview loading inbox")
            view.loadUrl(InstagramWebConstants.INBOX_REFERER)
        }
        try {
            withTimeout(22_000) { wait.await() }
        } catch (error: IntegrationError.SessionExpired) {
            readySignal = null
            throw error
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
            readySignal = null
            val current = withContext(Dispatchers.Main) { view.url.orEmpty() }
            Log.e("Retract", "IG webview inbox page timed out at $current")
            throw IntegrationError.TransportFailure(false)
        }
    }

    private fun fetchScript(id: String, method: String, url: String, csrf: String): String {
        val headers = JSONObject()
            .put("X-CSRFToken", csrf)
            .put("X-IG-App-ID", InstagramWebConstants.WEB_APP_ID)
            .put("X-Requested-With", "XMLHttpRequest")
            .put("Accept", "application/json")
            .put("X-IG-WWW-Claim", "0")
        return """
            (function(){
              var headers = $headers;
              try {
                var match = document.cookie.match(/(?:^|; )ig_www_claim=([^;]*)/);
                if (match) headers['X-IG-WWW-Claim'] = decodeURIComponent(match[1]);
              } catch (e) {}
              fetch(${JSONObject.quote(url)}, {
                method: ${JSONObject.quote(method)},
                credentials: 'include',
                headers: headers
              }).then(function(r){
                return r.text().then(function(t){
                  DeloreNative.ok(${JSONObject.quote(id)}, r.status, t);
                });
              }).catch(function(e){
                DeloreNative.fail(${JSONObject.quote(id)}, String(e && e.message ? e.message : e));
              });
            })();
        """.trimIndent()
    }

    @Keep
    private inner class NativeBridge {
        @JavascriptInterface
        fun ok(id: String, status: Int, body: String) {
            pending.remove(id)?.complete(NativeResult.Ok(status, body))
        }

        @JavascriptInterface
        fun fail(id: String, message: String) {
            pending.remove(id)?.complete(NativeResult.Failed(message))
        }
    }

    private sealed class NativeResult {
        data class Ok(val status: Int, val body: String) : NativeResult()
        data class Failed(val message: String) : NativeResult()
    }
}
