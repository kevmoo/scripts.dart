import 'package:kevmoo_scripts/src/dart_clean.dart';
import 'package:test/test.dart';

void main() {
  test('formats a basic command', () {
    expect(
      formatCmdline(
        '/usr/local/bin/dart run build_runner watch --delete-conflicting-outputs',
      ),
      'dart run build_runner watch',
    );
  });

  test('formats a script execution', () {
    expect(
      formatCmdline(
        '/opt/homebrew/bin/dart --observe=8080 bin/server.dart --port 8080',
      ),
      'dart server.dart',
    );
  });

  test('formats a test file execution', () {
    expect(
      formatCmdline('dart --enable-asserts test/foo/bar_test.dart'),
      'dart bar_test.dart',
    );
  });

  test('handles unknown', () {
    expect(formatCmdline('<unknown>'), '<unknown>');
  });

  test('handles empty parts gracefully', () {
    // split(' ') on ' dart   ' would result in ['', 'dart', '', '', '']
    // empty parts are skipped, so it should just return 'dart'
    expect(formatCmdline(' dart   '), 'dart');
  });

  test('formats snapshot execution', () {
    expect(
      formatCmdline(
        '/b/s/w/ir/x/w/recipe_cleanup/recipe_cleanup.snapshot --dry-run',
      ),
      'recipe_cleanup.snapshot',
    );
  });
}
