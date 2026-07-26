import 'package:checks/checks.dart';
import 'package:kevmoo_scripts/src/process_utils.dart';
import 'package:test/scaffolding.dart';

void main() {
  test('formats a basic command', () {
    check(
      formatCmdline(
        '/usr/local/bin/dart run build_runner watch --delete-conflicting-outputs',
      ),
    ).equals('dart run build_runner watch');
  });

  test('formats a script execution', () {
    check(
      formatCmdline(
        '/opt/homebrew/bin/dart --observe=8080 bin/server.dart --port 8080',
      ),
    ).equals('dart server.dart');
  });

  test('formats a test file execution', () {
    check(formatCmdline('dart --enable-asserts test/foo/bar_test.dart'))
        .equals('dart bar_test.dart');
  });

  test('handles unknown', () {
    check(formatCmdline('<unknown>')).equals('<unknown>');
  });

  test('handles empty parts gracefully', () {
    // split(' ') on ' dart   ' would result in ['', 'dart', '', '', '']
    // empty parts are skipped, so it should just return 'dart'
    check(formatCmdline(' dart   ')).equals('dart');
  });

  test('formats snapshot execution', () {
    check(
      formatCmdline(
        '/b/s/w/ir/x/w/recipe_cleanup/recipe_cleanup.snapshot --dry-run',
      ),
    ).equals('recipe_cleanup.snapshot');
  });
}
