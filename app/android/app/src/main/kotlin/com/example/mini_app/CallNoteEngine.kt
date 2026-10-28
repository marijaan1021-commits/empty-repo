package com.example.mini_app

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.Telephony
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * The native half of CallNote.
 *
 * Owns three things:
 *  - notifications (posting, and the "Done" / "Snooze" buttons)
 *  - the address book (listing contacts, and resolving a phone number to one)
 *  - call detection (CallScreeningService for incoming, the call log for outgoing)
 *
 * Everything else - "is there a note for this number?", "is the note still
 * active?" - is decided on the Dart side.
 */
class CallNoteEngine(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {

    companion object {
        const val CHANNEL = "com.example.mini_app/callnote"
        const val NOTIF_CHANNEL_ID = "call_notes"
        const val ACTION_DONE = "com.example.mini_app.action.DONE"
        const val ACTION_SNOOZE = "com.example.mini_app.action.SNOOZE"
        const val PREFS = "callnote"
        const val KEY_PENDING_ACTIONS = "pending_actions"
        const val REQ_PERMISSION = 4711
        const val REQ_ROLE = 4712
        private const val TAG = "CallNote"

        /** A call we saw ring, so the call log does not make us remind twice. */
        class Screened(val number: String, val at: Long)

        @Volatile
        var live: CallNoteEngine? = null

        /** Entry point for NoteActionReceiver. */
        fun dispatchAction(context: Context, id: String, action: String) {
            val e = live
            if (e != null) {
                e.queueAction(id, action)
                e.pushAction(id, action)
            } else {
                val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val arr = JSONArray(p.getString(KEY_PENDING_ACTIONS, "[]") ?: "[]")
                arr.put(JSONObject().put("id", id).put("action", action))
                p.edit().putString(KEY_PENDING_ACTIONS, arr.toString()).apply()
            }
        }

        /** Called by NoteCallScreeningService. */
        fun recordScreened(number: String, at: Long) {
            val e = live ?: return
            synchronized(e.screened) {
                e.screened.add(Screened(number, at))
                while (e.screened.size > 20) e.screened.removeAt(0)
            }
        }

        /** Called by NoteCallScreeningService and by the call log poller. */
        fun emitCall(number: String, incoming: Boolean, sessionId: String) {
            val e = live ?: return
            e.pushCall(number, incoming, sessionId)
        }
    }

    private val ctx: Context = activity.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val screened = ArrayList<Screened>()

    private var lastCallLogId = 0L
    private var poller: Runnable? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingRoleResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        live = this
        startCallLogPolling()
    }

    // ------------------------------------------------------------- method api

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "dataDir" -> result.success(ctx.filesDir.absolutePath)

            "hasPermission" -> {
                val p = call.argument<String>("permission") ?: ""
                result.success(hasPermission(p))
            }

            "requestPermission" -> {
                val p = call.argument<String>("permission") ?: ""
                if (hasPermission(p)) {
                    result.success(true)
                } else if (pendingPermissionResult != null) {
                    result.success(false)
                } else {
                    pendingPermissionResult = result
                    activity.requestPermissions(arrayOf(p), REQ_PERMISSION)
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

            "simulateCall" -> {
                val n = call.argument<String>("number") ?: ""
                val incoming = call.argument<Boolean>("incoming") ?: true
                val session = (if (incoming) "in:" else "out:") + n + ":" + System.currentTimeMillis()
                emitCall(n, incoming, session)
                result.success(true)
            }

            "drainActions" -> result.success(drainActions())

            "hasCallerIdRole" -> result.success(hasCallerIdRole())

            "requestCallerIdRole" -> requestCallerIdRole(result)

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ permissions

    private fun hasPermission(permission: String): Boolean {
        if (permission.isEmpty()) return false
        return ctx.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
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
        val rm = ctx.getSystemService(RoleManager::class.java) ?: return false
        return rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING) &&
            rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING)
    }

    private fun requestCallerIdRole(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(false)
            return
        }
        val rm = ctx.getSystemService(RoleManager::class.java)
        if (rm == null || !rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING)) {
            result.success(false)
            return
        }
        if (rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING)) {
            result.success(true)
            return
        }
        if (pendingRoleResult != null) {
            result.success(false)
            return
        }
        pendingRoleResult = result
        try {
            activity.startActivityForResult(
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
            ctx.contentResolver.query(
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
            ctx.contentResolver.query(
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
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
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
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val nid = notificationId(id)

        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        val contentPi = PendingIntent.getActivity(
            ctx, nid, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val donePi = PendingIntent.getBroadcast(
            ctx, nid * 2 + 1,
            Intent(ACTION_DONE).setClass(ctx, NoteActionReceiver::class.java).putExtra("id", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val snoozePi = PendingIntent.getBroadcast(
            ctx, nid * 2 + 2,
            Intent(ACTION_SNOOZE).setClass(ctx, NoteActionReceiver::class.java).putExtra("id", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, NOTIF_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(ctx)
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
                    Icon.createWithResource(ctx, R.drawable.ic_action_done),
                    "Stop permanently",
                    donePi,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(ctx, R.drawable.ic_action_snooze),
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
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.cancel(notificationId(id))
    }

    // ------------------------------------------------- notification actions

    private fun queueAction(id: String, action: String) {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = JSONArray(p.getString(KEY_PENDING_ACTIONS, "[]") ?: "[]")
        arr.put(JSONObject().put("id", id).put("action", action))
        p.edit().putString(KEY_PENDING_ACTIONS, arr.toString()).apply()
    }

    private fun drainActions(): List<Map<String, Any?>> {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
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
        main.post {
            try {
                channel.invokeMethod(
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
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
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

    fun pushCall(number: String, incoming: Boolean, sessionId: String) {
        main.post {
            try {
                channel.invokeMethod(
                    "onCall",
                    mapOf(
                        "number" to number,
                        "incoming" to incoming,
                        "sessionId" to sessionId,
                    ),
                )
            } catch (e: Exception) {
                Log.w(TAG, "pushCall failed: ${e.message}")
            }
        }
    }

    private fun startCallLogPolling() {
        if (poller != null) return
        // Start from the newest existing row so we never replay old calls.
        try {
            ctx.contentResolver.query(
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
        val r = object : Runnable {
            override fun run() {
                pollCallLog()
                main.postDelayed(this, 2000)
            }
        }
        poller = r
        main.postDelayed(r, 2000)
    }

    private fun pollCallLog() {
        if (!hasPermission(Manifest.permission.READ_CALL_LOG)) return
        // The permission may only have been granted after the emulator was
        // already running. Seed the baseline the first time we are allowed to
        // read the log, otherwise every historical call would be replayed as
        // if it had just happened.
        if (lastCallLogId == 0L) {
            try {
                ctx.contentResolver.query(
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
            return
        }
        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.NUMBER,
            CallLog.Calls.TYPE,
            CallLog.Calls.DATE,
        )
        try {
            ctx.contentResolver.query(
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
                    emitCall(number, incoming, session)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "pollCallLog failed: ${e.message}")
        }
    }

    /** True if we already announced this call through CallScreeningService. */
    private fun screenedRecently(number: String, at: Long): Boolean {
        synchronized(screened) {
            for (s in screened) {
                if (s.number == number && kotlin.math.abs(at - s.at) < 120000L) return true
            }
        }
        return false
    }
}
