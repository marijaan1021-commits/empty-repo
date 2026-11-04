import 'package:flutter/material.dart';

import 'bridge.dart';
import 'controller.dart';
import 'model.dart';
import 'note_editor.dart';
import 'contact_picker.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final Controller controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Controller get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _askPermissions();
  }

  Future<void> _askPermissions() async {
    for (final String p in <String>[
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.READ_CONTACTS',
      'android.permission.READ_CALL_LOG',
      'android.permission.READ_PHONE_STATE',
    ]) {
      final bool? granted = await Bridge.invoke<bool>('requestPermission', <String, dynamic>{'permission': p});
      if (granted != true) break; // one denial at a time, the user can retry
    }
    // The watcher's ongoing notification is dropped by Android if it was
    // posted before POST_NOTIFICATIONS was granted, so ask the native side to
    // start the watcher again now that the answer is known.
    await c.ensureMonitorRunning();
    await c.refreshStatus();
  }

  Future<void> _addContact() async {
    final ContactRef? contact = await Navigator.of(context).push<ContactRef>(
      MaterialPageRoute<ContactRef>(builder: (_) => const ContactPickerScreen()),
    );
    if (contact == null || !mounted) return;
    final CallNote note = await c.upsertForContact(
      contactId: contact.contactId,
      name: contact.name,
      numbers: contact.numbers,
    );
    if (!mounted) return;
    await showNoteEditor(context, c, note);
  }

  Future<void> _edit(CallNote note) async => showNoteEditor(context, c, note);

  Future<void> _confirmDelete(CallNote note) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: Text('Remove ${note.name.isEmpty ? 'contact' : note.name}?'),
        content: const Text('The note is deleted and you will not be reminded about this contact any more.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (yes == true) await c.deleteNote(note);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (BuildContext context, _) {
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: const Text('CallNote', style: TextStyle(fontWeight: FontWeight.bold)),
            actions: <Widget>[
              IconButton(
                tooltip: 'Menu',
                icon: const Icon(Icons.more_vert),
                onPressed: () => _menu(context),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                if (!c.monitoring) _notWatching(),
                Expanded(
                  child: c.notes.isEmpty ? _emptyState() : _list(),
                ),
              ],
            ),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _addContact,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            elevation: 0,
            tooltip: null,
            child: const Icon(Icons.person_add_alt_1),
          ),
        );
      },
    );
  }

  Widget _list() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: c.notes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int i) {
        final CallNote note = c.notes[i];
        return _NoteCard(
          note: note,
          onTap: () => _edit(note),
          onToggle: () => c.toggleEnabled(note),
          onDelete: () => _confirmDelete(note),
        );
      },
    );
  }

  Widget _notWatching() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1F00),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: <Widget>[
          Icon(Icons.visibility_off, size: 18, color: Color(0xFFFFC107)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'CallNote is not watching for calls. Notes will not appear.',
              style: TextStyle(fontSize: 13, color: Color(0xFFFFE082), height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.phone_in_talk_outlined, size: 56, color: Color(0xFF444444)),
            const SizedBox(height: 16),
            const Text(
              'No reminders yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add a contact and write down what you want to say or ask when they call.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF888888), height: 1.4),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _addContact,
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label: const Text('Add a contact'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFF333333)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
    // Watching can be turned off from the notification, so read the real
    // state before showing the menu.
    await c.refreshStatus();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF333333),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            _menuItem(ctx, Icons.notifications_none, 'Post a test notification', () {
              c.postTestNotification();
              Navigator.pop(ctx);
            }),
            _menuItem(
              ctx,
              c.monitoring ? Icons.visibility_off : Icons.visibility,
              c.monitoring ? 'Stop watching calls' : 'Start watching calls',
              () {
                final bool next = !c.monitoring;
                Navigator.pop(ctx);
                c.setMonitoring(next);
              },
            ),
            _menuItem(ctx, Icons.shield_outlined, 'Caller ID access', () async {
              Navigator.pop(ctx);
              await Bridge.invoke<bool>('requestCallerIdRole');
              await c.refreshStatus();
            }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      onTap: onTap,
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  final CallNote note;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final String initial =
        note.name.isNotEmpty ? note.name.characters.first.toUpperCase() : '#';
    final bool dim = !note.willRemind;
    return Material(
      color: const Color(0xFF111111),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              CircleAvatar(
                radius: 20,
                backgroundColor: dim ? const Color(0xFF222222) : Colors.white,
                child: Text(
                  initial,
                  style: TextStyle(
                    color: dim ? const Color(0xFF666666) : Colors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      note.name.isEmpty ? 'Unknown contact' : note.name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: dim ? const Color(0xFF777777) : Colors.white,
                      ),
                    ),
                    if (note.numbers.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          note.numbers.join('  ·  '),
                          style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      note.text.trim().isEmpty ? 'No note - will not remind you' : note.text,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.35,
                        color: note.text.trim().isEmpty
                            ? const Color(0xFF555555)
                            : const Color(0xFFCCCCCC),
                        fontStyle: note.text.trim().isEmpty ? FontStyle.italic : FontStyle.normal,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                children: <Widget>[
                  Switch(
                    value: note.enabled,
                    onChanged: (_) => onToggle(),
                    activeThumbColor: Colors.white,
                    activeTrackColor: Colors.white24,
                  ),
                  SizedBox(
                    width: 40,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline, color: Color(0xFF555555)),
                      onPressed: onDelete,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
