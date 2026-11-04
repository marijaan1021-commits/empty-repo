package com.example.mini_app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var engine: CallNoteEngine? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The first launch turns monitoring on. After that the user's choice
        // is kept, so "Stop watching" is not undone by opening the app.
        val prefs = getSharedPreferences(CallNoteEngine.PREFS, MODE_PRIVATE)
        if (!prefs.contains(CallNoteEngine.KEY_MONITORING)) {
            CallNoteEngine.setMonitoring(this, true)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engine = CallNoteEngine.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // Keeps the reminder working after the app is swiped away.
        CallNoteMonitorService.start(this)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        engine?.onRequestPermissionsResult(requestCode, grantResults)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == CallNoteEngine.REQ_ROLE) {
            engine?.onRoleResult(resultCode == RESULT_OK)
        }
    }
}
