package app.delore.android.engine

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import app.delore.android.DeLoreApplication
import app.delore.android.MainActivity

class CleanupForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        (application as? DeLoreApplication)?.work?.attachBrowser()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: DEFAULT_TEXT
        startForegroundNotification(text)
        if (intent == null) {
            (application as? DeLoreApplication)?.work?.resumePersistedWork()
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        startForegroundNotification(DEFAULT_TEXT)
    }

    private fun startForegroundNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Reading & unsending", NotificationManager.IMPORTANCE_LOW),
        )
        val launch = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle("Retract")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(launch)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1, notification)
        }
    }

    companion object {
        private const val CHANNEL = "cleanup"
        private const val EXTRA_TEXT = "text"
        const val DEFAULT_TEXT = "Retract is working. You can leave."

        fun start(context: Context, text: String = DEFAULT_TEXT) {
            val intent = Intent(context, CleanupForegroundService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CleanupForegroundService::class.java))
        }
    }
}
