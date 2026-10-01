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
import android.util.Log
import androidx.core.app.NotificationCompat
import app.delore.android.MainActivity
import java.util.concurrent.atomic.AtomicBoolean

class CleanupForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundNotification(DEFAULT_TEXT)
        if (pendingStop.get()) {
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (pendingStop.get()) {
            startForegroundNotification(intent?.getStringExtra(EXTRA_TEXT) ?: DEFAULT_TEXT)
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundNotification(intent?.getStringExtra(EXTRA_TEXT) ?: DEFAULT_TEXT)
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) {
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        promoted.set(false)
        inForeground.set(false)
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        startForegroundNotification(DEFAULT_TEXT)
    }

    private fun startForegroundNotification(text: String) {
        ensureChannel(this)
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
        inForeground.set(true)
        if (pendingStop.get()) stopSelf()
    }

    companion object {
        private const val CHANNEL = "cleanup"
        private const val EXTRA_TEXT = "text"
        const val DEFAULT_TEXT = "Retract is working"
        private val promoted = AtomicBoolean(false)
        private val inForeground = AtomicBoolean(false)
        private val pendingStop = AtomicBoolean(false)

        fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Cleanup", NotificationManager.IMPORTANCE_LOW),
            )
        }

        fun start(context: Context, text: String = DEFAULT_TEXT) {
            val app = context.applicationContext
            pendingStop.set(false)
            val intent = Intent(app, CleanupForegroundService::class.java).putExtra(EXTRA_TEXT, text)
            try {
                if (promoted.compareAndSet(false, true)) {
                    if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent) else app.startService(intent)
                } else {
                    app.startService(intent)
                }
            } catch (error: Exception) {
                promoted.set(false)
                Log.e("Retract", "could not start cleanup service: ${error.message}")
            }
        }

        fun stop(context: Context) {
            pendingStop.set(true)
            if (!inForeground.get()) return
            promoted.set(false)
            inForeground.set(false)
            context.applicationContext.stopService(
                Intent(context.applicationContext, CleanupForegroundService::class.java),
            )
        }
    }
}
