import 'package:kevmoo_scripts/src/lint_cleanup.dart';
import 'package:test/test.dart';

void main() {
  test('lintCleanupUsage matches expected', () {
    expect(lintCleanupUsage, '''
-p, --package-dir     The directory to a package within the repository that depends
                      on the referenced include file. Needed for mono repos.
-r, --[no-]rewrite    Rewrites the analysis_options.yaml file to remove duplicative entries.
-h, --help            Prints out usage and exits''');
  });
}
