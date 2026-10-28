import 'package:flutter_test/flutter_test.dart';
import 'package:mini_app/model.dart';

void main() {
  test('numbers match across country codes', () {
    expect(numbersMatch('5550100', '+15550100'), isTrue);
    expect(numbersMatch('(555) 010-0100', '5550100100'), isTrue);
    expect(numbersMatch('5550100', '5550101'), isFalse);
    expect(numbersMatch('', '5550100'), isFalse);
  });

  test('a note only reminds when it is enabled and has text', () {
    final CallNote note = CallNote(
      id: 'n1',
      contactId: 'c1',
      name: 'Batman',
      numbers: <String>['5550100'],
      text: '',
      enabled: true,
      updatedAt: 0,
    );
    expect(note.willRemind, isFalse);
    note.text = 'ask about the surgery';
    expect(note.willRemind, isTrue);
    note.enabled = false;
    expect(note.willRemind, isFalse);
  });

  test('notes survive a json round trip', () {
    final CallNote note = CallNote(
      id: 'n1',
      contactId: 'c1',
      name: 'Batman',
      numbers: <String>['5550100'],
      text: 'say hi',
      enabled: true,
      updatedAt: 42,
    );
    final CallNote back = CallNote.fromJson(note.toJson());
    expect(back.id, 'n1');
    expect(back.name, 'Batman');
    expect(back.numbers, <String>['5550100']);
    expect(back.text, 'say hi');
    expect(back.enabled, isTrue);
  });
}
