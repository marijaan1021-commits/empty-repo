import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the single MethodChannel that talks to the native side.
///
/// The native side owns: notifications, contact lookup, call detection.
/// This side owns: the note list and the decision "does this call deserve a
/// reminder?".
class Bridge {
  Bridge._();

  static const MethodChannel _channel = MethodChannel('com.example.mini_app/callnote');
  static final StreamController<Map<dynamic, dynamic>> _events =
      StreamController<Map<dynamic, dynamic>>.broadcast();
  static bool _initialised = false;

  /// Events pushed from native: onCall, onNotificationAction.
  static Stream<Map<dynamic, dynamic>> get events => _events.stream;

  static void init() {
    if (_initialised) return;
    _initialised = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      final Map<dynamic, dynamic> args = call.arguments is Map
          ? Map<dynamic, dynamic>.from(call.arguments as Map)
          : <dynamic, dynamic>{};
      _events.add(<dynamic, dynamic>{'method': call.method, 'args': args});
      return null;
    });
  }

  static Future<T?> invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      debugPrint('callnote bridge: $method failed: $e');
      return null;
    }
  }
}
