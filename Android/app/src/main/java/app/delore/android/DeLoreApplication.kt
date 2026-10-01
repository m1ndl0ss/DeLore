package app.delore.android

import android.app.Application
import app.delore.android.engine.CleanupForegroundService
import app.delore.android.engine.InstagramWorkController

class DeLoreApplication : Application() {
    val environment: AppEnvironment by lazy { AppEnvironment(this) }
    val work: InstagramWorkController by lazy { InstagramWorkController(this, environment) }

    override fun onCreate() {
        super.onCreate()
        CleanupForegroundService.ensureChannel(this)
    }
}
