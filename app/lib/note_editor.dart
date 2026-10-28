import 'package:flutter/material.dart';

import 'controller.dart';
import 'model.dart';

/// Opens the note editor for a contact.
Future<void> showNoteEditor(BuildContext context, Controller controller, CallNote note) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF141414),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (BuildContext ctx) => _NoteEditor(controller: controller, note: note),
  );
}

class _NoteEditor extends StatefulWidget {
  const _NoteEditor({required this.controller, required this.note});

  final Controller controller;
  final CallNote note;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late final TextEditingController _text = TextEditingController(text: widget.note.text);
  late bool _enabled = widget.note.enabled;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    widget.note.text = _text.text;
    widget.note.enabled = _enabled;
    await widget.controller.saveNote(widget.note);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final CallNote note = widget.note;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF333333),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.white,
                  child: Text(
                    note.name.isEmpty ? '#' : note.name.characters.first.toUpperCase(),
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        note.name.isEmpty ? 'Unknown contact' : note.name,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      if (note.numbers.isNotEmpty)
                        Text(
                          note.numbers.join('  ·  '),
                          style: const TextStyle(fontSize: 12, color: Color(0xFF777777)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'What do you want to say or ask?',
              style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              maxLines: 4,
              minLines: 3,
              autofocus: false,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 15, height: 1.35),
              decoration: const InputDecoration(
                hintText: 'e.g. ask about the surgery',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                const Icon(Icons.info_outline, size: 15, color: Color(0xFF666666)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _text.text.trim().isEmpty
                        ? 'An empty note never reminds you.'
                        : 'You will be reminded on every call with this contact.',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (bool v) => setState(() => _enabled = v),
              activeThumbColor: Colors.white,
              activeTrackColor: Colors.white24,
              title: const Text('Remind me', style: TextStyle(fontSize: 15)),
              subtitle: const Text(
                'Turn off to mute this contact without deleting the note',
                style: TextStyle(fontSize: 12, color: Color(0xFF777777)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Color(0xFF333333)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
