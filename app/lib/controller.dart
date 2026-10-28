import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bridge.dart';
import 'model.dart';

/// A call that was detected by the native side.
class CallEvent {
  CallEvent({
    required this.number,
    required this.incoming,
    required this.sessionId,
  });

  final String number;
  final bool incoming;

  /// Identifies one single call. The same call always produces the same id,
  /// so a call is never reminded about twice - but the *next* call is a new
  /// session and reminds again.
  final String sessionId;
}

/// Holds the notes, listens for calls and for notification button presses.
class Controller extends ChangeNotifier {
  Controller(this.store);

  final NoteStore store;

  List<CallNote> notes = <CallNote>[];

  /// Session ids we already reminded about. Kept in memory on purpose: a new
  /// call is a new session, even if it happens seconds after the last one.
  final Set<String> _handledSessions = <String>{};

  bool ready = false;
  bool callerIdRoleHeld = false;
  String status = '';

  Future<void> init() async {
    await store.load();
    notes = store.notes;
    Bridge.events.listen(_onNativeEvent);
    // The native side queues button presses that happened while the app was
    // closed. Pick them up now.
    await _drainPendingActions();
    await refreshStatus();
    ready = true;
    notifyListeners();
  }

  Future<void> refreshStatus() async {
    final role = await Bridge.invoke<bool>('hasCallerIdRole');
    callerIdRoleHeld = role ?? false;
    notifyListeners();
  }

  // ---------------------------------------------------------------- actions

  void toggleEnabled(CallNote note) {
    note.enabled = !note.enabled;
    note.updatedAt = DateTime.now().millisecondsSinceEpoch;
    store.save();
    notifyListeners();
  }

  Future<void> saveNote(CallNote note) async {
    note.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await store.save();
    notifyListeners();
  }

  Future<void> deleteNote(CallNote note) async {
    notes.removeWhere((CallNote n) => n.id == note.id);
    await Bridge.invoke<bool>('cancelNotification', <String, dynamic>{'id': note.id});
    await store.save();
    notifyListeners();
  }

  /// Adds (or updates) the note for a contact coming from the contact picker.
  Future<CallNote> upsertForContact({
    required String contactId,
    required String name,
    required List<String> numbers,
  }) async {
    CallNote? existing;
    for (final CallNote n in notes) {
      if (n.contactId == contactId && contactId.isNotEmpty) {
        existing = n;
        break;
      }
    }
    if (existing == null) {
      for (final CallNote n in notes) {
        for (final String num in numbers) {
          if (n.numbers.any((String x) => numbersMatch(x, num))) {
            existing = n;
            break;
          }
        }
        if (existing != null) break;
      }
    }
    if (existing == null) {
      existing = CallNote(
        id: 'n${DateTime.now().microsecondsSinceEpoch}',
        contactId: contactId,
        name: name,
        numbers: numbers,
        text: '',
        enabled: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      notes.add(existing);
    } else {
      existing.contactId = contactId.isNotEmpty ? contactId : existing.contactId;
      existing.name = name.isNotEmpty ? name : existing.name;
      existing.numbers = numbers.isNotEmpty ? numbers : existing.numbers;
    }
    await store.save();
    notifyListeners();
    return existing;
  }

  // ------------------------------------------------------------------ calls

  void _onNativeEvent(Map<dynamic, dynamic> event) {
    final String method = (event['method'] ?? '').toString();
    final Map<dynamic, dynamic> args = Map<dynamic, dynamic>.from(
      (event['args'] ?? <dynamic, dynamic>{}) as Map,
    );
    if (method == 'onCall') {
      onCall(CallEvent(
        number: (args['number'] ?? '').toString(),
        incoming: args['incoming'] == true,
        sessionId: (args['sessionId'] ?? '').toString(),
      ));
    } else if (method == 'onNotificationAction') {
      onNotificationAction(
        (args['action'] ?? '').toString(),
        (args['id'] ?? '').toString(),
      );
    }
  }

  Future<void> onCall(CallEvent event) async {
    if (event.number.isEmpty) return;
    if (event.sessionId.isNotEmpty) {
      if (_handledSessions.contains(event.sessionId)) return;
      _handledSessions.add(event.sessionId);
    }
    final CallNote? note = await findNoteFor(event.number);
    if (note == null) return;
    if (!note.willRemind) return; // disabled, or the note has no text
    await Bridge.invoke<bool>('notify', <String, dynamic>{
      'id': note.id,
      'title': note.name.isEmpty ? event.number : note.name,
      'body': note.text,
    });
  }

  /// The note that belongs to a phone number, if any.
  Future<CallNote?> findNoteFor(String number) async {
    final List<CallNote> candidates = <CallNote>[];

    for (final CallNote n in notes) {
      if (n.numbers.any((String x) => numbersMatch(x, number))) {
        candidates.add(n);
      }
    }

    final String contactId = await _contactIdFor(number);
    if (contactId.isNotEmpty) {
      for (final CallNote n in notes) {
        if (n.contactId == contactId && !candidates.contains(n)) {
          candidates.add(n);
        }
      }
    }

    for (final CallNote n in candidates) {
      if (n.willRemind) return n;
    }
    return null;
  }

  Future<String> _contactIdFor(String number) async {
    final List<dynamic>? info =
        await Bridge.invoke<List<dynamic>>('lookupContact', <String, dynamic>{'number': number});
    if (info == null || info.isEmpty) return '';
    final dynamic first = info.first;
    if (first is! Map) return '';
    return (first['contactId'] ?? '').toString();
  }

  // ------------------------------------------------------ notification taps

  /// "done"   -> the reminder is fulfilled, stop reminding about this contact.
  /// "snooze" -> remind me again on the next call.
  Future<void> onNotificationAction(String action, String id) async {
    final int index = notes.indexWhere((CallNote n) => n.id == id);
    if (index >= 0) {
      final CallNote note = notes[index];
      if (action == 'done') {
        note.enabled = false;
        note.updatedAt = DateTime.now().millisecondsSinceEpoch;
        await store.save();
      }
      await Bridge.invoke<bool>('cancelNotification', <String, dynamic>{'id': id});
      notifyListeners();
    }
  }

  Future<void> _drainPendingActions() async {
    final List<dynamic>? pending =
        await Bridge.invoke<List<dynamic>>('drainActions');
    if (pending == null) return;
    for (final dynamic p in pending) {
      if (p is! Map) continue;
      await onNotificationAction(
        (p['action'] ?? '').toString(),
        (p['id'] ?? '').toString(),
      );
    }
  }

  // --------------------------------------------------------------- debugging

  Future<void> postTestNotification() async {
    final CallNote? note = notes.isEmpty ? null : notes.first;
    await Bridge.invoke<bool>('notify', <String, dynamic>{
      'id': note?.id ?? 'test',
      'title': note?.name ?? 'Batman',
      'body': note?.text.isNotEmpty == true ? note!.text : 'Test reminder - ask about the surgery',
    });
  }

  Future<void> simulateCall({bool incoming = true}) async {
    final CallNote? note = notes.isEmpty ? null : notes.first;
    final String number = note != null && note.numbers.isNotEmpty
        ? note.numbers.first
        : '5550100';
    await Bridge.invoke<bool>('simulateCall', <String, dynamic>{
      'number': number,
      'incoming': incoming,
    });
  }
}

/// Creates the store file inside the app's private data directory.
Future<NoteStore> openStore() async {
  final String? dir = await Bridge.invoke<String>('dataDir');
  final String base = (dir == null || dir.isEmpty) ? Directory.systemTemp.path : dir;
  return NoteStore(File('$base/callnote.json'));
}
