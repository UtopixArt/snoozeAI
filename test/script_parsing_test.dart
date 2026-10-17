import 'package:flutter_test/flutter_test.dart';
import 'package:snooze_ai/services/show_generator.dart';

void main() {
  test('splits objects that Grok glued back to back', () {
    const text = '{"title":"Réveil chrome","blocks":[],"snooze_1":[],"snooze_2":[]}'
        '{"title":"Vrai","blocks":[{"kind":"talk","topic":"x","lines":[]}]}';
    expect(topLevelJsonObjects(text).toList(), [
      '{"title":"Réveil chrome","blocks":[],"snooze_1":[],"snooze_2":[]}',
      '{"title":"Vrai","blocks":[{"kind":"talk","topic":"x","lines":[]}]}',
    ]);
  });

  test('ignores braces inside strings and text around the JSON', () {
    const text = 'Voici :\n```json\n{"text":"un } piège { avec \\"guillemets\\""}\n```';
    expect(topLevelJsonObjects(text).single, '{"text":"un } piège { avec \\"guillemets\\""}');
  });
}
