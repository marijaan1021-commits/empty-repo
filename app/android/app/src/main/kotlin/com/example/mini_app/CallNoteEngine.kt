package com.example.mini_app

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.role.RoleManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * The native half of CallNote.
 *
 * Owns four things:
 *  - notifications (posting, and the "Stop permanently" / "Snooze" buttons)
 *  - the address book (listing contacts, and resolving a phone number to one)
 *  - call detection (CallScreeningService for incoming, the call log for outgoing)
 *  - the note lookup that decides whether a call deserves a reminder
 *
 * The engine is a process-wide singleton, so it keeps working when the Flutter
 * engine is gone - the app was swiped away, or the phone just rebooted. The
 * Dart side is only a UI: the reminder is posted from here, so it does not
 * matter whether any Dart code is running.
 */
class CallNoteEngine private constructor(
    private val appCtx: Context,
) {

    companion object {
        const val CHANNEL = "com.example.mini_app/callnote"

        /** The call states the phone reports. */
        const val CALL_STATE_IDLE = 0
        const val CALL_STATE_RINGING = 1
        const val CALL_STATE_OFFHOOK = 2

        const val NOTIF_CHANNEL_ID = "call_notes"
        const val ACTION_DONE = "com.example.mini_app.action.DONE"
        const val ACTION_SNOOZE = "com.example.mini_app.action.SNOOZE"
        const val ACTION_STOP_MONITORING = "com.example.mini_app.action.STOP_MONITORING"
        const val PREFS = "callnote"
        const val KEY_PENDING_ACTIONS = "pending_actions"
        const val KEY_MONITORING = "monitoring_enabled"
        const val KEY_SCREENED = "last_screened"
        const val REQ_PERMISSION = 4711
        const val REQ_ROLE = 4712
        private const val TAG = "CallNote"

        /** A call we saw ring, so the call log does not make us remind twice. */
        class Screened(val number: String, val at: Long)

        /** A call we have already announced. */
        class AnnouncedCall(val number: String, val at: Long, val incoming: Boolean)

        @Volatile
        private var instance: CallNoteEngine? = null

        /** The engine of this process, created on first use. */
        fun get(ctx: Context): CallNoteEngine =
            instance ?: synchronized(this) {
                instance ?: CallNoteEngine(ctx.applicationContext).also { instance = it }
            }

        /** Wires the engine to the Flutter engine of an activity. */
        fun attach(activity: Activity, messenger: BinaryMessenger): CallNoteEngine {
            val e = get(activity)
            e.activity = activity
            val channel = MethodChannel(messenger, CHANNEL)
            e.channel = channel
            channel.setMethodCallHandler { call, result -> e.handle(call, result) }
            return e
        }

        fun isMonitoring(ctx: Context): Boolean {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return p.getBoolean(KEY_MONITORING, true)
        }

        fun setMonitoring(ctx: Context, on: Boolean) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_MONITORING, on).apply()
        }

        /**
         * Entry point for NoteActionReceiver.
         *
         * The change is written to the note file right away, even when the app
         * is not running - "Stop permanently" has to work from the notification
         * alone. The Dart side is told as well, so the UI stays in sync.
         */
        fun dispatchAction(context: Context, id: String, action: String) {
            val e = get(context)
            when (action) {
                "done" -> NoteStore.setEnabled(context, id, false)
                "stop_monitoring" -> {
                    setMonitoring(context, false)
                    CallNoteMonitorService.stop(context)
                    e.pushMonitoring(false)
                }
            }
            e.queueAction(id, action)
            e.pushAction(id, action)
        }
    }

    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val screened = ArrayList<Screened>()

    private var lastCallLogId = 0L
    private var observer: ContentObserver? = null
    private var watcherThread: HandlerThread? = null
    private var pollRunnable: Runnable? = null
    private var fastPollRunnable: Runnable? = null
    private var fastPollUntil = 0L
    private var callStateWatcher: CallStateWatcher? = null

    /** True while the phone says a call is running or ringing. */
    @Volatile
    private var callActive = false

    /** The last call log row the fast poll looked at, to keep the log quiet. */
    @Volatile
    private var lastRecentCallId = 0L

    /** Whether the reminder for the current call has already gone out. */
    @Volatile
    private var currentCallAnnounced = false

    /** The calls we have already announced, so none of them is shown twice. */
    private val announcedCalls = ArrayList<AnnouncedCall>()
    private val seenSessions = LinkedHashSet<String>()

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingRoleResult: MethodChannel.Result? = null

    // ------------------------------------------------------------- method api

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "dataDir" -> result.success(appCtx.filesDir.absolutePath)

            "hasPermission" -> {
                val p = call.argument<String>("permission") ?: ""
                result.success(hasPermission(p))
            }

            "requestPermission" -> {
                val p = call.argument<String>("permission") ?: ""
                val act = activity
                if (hasPermission(p)) {
                    result.success(true)
                } else if (act == null || pendingPermissionResult != null) {
                    result.success(false)
                } else {
                    pendingPermissionResult = result
                    try {
                        act.requestPermissions(arrayOf(p), REQ_PERMISSION)
                    } catch (e: Exception) {
                        pendingPermissionResult = null
                        result.success(false)
                    }
                }
            }

            "listContacts" -> {
                val q = call.argument<String>("query") ?: ""
                result.success(listContacts(q))
            }

            "lookupContact" -> {
                val n = call.argument<String>("number") ?: ""
                result.success(lookupContact(n))
            }

            "notify" -> {
                val id = call.argument<String>("id") ?: "note"
                val title = call.argument<String>("title") ?: ""
                val body = call.argument<String>("body") ?: ""
                postNotification(id, title, body)
                result.success(true)
            }

            "cancelNotification" -> {
                val id = call.argument<String>("id") ?: ""
                cancelNotification(id)
                result.success(true)
            }

            "drainActions" -> result.success(drainActions())

            "hasCallerIdRole" -> result.success(hasCallerIdRole())

            "requestCallerIdRole" -> requestCallerIdRole(result)

            "isMonitoring" -> result.success(isMonitoring(appCtx))

            "setMonitoring" -> {
                val on = call.argument<Boolean>("on") ?: false
                setMonitoring(appCtx, on)
                if (on) {
                    CallNoteMonitorService.start(appCtx)
                } else {
                    CallNoteMonitorService.stop(appCtx)
                }
                pushMonitoring(on)
                result.success(true)
            }

            // Starts the watcher if it should be on. A service that was
            // started before POST_NOTIFICATIONS was granted never shows its
            // notification, so the Dart side calls this once the user has
            // answered the permission prompt.
            "ensureMonitorRunning" -> {
                CallNoteMonitorService.start(appCtx)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ permissions

    private fun hasPermission(permission: String): Boolean {
        if (permission.isEmpty()) return false
        return appCtx.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_PERMISSION) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    private fun hasCallerIdRole(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val rm = appCtx.getSystemService(RoleManager::class.java) ?: return false
        return rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING) &&
            rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING)
    }

    private fun requestCallerIdRole(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(false)
            return
        }
        val rm = appCtx.getSystemService(RoleManager::class.java)
        if (rm == null || !rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING)) {
            result.success(false)
            return
        }
        if (rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING)) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null || pendingRoleResult != null) {
            result.success(false)
            return
        }
        pendingRoleResult = result
        try {
            act.startActivityForResult(
                rm.createRequestRoleIntent(RoleManager.ROLE_CALL_SCREENING),
                REQ_ROLE,
            )
        } catch (e: Exception) {
            pendingRoleResult = null
            result.success(false)
        }
    }

    fun onRoleResult(granted: Boolean) {
        pendingRoleResult?.success(granted)
        pendingRoleResult = null
    }

    // -------------------------------------------------------------- contacts

    private fun listContacts(query: String): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) return out
        val q = query.trim()
        val projection = arrayOf(
            Phone.CONTACT_ID,
            Phone.DISPLAY_NAME,
            Phone.NUMBER,
        )
        var selection: String? = null
        var args: Array<String>? = null
        if (q.isNotEmpty()) {
            selection = "(${Phone.DISPLAY_NAME} LIKE ? OR ${Phone.NUMBER} LIKE ?)"
            args = arrayOf("%$q%", "%$q%")
        }
        val grouped = LinkedHashMap<String, MutableMap<String, Any?>>()
        try {
            appCtx.contentResolver.query(
                Phone.CONTENT_URI, projection, selection, args, null,
            )?.use { c ->
                val idIdx = c.getColumnIndex(Phone.CONTACT_ID)
                val nameIdx = c.getColumnIndex(Phone.DISPLAY_NAME)
                val numIdx = c.getColumnIndex(Phone.NUMBER)
                var seen = 0
                while (c.moveToNext() && seen < 500) {
                    seen++
                    val id = c.getString(idIdx) ?: continue
                    val number = c.getString(numIdx)?.trim().orEmpty()
                    if (number.isEmpty()) continue
                    val name = c.getString(nameIdx)?.trim().orEmpty()
                    val row = grouped.getOrPut(id) {
                        mutableMapOf<String, Any?>(
                            "contactId" to id,
                            "name" to name,
                            "numbers" to ArrayList<String>(),
                        )
                    }
                    if (row["name"].toString().isEmpty() && name.isNotEmpty()) {
                        row["name"] = name
                    }
                    @Suppress("UNCHECKED_CAST")
                    val nums = row["numbers"] as ArrayList<String>
                    if (!nums.contains(number)) nums.add(number)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "listContacts failed: ${e.message}")
        }
        for (row in grouped.values) out.add(row)
        return out
    }

    private fun lookupContact(number: String): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val digits = number.filter { it.isDigit() }
        if (digits.isEmpty()) return out
        try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(digits),
            )
            appCtx.contentResolver.query(
                uri,
                arrayOf(
                    ContactsContract.PhoneLookup._ID,
                    ContactsContract.PhoneLookup.DISPLAY_NAME,
                ),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    out.add(
                        mapOf(
                            "contactId" to (c.getString(0) ?: ""),
                            "name" to (c.getString(1) ?: ""),
                        ),
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "lookupContact failed: ${e.message}")
        }
        return out
    }

    // ---------------------------------------------------------- notifications

    private fun notificationId(id: String): Int = (id.hashCode() and 0x7fffffff)

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = appCtx.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            NOTIF_CHANNEL_ID,
            "Call reminders",
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = "Shows what you want to say when a contact calls"
        channel.enableVibration(true)
        nm.createNotificationChannel(channel)
    }

    private fun postNotification(id: String, title: String, body: String) {
        ensureChannel()
        val nm = appCtx.getSystemService(NotificationManager::class.java) ?: return
        val nid = notificationId(id)

        val launch = appCtx.packageManager.getLaunchIntentForPackage(appCtx.packageName)
        val contentPi = PendingIntent.getActivity(
            appCtx, nid, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val donePi = PendingIntent.getBroadcast(
            appCtx, nid * 2 + 1,
            Intent(ACTION_DONE).setClass(appCtx, NoteActionReceiver::class.java).putExtra("id", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val snoozePi = PendingIntent.getBroadcast(
            appCtx, nid * 2 + 2,
            Intent(ACTION_SNOOZE).setClass(appCtx, NoteActionReceiver::class.java).putExtra("id", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(appCtx, NOTIF_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(appCtx)
        }

        builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(contentPi)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPriority(Notification.PRIORITY_HIGH)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(appCtx, R.drawable.ic_action_done),
                    "Stop permanently",
                    donePi,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(appCtx, R.drawable.ic_action_snooze),
                    "Snooze",
                    snoozePi,
                ).build(),
            )

        try {
            nm.notify(nid, builder.build())
        } catch (e: Exception) {
            Log.w(TAG, "notify failed: ${e.message}")
        }
    }

    private fun cancelNotification(id: String) {
        val nm = appCtx.getSystemService(NotificationManager::class.java) ?: return
        nm.cancel(notificationId(id))
    }

    // ------------------------------------------------- notification actions

    private fun queueAction(id: String, action: String) {
        val p = appCtx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = JSONArray(p.getString(KEY_PENDING_ACTIONS, "[]") ?: "[]")
        arr.put(JSONObject().put("id", id).put("action", action))
        p.edit().putString(KEY_PENDING_ACTIONS, arr.toString()).apply()
    }

    private fun drainActions(): List<Map<String, Any?>> {
        val p = appCtx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = p.getString(KEY_PENDING_ACTIONS, "[]") ?: "[]"
        p.edit().putString(KEY_PENDING_ACTIONS, "[]").apply()
        val out = ArrayList<Map<String, Any?>>()
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                out.add(
                    mapOf(
                        "id" to o.optString("id"),
                        "action" to o.optString("action"),
                    ),
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "drainActions failed: ${e.message}")
        }
        return out
    }

    fun pushAction(id: String, action: String) {
        val ch = channel ?: return // no Flutter engine: the action stays queued
        main.post {
            try {
                ch.invokeMethod(
                    "onNotificationAction",
                    mapOf("id" to id, "action" to action),
                    object : MethodChannel.Result {
                        // Dart got it - drop it from the offline queue so it is
                        // not applied a second time on the next app start.
                        override fun success(result: Any?) = removeQueued(id, action)

                        override fun error(code: String, message: String?, details: Any?) {}

                        override fun notImplemented() {}
                    },
                )
            } catch (e: Exception) {
                Log.w(TAG, "pushAction failed: ${e.message}")
            }
        }
    }

    private fun removeQueued(id: String, action: String) {
        val p = appCtx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = JSONArray(p.getString(KEY_PENDING_ACTIONS, "[]") ?: "[]")
        val kept = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val same = o.optString("id") == id && o.optString("action") == action
            if (!same) kept.put(o)
        }
        p.edit().putString(KEY_PENDING_ACTIONS, kept.toString()).apply()
    }

    // ------------------------------------------------------------ call events

    /**
     * A call happened. Decides here - not in Dart - whether it deserves a
     * reminder, and posts it. Works with no Flutter engine running.
     *
     * [at] is when the call started. It is what tells two detections of the
     * same call apart from two different calls to the same number.
     */
    fun onCallDetected(number: String, incoming: Boolean, sessionId: String, at: Long = System.currentTimeMillis()) {
        if (number.isEmpty()) return
        if (!markSession(sessionId)) return
        if (alreadyAnnounced(number, at)) return
        rememberAnnounced(number, at, incoming)
        val reminder = NoteStore.findFor(appCtx, number)
        var posted = false
        if (reminder != null && reminder.willRemind) {
            val title = if (reminder.name.isNotEmpty()) reminder.name else number
            postNotification(reminder.id, title, reminder.text)
            posted = true
            Log.i(TAG, "reminder posted for $number (${reminder.name})")
        }
        pushCall(number, incoming, sessionId, posted)
    }

    /**
     * Has this call already been announced?
     *
     * The same call reaches us more than once: the phone state says a call
     * started, the call screening service says who it is, and the call log
     * row turns up later. All of them describe the same call, so the note
     * must only be shown once.
     *
     * What makes two detections the same call is the time it started - the
     * phone state uses the moment it saw the call, the call log row the date
     * the call started. Two calls to the same person a minute apart are two
     * different calls and both get a reminder.
     */
    private fun alreadyAnnounced(number: String, at: Long): Boolean {
        synchronized(announcedCalls) {
            for (a in announcedCalls) {
                if (a.number == number && kotlin.math.abs(a.at - at) <= SAME_CALL_WINDOW_MS) return true
            }
        }
        return false
    }

    private fun rememberAnnounced(number: String, at: Long, incoming: Boolean) {
        synchronized(announcedCalls) {
            announcedCalls.add(AnnouncedCall(number, at, incoming))
            while (announcedCalls.size > 50) announcedCalls.removeAt(0)
        }
    }

    /** Called by NoteCallScreeningService the moment a call rings. */
    fun onScreenedCall(number: String, at: Long) {
        synchronized(screened) {
            screened.add(Screened(number, at))
            while (screened.size > 20) screened.removeAt(0)
        }
        // Remember it on disk too, so a process restart cannot make us remind
        // about the same call a second time when its call log row shows up.
        appCtx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_SCREENED, "$number|$at").apply()
        onCallDetected(number, true, "in:$number:$at", at)
    }

    private fun markSession(sessionId: String): Boolean {
        if (sessionId.isEmpty()) return true
        synchronized(seenSessions) {
            if (seenSessions.contains(sessionId)) return false
            seenSessions.add(sessionId)
            while (seenSessions.size > 50) {
                val it = seenSessions.iterator()
                it.next()
                it.remove()
            }
        }
        return true
    }

    /** Tells the app that watching was turned on or off, so the UI can follow. */
    private fun pushMonitoring(on: Boolean) {
        val ch = channel ?: return
        main.post {
            try {
                ch.invokeMethod("onMonitoring", mapOf("on" to on))
            } catch (e: Exception) {
                Log.w(TAG, "pushMonitoring failed: ${e.message}")
            }
        }
    }

    private fun pushCall(number: String, incoming: Boolean, sessionId: String, posted: Boolean) {        val ch = channel ?: return
        main.post {
            try {
                ch.invokeMethod(
                    "onCall",
                    mapOf(
                        "number" to number,
                        "incoming" to incoming,
                        "sessionId" to sessionId,
                        "posted" to posted,
                    ),
                )
            } catch (e: Exception) {
                Log.w(TAG, "pushCall failed: ${e.message}")
            }
        }
    }

    // ------------------------------------------------------- call log watcher

    /**
     * Watches the call log with a ContentObserver.
     *
     * This replaces a poll every two seconds: the observer wakes us the moment
     * a row is written, and a slow poll stays as a safety net for the rare
     * case where the provider does not notify.
     */
    fun startCallLogWatch() {
        synchronized(this) {
            if (observer != null) return
            seedLastCallLogId()

            val thread = HandlerThread("callnote-log").also { it.start() }
            watcherThread = thread
            val handler = Handler(thread.looper)

            val obs = object : ContentObserver(handler) {
                override fun onChange(selfChange: Boolean) = pollCallLog()
                override fun onChange(selfChange: Boolean, uri: Uri?) = pollCallLog()
            }
            try {
                appCtx.contentResolver.registerContentObserver(
                    CallLog.Calls.CONTENT_URI, true, obs,
                )
                observer = obs
            } catch (e: Exception) {
                Log.w(TAG, "observer registration failed: ${e.message}")
            }

            val r = object : Runnable {
                override fun run() {
                    pollCallLog()
                    handler.postDelayed(this, BACKSTOP_POLL_MS)
                }
            }
            pollRunnable = r
            handler.postDelayed(r, BACKSTOP_POLL_MS)
            Log.i(TAG, "call log watcher started")

            // The phone state tells us when a call starts; the call log tells
            // us who it is to. Watch both.
            ensureCallStateWatch()
        }
    }

    /**
     * Starts the phone state watcher if it is not running yet.
     *
     * It is separate from the call log watcher because it needs a permission
     * that can be granted after the service is already up.
     */
    fun ensureCallStateWatch() {
        synchronized(this) {
            if (callStateWatcher?.isRunning == true) return
            // The previous attempt could not register because the permission
            // was not granted yet - try again now.
            callStateWatcher?.stop()
            callStateWatcher = CallStateWatcher(appCtx, this).also { it.start() }
        }
    }

    /**
     * A call just started (or started ringing).
     *
     * The number is only in the call log, and the call log is written by the
     * phone at a moment of its own choosing. Now that we know a call is
     * happening we look for the row every 250 ms instead of waiting for the
     * observer to wake us up - so the reminder arrives while the call is
     * still running, not after it.
     */
    /**
     * The phone told us about a call.
     *
     * This is the fast path: the phone says a call started (or started
     * ringing) at the very moment it happens, and it hands over the phone
     * number. So the reminder can go out right away - no waiting for the
     * call log, and no caller ID role needed.
     *
     * One call produces several of these:
     *
     *   RINGING              a call is coming in
     *   RINGING, OFFHOOK     it came in and was answered
     *   OFFHOOK              a call is going out
     *   IDLE                 the call is over
     *
     * A ringing call is always a new call. An off-hook state is a new call
     * too, unless the call was already ringing - then it is the same call
     * being answered, and the reminder was already sent.
     */
    fun onCallStateChanged(state: Int, number: String?) {
        when (state) {
            CALL_STATE_RINGING -> {
                callActive = true
                // A ringing call is a new call. Two listeners report it - one
                // with the number, one without - and the one without arrives
                // first, so the reminder is only sent for the call that has a
                // number, and only once.
                if (!number.isNullOrEmpty() || !currentCallAnnounced) {
                    currentCallAnnounced = false
                }
                announce(number, incoming = true)
                startFastPoll()
            }
            CALL_STATE_OFFHOOK -> {
                callActive = true
                // The call was already announced when it started (it rang, or
                // it was dialled), so there is nothing to do. The two
                // listeners report the same change a few milliseconds apart.
                if (!currentCallAnnounced) {
                    announce(number, incoming = false)
                }
                startFastPoll()
            }
            CALL_STATE_IDLE -> {
                callActive = false
                currentCallAnnounced = false
                stopFastPoll()
            }
        }
    }

    /**
     * Show the reminder for [number], unless this very call was already
     * announced by another source (the call screening service, the call log).
     */
    private fun announce(number: String?, incoming: Boolean) {
        if (number.isNullOrEmpty()) return
        val now = System.currentTimeMillis()
        if (alreadyAnnounced(number, now)) {
            currentCallAnnounced = true
            return
        }
        currentCallAnnounced = true
        Log.i(TAG, "phone state gave the number: $number (incoming=$incoming)")
        onCallDetected(number, incoming, "state:$number:$now")
    }

    /** Poll the call log quickly for a short while, to catch the row. */
    private fun startFastPoll() {
        synchronized(this) {
            val handler = watcherThread?.looper?.let { Handler(it) } ?: return
            fastPollUntil = System.currentTimeMillis() + FAST_POLL_WINDOW_MS
            fastPollRunnable?.let { handler.removeCallbacks(it) }
            val r = object : Runnable {
                override fun run() {
                    pollCallLog()
                    if (System.currentTimeMillis() < fastPollUntil) {
                        handler.postDelayed(this, FAST_POLL_MS)
                    } else {
                        fastPollRunnable = null
                    }
                }
            }
            fastPollRunnable = r
            handler.post(r)
        }
    }

    private fun stopFastPoll() {
        synchronized(this) {
            fastPollRunnable?.let { watcherThread?.looper?.let { l -> Handler(l).removeCallbacks(it) } }
            fastPollRunnable = null
            fastPollUntil = 0L
        }
    }

    fun stopCallLogWatch() {
        synchronized(this) {
            pollRunnable?.let { watcherThread?.looper?.let { l -> Handler(l).removeCallbacks(it) } }
            pollRunnable = null
            fastPollRunnable?.let { watcherThread?.looper?.let { l -> Handler(l).removeCallbacks(it) } }
            fastPollRunnable = null
            fastPollUntil = 0L
            callStateWatcher?.stop()
            callStateWatcher = null
            observer?.let {
                try {
                    appCtx.contentResolver.unregisterContentObserver(it)
                } catch (e: Exception) {
                    // already gone
                }
            }
            observer = null
            watcherThread?.quitSafely()
            watcherThread = null
        }
    }

    private fun seedLastCallLogId() {
        try {
            appCtx.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls._ID),
                null, null,
                "${CallLog.Calls._ID} DESC",
            )?.use { c ->
                if (c.moveToFirst()) lastCallLogId = c.getLong(0)
            }
        } catch (e: Exception) {
            Log.w(TAG, "call log seed failed: ${e.message}")
        }
    }

    /**
     * Looks for calls in the log and announces them.
     *
     * While a call is running the log is polled by date, not by row id: the
     * row for the current call is written when the call starts, but the
     * number can still be empty for a moment afterwards, and a row that was
     * skipped for that reason would never be looked at again.
     */
    private fun pollCallLog() {
        if (!isMonitoring(appCtx)) return
        if (!hasPermission(Manifest.permission.READ_CALL_LOG)) return
        // The permission may only have been granted after the emulator was
        // already running. Seed the baseline the first time we are allowed to
        // read the log, otherwise every historical call would be replayed as
        // if it had just happened.
        if (lastCallLogId == 0L) {
            seedLastCallLogId()
            return
        }
        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.TYPE,
            CallLog.Calls.DATE,
        )
        try {
            appCtx.contentResolver.query(
                CallLog.Calls.CONTENT_URI, projection,
                "${CallLog.Calls._ID} > ?", arrayOf(lastCallLogId.toString()),
                "${CallLog.Calls._ID} ASC",
            )?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    val number = c.getString(1)?.trim().orEmpty()
                    val type = c.getInt(2)
                    val date = c.getLong(3)
                    if (id > lastCallLogId) lastCallLogId = id
                    if (number.isEmpty()) continue
                    val incoming = type == CallLog.Calls.INCOMING_TYPE ||
                        type == CallLog.Calls.MISSED_TYPE
                    if (incoming && screenedRecently(number, date)) continue
                    val session = if (incoming) "in:$number:$date" else "out:$id"
                    Log.i(TAG, "call log row $id $number incoming=$incoming")
                    onCallDetected(number, incoming, session, date)
                }
            }
            if (callActive) pollRecentCalls()
        } catch (e: Exception) {
            Log.w(TAG, "pollCallLog failed: ${e.message}")
        }
    }

    /**
     * The calls of the last few minutes, by date rather than by row id.
     *
     * The row of the call that is running right now is written when the call
     * starts, but the phone number is sometimes only filled in a moment
     * later. Looking the rows up again by date picks that up.
     */
    private fun pollRecentCalls() {
        if (!hasPermission(Manifest.permission.READ_CALL_LOG)) return
        val since = System.currentTimeMillis() - RECENT_CALL_WINDOW_MS
        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.TYPE,
            CallLog.Calls.DATE,
        )
        try {
            appCtx.contentResolver.query(
                CallLog.Calls.CONTENT_URI, projection,
                "${CallLog.Calls.DATE} > ?", arrayOf(since.toString()),
                "${CallLog.Calls.DATE} DESC",
            )?.use { c ->
                var newest = true
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    val number = c.getString(1)?.trim().orEmpty()
                    val type = c.getInt(2)
                    val date = c.getLong(3)
                    if (number.isEmpty()) continue
                    val incoming = type == CallLog.Calls.INCOMING_TYPE ||
                        type == CallLog.Calls.MISSED_TYPE
                    if (incoming && screenedRecently(number, date)) continue
                    val session = "call:$date"
                    // The rows come back newest first - log that one only, so
                    // the fast poll does not fill the log with the same line.
                    if (newest) {
                        newest = false
                        if (id != lastRecentCallId) {
                            lastRecentCallId = id
                            Log.i(TAG, "recent call $id $number incoming=$incoming date=$date")
                        }
                    }
                    onCallDetected(number, incoming, session, date)
                    if (id > lastCallLogId) lastCallLogId = id
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "pollRecentCalls failed: ${e.message}")
        }
    }

    /** True if we already announced this call through CallScreeningService. */
    private fun screenedRecently(number: String, at: Long): Boolean {
        synchronized(screened) {
            for (s in screened) {
                if (s.number == number && kotlin.math.abs(at - s.at) < 120000L) return true
            }
        }
        // The process may have been restarted between the ring and the call
        // log row, so the last screened call is also kept on disk.
        val raw = appCtx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_SCREENED, "") ?: ""
        val parts = raw.split("|")
        if (parts.size == 2) {
            val n = parts[0]
            val t = parts[1].toLongOrNull() ?: 0L
            if (n == number && kotlin.math.abs(at - t) < 120000L) return true
        }
        return false
    }
}

private const val BACKSTOP_POLL_MS = 15000L

// How often the call log is checked while a call is running, and for how long.
// The phone state says a call is happening; this finds the row that says who
// it is, as soon as the phone writes it.
private const val FAST_POLL_MS = 250L
private const val FAST_POLL_WINDOW_MS = 30000L

// How far back the call log is looked at while a call is running. The row
// for the call that is running is written when the call starts, so a window
// of a few minutes is plenty.
private const val RECENT_CALL_WINDOW_MS = 300000L

// Two detections describe the same call when they are this close together.
// The phone state and the call log row of one call carry the same moment
// (when the call started), so a few seconds is plenty - and two calls to
// the same person a moment later are two calls, not one.
private const val SAME_CALL_WINDOW_MS = 5000L
