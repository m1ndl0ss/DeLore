package app.delore.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import app.delore.android.ui.DeLoreRoot
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var model: AppViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val env = (application as DeLoreApplication).environment
        model = ViewModelProvider(this, AppViewModel.Factory(env))[AppViewModel::class.java]
        setContent { DeLoreRoot(model) }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                model.onAppForeground()
            }
        }
    }

    override fun onStop() {
        super.onStop()
        model.onAppBackground()
    }

    override fun onStart() {
        super.onStart()
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
