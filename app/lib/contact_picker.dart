import 'dart:async';

import 'package:flutter/material.dart';

import 'bridge.dart';

/// A contact from the device's address book.
class ContactRef {
  ContactRef({required this.contactId, required this.name, required this.numbers});

  final String contactId;
  final String name;
  final List<String> numbers;

  String get display => name.isEmpty ? (numbers.isEmpty ? 'Unknown' : numbers.first) : name;
}

class ContactPickerScreen extends StatefulWidget {
  const ContactPickerScreen({super.key});

  @override
  State<ContactPickerScreen> createState() => _ContactPickerScreenState();
}

class _ContactPickerScreenState extends State<ContactPickerScreen> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  List<ContactRef> _contacts = <ContactRef>[];
  bool _loading = true;
  bool _noPermission = false;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String query) async {
    setState(() => _loading = true);
    final List<dynamic>? raw = await Bridge.invoke<List<dynamic>>(
      'listContacts',
      <String, dynamic>{'query': query},
    );
    if (!mounted) return;
    if (raw == null) {
      final bool? ok = await Bridge.invoke<bool>('hasPermission',
          <String, dynamic>{'permission': 'android.permission.READ_CONTACTS'});
      if (!mounted) return;
      setState(() {
        _noPermission = ok != true;
        _loading = false;
        _contacts = <ContactRef>[];
      });
      return;
    }
    final List<ContactRef> list = <ContactRef>[];
    for (final dynamic e in raw) {
      if (e is! Map) continue;
      final Map<dynamic, dynamic> m = Map<dynamic, dynamic>.from(e);
      final List<dynamic> nums = (m['numbers'] as List?) ?? <dynamic>[];
      list.add(ContactRef(
        contactId: (m['contactId'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        numbers: nums.map((dynamic n) => n.toString()).toList(),
      ));
    }
    setState(() {
      _contacts = list;
      _loading = false;
      _noPermission = false;
    });
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _load(value.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Pick a contact', style: TextStyle(fontSize: 18)),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                autofocus: false,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Search name or number',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                ),
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (_noPermission) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.contacts_outlined, size: 48, color: Color(0xFF444444)),
              const SizedBox(height: 12),
              const Text(
                'CallNote needs access to your contacts to pick who to remind you about.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF888888), height: 1.4),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () async {
                  await Bridge.invoke<bool>('requestPermission',
                      <String, dynamic>{'permission': 'android.permission.READ_CONTACTS'});
                  _load(_search.text.trim());
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF333333)),
                ),
                child: const Text('Allow'),
              ),
            ],
          ),
        ),
      );
    }
    if (_contacts.isEmpty) {
      return const Center(
        child: Text('No contacts found', style: TextStyle(color: Color(0xFF666666))),
      );
    }
    return ListView.builder(
      itemCount: _contacts.length,
      itemBuilder: (BuildContext context, int i) {
        final ContactRef c = _contacts[i];
        return ListTile(
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0xFF1C1C1C),
            child: Text(
              c.display.characters.first.toUpperCase(),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
          title: Text(c.display, style: const TextStyle(fontSize: 15)),
          subtitle: c.numbers.isEmpty
              ? null
              : Text(c.numbers.join('  ·  '),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
          onTap: () => Navigator.of(context).pop(c),
        );
      },
    );
  }
}
