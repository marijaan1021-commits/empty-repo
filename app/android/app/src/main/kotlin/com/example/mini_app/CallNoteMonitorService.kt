package com.example.mini_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps the app alive so a reminder can still be posted when the user has
 * swiped CallNote out of the recents list.
 *
 * It is a foreground service, because a background service would be killed
 * within minutes of the app leaving the foreground - which is exactly the
 * situation we want to survive. The ongoing notification it shows is the
 * standard Android way of telling the user that something is running.
 *
 * The service type is "specialUse": watching the call log is not one of the
 * types Android has a dedicated permission for, and unlike the dataSync type
 * it may also be started from a BOOT_COMPLETED receiver on Android 15+.
 */
class CallNoteMonitorService : Service() {

    companion object {
        private const val TAG = "CallNote"
        private const val CHANNEL_ID = "callnote_monitor"
        private const val NOTIF_ID = 4719

        fun start(ctx: Context) {
            if (!CallNoteEngine.isMonitoring(ctx)) return
            if (!notificationsAllowed(ctx)) {
                // The ongoing notification is the only way the user can see
                // that the watcher is running. Without POST_NOTIFICATIONS the
                // service would work invisibly, which is worse than being off.
                Log.w(TAG, "not starting the monitor service: notifications are not allowed")
                return
            }
            val intent = Intent(ctx, CallNoteMonitorService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "could not start monitor service: ${e.message}")
            }
        }

        /**
         * True when the app is allowed to show notifications.
         *
         * A notification that the system silently drops is the same as no
         * notification at all, so this gates the whole watcher.
         */
        fun notificationsAllowed(ctx: Context): Boolean {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            return nm == null || nm.areNotificationsEnabled()
        }

        fun stop(ctx: Context) {
            try {
                ctx.stopService(Intent(ctx, CallNoteMonitorService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "could not stop monitor service: ${e.message}")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        startForegroundCompat(buildNotification())
        CallNoteEngine.get(this).startCallLogWatch()
        Log.i(TAG, "monitor service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The user may have turned notifications off while we were running.
        if (!notificationsAllowed(this)) {
            Log.w(TAG, "notifications were turned off - stopping the monitor service")
            CallNoteEngine.get(this).stopCallLogWatch()
            stopSelf()
            return START_NOT_STICKY
        }
        startForegroundCompat(buildNotification())
        // Both are safe to call again: the phone state watcher may have been
        // unable to start earlier because READ_PHONE_STATE was not granted yet.
        CallNoteEngine.get(this).startCallLogWatch()
        CallNoteEngine.get(this).ensureCallStateWatch()
        // STICKY: if Android kills the process, the service comes back.
        return START_STICKY
    }

    override fun onDestroy() {
        CallNoteEngine.get(this).stopCallLogWatch()
        super.onDestroy()
        Log.i(TAG, "monitor service destroyed")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIF_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIF_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed: ${e.message}")
        }
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "CallNote monitoring",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = "Shown while CallNote watches for calls"
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }

        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val contentPi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopPi = PendingIntent.getBroadcast(
            this, NOTIF_ID,
            Intent(CallNoteEngine.ACTION_STOP_MONITORING)
                .setClass(this, NoteActionReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("CallNote is watching your calls")
            .setContentText("A note appears when a saved contact calls")
            .setContentIntent(contentPi)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(Notification.PRIORITY_LOW)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_action_done),
                    "Stop watching",
                    stopPi,
                ).build(),
            )
        return builder.build()
    }
}
