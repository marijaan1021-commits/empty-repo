import 'dart:convert';
import 'dart:io';

/// A reminder attached to a device contact.
class CallNote {
  CallNote({
    required this.id,
    required this.contactId,
    required this.name,
    required this.numbers,
    required this.text,
    required this.enabled,
    required this.updatedAt,
  });

  final String id;

  /// Contacts provider id of the contact this note belongs to.
  String contactId;

  /// Display name snapshot, so the note still renders if the contact is deleted.
  String name;

  /// Snapshot of the contact's phone numbers, used for fast number matching.
  List<String> numbers;

  /// The reminder text. Empty text means "no reminder" (per the spec).
  String text;

  /// Whether the user wants to be reminded about this contact.
  bool enabled;

  int updatedAt;

  /// A note only fires when it is enabled AND actually says something.
  bool get willRemind => enabled && text.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'contactId': contactId,
        'name': name,
        'numbers': numbers,
        'text': text,
        'enabled': enabled,
        'updatedAt': updatedAt,
      };

  factory CallNote.fromJson(Map<String, dynamic> j) => CallNote(
        id: j['id'] as String? ?? '',
        contactId: j['contactId'] as String? ?? '',
        name: j['name'] as String? ?? '',
        numbers: ((j['numbers'] as List?) ?? const <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList(),
        text: j['text'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
        updatedAt: j['updatedAt'] as int? ?? 0,
      );
}

/// Digits only, no formatting.
String digitsOf(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

/// Two phone numbers are the same number if one is the other plus a country
/// code. "5550100" and "+15550100" must match, "5550100" and "5550101" must not.
bool numbersMatch(String a, String b) {
  final x = digitsOf(a);
  final y = digitsOf(b);
  if (x.isEmpty || y.isEmpty) return false;
  if (x == y) return true;
  final short = x.length <= y.length ? x : y;
  final long = x.length <= y.length ? y : x;
  if (short.length < 7) return false;
  return long.endsWith(short);
}

/// The note list, persisted as one JSON file in the app's private data dir.
class NoteStore {
  NoteStore(this.file);

  final File file;
  List<CallNote> notes = <CallNote>[];

  Future<void> load() async {
    notes = <CallNote>[];
    try {
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      notes = decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((dynamic e) => CallNote.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      notes = <CallNote>[];
    }
  }

  Future<void> save() async {
    try {
      await file.writeAsString(
        jsonEncode(notes.map((CallNote n) => n.toJson()).toList()),
      );
    } catch (_) {
      /* keep the app usable if the disk is unhappy */
    }
  }
}
