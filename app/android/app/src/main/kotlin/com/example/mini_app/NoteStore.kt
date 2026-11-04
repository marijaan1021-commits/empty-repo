package com.example.mini_app

import android.content.Context
import android.net.Uri
import android.provider.ContactsContract
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Reads (and writes) the note list from the native side.
 *
 * The Dart side owns the file - it is written by [com.example.mini_app.MainActivity]'s
 * Flutter engine. This is the second reader of the same JSON, so that the
 * reminder can still be posted when the app is closed, swiped away or has just
 * come back from a reboot, long before any Dart code runs.
 *
 * The file format is a JSON array of objects:
 *   { "id", "contactId", "name", "numbers": [...], "text", "enabled", "updatedAt" }
 */
object NoteStore {

    const val FILE_NAME = "callnote.json"

    /** One saved note, as far as the native side cares. */
    class Reminder(
        val id: String,
        val name: String,
        val text: String,
        val enabled: Boolean,
        val contactId: String,
        val numbers: List<String>,
    ) {
        /** A note only fires when it is enabled AND actually says something. */
        val willRemind: Boolean
            get() = enabled && text.isNotBlank()
    }

    fun file(ctx: Context): File = File(ctx.filesDir, FILE_NAME)

    fun load(ctx: Context): List<Reminder> {
        val f = file(ctx)
        if (!f.exists()) return emptyList()
        return try {
            val raw = f.readText()
            if (raw.isBlank()) return emptyList()
            val arr = JSONArray(raw)
            val out = ArrayList<Reminder>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val nums = ArrayList<String>()
                val arrNums = o.optJSONArray("numbers")
                if (arrNums != null) {
                    for (n in 0 until arrNums.length()) {
                        val s = arrNums.optString(n).trim()
                        if (s.isNotEmpty()) nums.add(s)
                    }
                }
                out.add(
                    Reminder(
                        id = o.optString("id"),
                        name = o.optString("name"),
                        text = o.optString("text"),
                        enabled = o.optBoolean("enabled", true),
                        contactId = o.optString("contactId"),
                        numbers = nums,
                    ),
                )
            }
            out
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * The note that belongs to [number], if any.
     *
     * Number matching is the same rule the Dart side uses, so both agree on
     * which contact a call is about. If no number matches, the contact is
     * looked up in the address book and matched by contact id instead.
     */
    fun findFor(ctx: Context, number: String): Reminder? {
        val notes = load(ctx)
        if (notes.isEmpty()) return null
        for (n in notes) {
            for (num in n.numbers) {
                if (numbersMatch(num, number)) return n
            }
        }
        val contactId = contactIdFor(ctx, number)
        if (contactId.isNotEmpty()) {
            for (n in notes) {
                if (n.contactId == contactId) return n
            }
        }
        return null
    }

    /**
     * Flips the "remind me" flag of one note, straight in the file.
     *
     * Used when the notification button is pressed while the app is not
     * running - there is no Dart code to do it, and waiting for the next app
     * start would make "Stop permanently" feel broken.
     */
    fun setEnabled(ctx: Context, id: String, enabled: Boolean): Boolean {
        if (id.isEmpty()) return false
        val f = file(ctx)
        if (!f.exists()) return false
        return try {
            val arr = JSONArray(f.readText())
            var changed = false
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("id") == id) {
                    o.put("enabled", enabled)
                    o.put("updatedAt", System.currentTimeMillis())
                    changed = true
                    break
                }
            }
            if (changed) f.writeText(arr.toString())
            changed
        } catch (e: Exception) {
            false
        }
    }

    /** The contacts provider id of the contact that owns [number]. */
    fun contactIdFor(ctx: Context, number: String): String {
        val digits = digitsOf(number)
        if (digits.isEmpty()) return ""
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(digits),
            )
            ctx.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup._ID),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) c.getString(0) ?: "" else ""
            } ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    fun digitsOf(raw: String): String = raw.filter { it.isDigit() }

    /**
     * Two phone numbers are the same number if one is the other plus a country
     * code. "5550100" and "+15550100" must match, "5550100" and "5550101" must
     * not. This is the same rule as numbersMatch() in lib/model.dart.
     */
    fun numbersMatch(a: String, b: String): Boolean {
        val x = digitsOf(a)
        val y = digitsOf(b)
        if (x.isEmpty() || y.isEmpty()) return false
        if (x == y) return true
        val short = if (x.length <= y.length) x else y
        val long = if (x.length <= y.length) y else x
        if (short.length < 7) return false
        return long.endsWith(short)
    }
}
