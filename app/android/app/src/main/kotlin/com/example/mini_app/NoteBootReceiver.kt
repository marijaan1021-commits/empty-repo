package com.example.mini_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Starts the monitoring service again after the phone reboots.
 *
 * Without this, a reboot silently stops every reminder until the user opens
 * the app by hand. BOOT_COMPLETED is sent once the device has been unlocked,
 * so the app's private files are readable by then.
 *
 * MY_PACKAGE_REPLACED does the same after an update of CallNote itself.
 */
class NoteBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        if (!CallNoteEngine.isMonitoring(context)) {
            Log.i("CallNote", "boot: monitoring is off, not starting")
            return
        }
        Log.i("CallNote", "boot: starting monitor service ($action)")
        CallNoteMonitorService.start(context)
    }
}
