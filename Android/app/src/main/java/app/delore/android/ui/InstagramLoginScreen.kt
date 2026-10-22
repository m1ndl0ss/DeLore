package app.delore.android.ui

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import app.delore.android.instagram.InstagramLoginPolicy
import app.delore.android.instagram.InstagramWebConstants
import app.delore.android.instagram.InstagramWebSession
import app.delore.android.instagram.applyInstagramWebsiteDefaults
import java.util.concurrent.atomic.AtomicBoolean

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun InstagramLoginScreen(
    onComplete: (InstagramWebSession) -> Unit,
    onCancel: () -> Unit,
) {
    var working by remember { mutableStateOf(true) }
    BackHandler(onBack = onCancel)
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
        Row(
            Modifier.padding(horizontal = Spacing.screen, vertical = Spacing.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Wordmark()
            Spacer(Modifier.weight(1f))
            CloseButton(onCancel)
        }
        Text(
            "Continue on Instagram.com",
            color = Palette.ink(),
            fontWeight = FontWeight.Bold,
            fontSize = 20.sp,
            modifier = Modifier.padding(horizontal = Spacing.screen, vertical = Spacing.s),
        )
        Box(
            Modifier
                .weight(1f)
                .padding(horizontal = Spacing.m)
                .clip(RoundedCornerShape(20.dp)),
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { context ->
                    val finished = AtomicBoolean(false)
                    val requestedInbox = AtomicBoolean(false)
                    CookieManager.getInstance().setAcceptCookie(true)
                    CookieManager.getInstance().removeAllCookies(null)
                    WebView(context).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                        settings.applyInstagramWebsiteDefaults()
                        settings.useWideViewPort = true
                        settings.loadWithOverviewMode = true
                        settings.builtInZoomControls = true
                        settings.displayZoomControls = false
                        webChromeClient = WebChromeClient()
                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                                val url = request.url.toString()
                                return !InstagramLoginPolicy.allowsNavigation(url)
                            }

                            override fun onPageFinished(view: WebView, url: String) {
                                working = false
                                if (!InstagramLoginPolicy.isPostLogin(url)) return
                                if (!InstagramLoginPolicy.isDirectSurface(url) && requestedInbox.compareAndSet(false, true)) {
                                    view.loadUrl(InstagramWebConstants.INBOX_REFERER)
                                    return
                                }
                                view.postDelayed({ captureCookies(finished, onComplete) }, 800)
                            }
                        }
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                        loadUrl(InstagramWebConstants.LOGIN_URL)
                    }
                },
            )
            if (working) {
                CircularProgressIndicator(Modifier.align(Alignment.Center), color = Palette.ink())
            }
        }
        Text(
            "This is Instagram.com’s sign-in page. We never see your password. If Instagram asks you to verify, do that here — we won't skip it.",
            color = Palette.secondaryInk(),
            fontSize = 13.sp,
            modifier = Modifier.padding(Spacing.screen),
        )
        }
    }
}

private fun captureCookies(finished: AtomicBoolean, onComplete: (InstagramWebSession) -> Unit) {
    if (finished.get()) return
    CookieManager.getInstance().flush()
    val cookies = readInstagramCookies()
    val session = InstagramWebSession.from(cookies) ?: return
    if (!finished.compareAndSet(false, true)) return
    onComplete(session)
}

private fun readInstagramCookies(): List<InstagramWebSession.Cookie> {
    val manager = CookieManager.getInstance()
    val seen = LinkedHashMap<String, InstagramWebSession.Cookie>()
    for (host in listOf("https://www.instagram.com", "https://instagram.com", "https://i.instagram.com")) {
        val header = manager.getCookie(host) ?: continue
        for (part in header.split(";")) {
            val trimmed = part.trim()
            val eq = trimmed.indexOf('=')
            if (eq <= 0) continue
            val name = trimmed.substring(0, eq)
            seen[name.lowercase()] = InstagramWebSession.Cookie(
                name = name,
                value = trimmed.substring(eq + 1),
                domain = ".instagram.com",
                path = "/",
                isSecure = true,
            )
        }
    }
    return seen.values.toList()
}
