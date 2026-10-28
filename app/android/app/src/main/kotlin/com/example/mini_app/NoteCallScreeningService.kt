package com.example.mini_app

import android.telecom.Call
import android.telecom.CallScreeningService

/**
 * Sees incoming calls the moment the phone rings, and tells the app the
 * number. This is the official "Caller ID" service, so the app has to hold
 * the android.app.role.CALL_SCREENING role.
 */
class NoteCallScreeningService : CallScreeningService() {

    override fun onScreenCall(details: Call.Details) {
        try {
            val handle = details.handle?.toString()
            val digits = handle
                ?.removePrefix("tel:")
                ?.removePrefix("sip:")
                ?.filter { it.isDigit() }
                .orEmpty()
            if (digits.isNotEmpty()) {
                val now = System.currentTimeMillis()
                CallNoteEngine.recordScreened(digits, now)
                CallNoteEngine.emitCall(digits, true, "in:$digits:$now")
            }
        } catch (e: Exception) {
            // never crash the call screener
        } finally {
            // Let the call through untouched. If we did not answer, the
            // platform would hold the call for its timeout and then continue
            // anyway - answering properly keeps the call log and the incoming
            // call screen exactly as they would be without us.
            try {
                respondToCall(
                    details,
                    CallResponse.Builder()
                        .setDisallowCall(false)
                        .setRejectCall(false)
                        .setSilenceCall(false)
                        .setSkipCallLog(false)
                        .setSkipNotification(false)
                        .build(),
                )
            } catch (e: Exception) {
                // ignore
            }
        }
    }
}
