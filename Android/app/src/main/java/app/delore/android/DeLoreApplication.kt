package app.delore.android

import android.app.Application
import app.delore.android.engine.InstagramWorkController

class DeLoreApplication : Application() {
    lateinit var environment: AppEnvironment
        private set
    lateinit var work: InstagramWorkController
        private set

    override fun onCreate() {
        super.onCreate()
        environment = AppEnvironment(this)
        work = InstagramWorkController(this, environment)
    }
}
