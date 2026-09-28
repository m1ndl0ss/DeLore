package app.delore.android.ui

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
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
import java.util.concurrent.atomic.AtomicBoolean

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun InstagramLoginScreen(
    onComplete: (InstagramWebSession) -> Unit,
    onCancel: () -> Unit,
) {
    var working by remember { mutableStateOf(true) }
    Column(
        Modifier
            .fillMaxSize()
            .background(Palette.background()),
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
            "Sign in with Instagram",
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
                    CookieManager.getInstance().setAcceptCookie(true)
                    CookieManager.getInstance().removeAllCookies(null)
                    WebView(context).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.userAgentString = InstagramWebConstants.CHROME_USER_AGENT
                        webChromeClient = WebChromeClient()
                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                                val url = request.url.toString()
                                return !InstagramLoginPolicy.allowsNavigation(url)
                            }

                            override fun onPageFinished(view: WebView, url: String) {
                                working = false
                                captureCookies(finished, onComplete)
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
            "This is Instagram's sign-in page. We never see your password. If Instagram asks you to verify, do that here — we won't skip it.",
            color = Palette.secondaryInk(),
            fontSize = 13.sp,
            modifier = Modifier.padding(Spacing.screen),
        )
    }
}

private fun captureCookies(finished: AtomicBoolean, onComplete: (InstagramWebSession) -> Unit) {
    if (finished.get()) return
    val header = CookieManager.getInstance().getCookie("https://www.instagram.com") ?: return
    val cookies = header.split(";").mapNotNull { part ->
        val trimmed = part.trim()
        val eq = trimmed.indexOf('=')
        if (eq <= 0) return@mapNotNull null
        InstagramWebSession.Cookie(
            name = trimmed.substring(0, eq),
            value = trimmed.substring(eq + 1),
            domain = ".instagram.com",
            path = "/",
            isSecure = true,
        )
    }
    val session = InstagramWebSession.from(cookies) ?: return
    if (!finished.compareAndSet(false, true)) return
    onComplete(session)
}
