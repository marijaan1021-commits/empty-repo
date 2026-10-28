package com.example.mini_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Handles the "Done" and "Snooze" buttons on the reminder notification. */
class NoteActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val action = when (intent.action) {
            CallNoteEngine.ACTION_DONE -> "done"
            CallNoteEngine.ACTION_SNOOZE -> "snooze"
            else -> return
        }
        CallNoteEngine.dispatchAction(context, id, action)
    }
}
