package com.example.mini_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Tells the engine the moment a call starts, or the moment one starts ringing.
 *
 * The call log is the wrong clock. When the OEM writes the row is up to the
 * device, and on some phones that is only when the call is over. Waiting for
 * the row therefore makes the reminder arrive late.
 *
 * The phone state is the real thing and behaves the same everywhere:
 *
 *   RINGING  - a call is coming in
 *   OFFHOOK  - a call is going out (or an incoming one was answered)
 *   IDLE     - no call
 *
 * Two callbacks are registered:
 *
 *  - [PhoneStateListener] - deprecated, but it is the only one that still
 *    carries the phone number, which is what an incoming call needs.
 *  - [TelephonyCallback.CallStateListener] - the modern replacement, used as
 *    a second source for the timing.
 *
 * The number is only in the call log for outgoing calls; for incoming calls
 * it comes from the phone state, or from the call screening service when the
 * user has given this app the caller ID role.
 */
class CallStateWatcher(
    private val ctx: Context,
    private val engine: CallNoteEngine,
) {

    companion object {
        private const val TAG = "CallNote"
    }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var telephonyCallback: Any? = null
    private var phoneStateListener: PhoneStateListener? = null
    private var starting = false
    private var stopped = false

    /**
     * True when the callback is registered and the phone is reporting states.
     *
     * It is true from the moment [start] is called, even though the
     * registration itself happens a moment later on the watcher thread -
     * otherwise a second call to [start] would register a second listener and
     * then quit the thread of the first one, which loses the callbacks.
     */
    val isRunning: Boolean
        get() = starting || telephonyCallback != null || phoneStateListener != null

    fun start() {
        if (ctx.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.i(TAG, "call state watcher not started: READ_PHONE_STATE is not granted")
            return
        }
        if (isRunning || starting) return
        starting = true
        stopped = false

        val t = HandlerThread("callnote-callstate").also { it.start() }
        thread = t
        handler = Handler(t.looper)

        val tm = ctx.getSystemService(TelephonyManager::class.java)
        if (tm == null) {
            Log.w(TAG, "call state watcher: no telephony service")
            starting = false
            return
        }

        // Both listeners are registered on this thread, not on the app's main
        // thread. A listener hands its callbacks to the thread that created
        // it, and the main thread here is busy rendering the Flutter UI - a
        // callback posted there can sit in the queue for a long time.
        handler?.post {
            if (stopped) {
                starting = false
                return@post
            }
            try {
                // The deprecated listener: it is the only one that still hands
                // over the phone number, which is what an incoming call needs.
                val listener = object : PhoneStateListener() {
                    @Suppress("DEPRECATION")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        onState(state, phoneNumber)
                    }
                }
                tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
                phoneStateListener = listener
                Log.i(TAG, "call state watcher started (PhoneStateListener)")
            } catch (e: Exception) {
                Log.w(TAG, "PhoneStateListener failed: ${e.message}")
            }

            // The modern one, as a second source for the timing.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                        override fun onCallStateChanged(state: Int) {
                            onState(state, null)
                        }
                    }
                    val executor = java.util.concurrent.Executor { r ->
                        val h = handler
                        if (h != null) h.post(r) else r.run()
                    }
                    tm.registerTelephonyCallback(executor, cb)
                    telephonyCallback = cb
                    Log.i(TAG, "call state watcher started (TelephonyCallback)")
                } catch (e: Exception) {
                    Log.w(TAG, "TelephonyCallback failed: ${e.message}")
                }
            }
            starting = false
        }
    }

    fun stop() {
        stopped = true
        starting = false
        try {
            val tm = ctx.getSystemService(TelephonyManager::class.java)
            val cb = telephonyCallback
            if (tm != null && cb is TelephonyCallback) {
                tm.unregisterTelephonyCallback(cb)
            }
            val l = phoneStateListener
            if (tm != null && l != null) {
                @Suppress("DEPRECATION")
                tm.listen(l, PhoneStateListener.LISTEN_NONE)
            }
        } catch (e: Exception) {
            Log.w(TAG, "call state watcher failed to unregister: ${e.message}")
        }
        telephonyCallback = null
        phoneStateListener = null
        thread?.quitSafely()
        thread = null
        handler = null
    }

    private fun onState(state: Int, number: String?) {
        when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                Log.i(TAG, "phone state: RINGING number=${number ?: "<none>"}")
                engine.onCallStateChanged(CallNoteEngine.CALL_STATE_RINGING, number)
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                Log.i(TAG, "phone state: OFFHOOK number=${number ?: "<none>"}")
                engine.onCallStateChanged(CallNoteEngine.CALL_STATE_OFFHOOK, number)
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                Log.i(TAG, "phone state: IDLE")
                engine.onCallStateChanged(CallNoteEngine.CALL_STATE_IDLE, number)
            }
            else -> Log.i(TAG, "phone state: $state")
        }
    }
}
