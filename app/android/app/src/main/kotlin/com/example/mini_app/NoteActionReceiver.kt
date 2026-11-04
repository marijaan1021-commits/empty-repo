package com.example.mini_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles the buttons on the notifications:
 *  - "Stop permanently" on a reminder
 *  - "Snooze" on a reminder
 *  - "Stop watching" on the monitoring notification
 */
class NoteActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = when (intent.action) {
            CallNoteEngine.ACTION_DONE -> "done"
            CallNoteEngine.ACTION_SNOOZE -> "snooze"
            CallNoteEngine.ACTION_STOP_MONITORING -> "stop_monitoring"
            else -> return
        }
        if (action == "stop_monitoring") {
            // No note id here - this one turns the monitoring off.
            CallNoteEngine.setMonitoring(context, false)
            CallNoteMonitorService.stop(context)
            return
        }
        val id = intent.getStringExtra("id") ?: return
        CallNoteEngine.dispatchAction(context, id, action)
    }
}
