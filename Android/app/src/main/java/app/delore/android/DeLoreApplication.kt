package app.delore.android

import android.app.Application

class DeLoreApplication : Application() {
    lateinit var environment: AppEnvironment
        private set

    override fun onCreate() {
        super.onCreate()
        environment = AppEnvironment(this)
    }
}
