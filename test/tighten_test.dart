import 'dart:async';
import 'dart:io';

import 'package:kevmoo_scripts/src/tighten.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:yaml/yaml.dart';

void main() {
  test('tightenUsage matches expected', () {
    expect(tightenUsage, '''
-w, --workspace    Tighten workspace dependencies
-h, --help         Print this usage information.''');
  });

  test('tighten non-workspace', () async {
    await d.dir('simple', [
      d.file('pubspec.yaml', '''
name: simple
environment:
  sdk: ^3.0.0
dependencies:
  # A dependency that definitely exists and has versions
  path: any
'''),
    ]).create();

    await Process.run('dart', [
      'pub',
      'get',
    ], workingDirectory: d.path('simple'));

    await tighten(cwd: d.path('simple'));

    final pubspec =
        loadYaml(
              File(p.join(d.path('simple'), 'pubspec.yaml')).readAsStringSync(),
            )
            as YamlMap;

    final pathConstraint = (pubspec['dependencies'] as Map)['path'] as String;
    expect(pathConstraint, isNot('any')); // Should have tightened
  });

  group('workspace', () {
    Future<void> createWorkspace() async {
      await d.dir('workspace_root', [
        d.file('pubspec.yaml', '''
name: workspace_root
environment:
  sdk: ^3.7.0
workspace:
  - pkg_a
  - pkg_b
'''),
        d.dir('pkg_a', [
          d.file('pubspec.yaml', '''
name: pkg_a
version: 1.0.0-wip
environment:
  sdk: ^3.7.0
resolution: workspace
'''),
        ]),
        d.dir('pkg_b', [
          d.file('pubspec.yaml', '''
name: pkg_b
environment:
  sdk: ^3.7.0
resolution: workspace
dependencies:
  pkg_a: any
'''),
        ]),
      ]).create();

      final result = await Process.run('dart', [
        'pub',
        'get',
      ], workingDirectory: d.path('workspace_root'));
      if (result.exitCode != 0) {
        fail('dart pub get failed:\n${result.stdout}\n${result.stderr}');
      }
    }

    test('warns if --workspace missing in root', () async {
      await createWorkspace();

      // Capture print output
      final prints = <String>[];
      final zone = Zone.current.fork(
        specification: ZoneSpecification(
          print: (self, parent, zone, line) {
            prints.add(line);
            parent.print(zone, line);
          },
        ),
      );

      await zone.run(() => tighten(cwd: d.path('workspace_root')));

      expect(
        prints,
        contains(
          contains(
            'WARNING: You are in a workspace but did NOT use the '
            '--workspace flag',
          ),
        ),
      );
    });

    test('reverts changes with --workspace in root', () async {
      await createWorkspace();

      await tighten(isWorkspace: true, cwd: d.path('workspace_root'));

      final pkgBPubspec =
          loadYaml(
                File(
                  p.join(d.path('workspace_root'), 'pkg_b', 'pubspec.yaml'),
                ).readAsStringSync(),
              )
              as YamlMap;

      // Should still be 'any' because it was reverted
      expect((pkgBPubspec['dependencies'] as Map)['pkg_a'], 'any');
    });

    test('reverts changes with --workspace in sub-package', () async {
      await createWorkspace();

      await tighten(isWorkspace: true, cwd: d.path('workspace_root/pkg_b'));

      final pkgBPubspec =
          loadYaml(
                File(
                  p.join(d.path('workspace_root'), 'pkg_b', 'pubspec.yaml'),
                ).readAsStringSync(),
              )
              as YamlMap;

      // Should still be 'any' because it was reverted
      expect((pkgBPubspec['dependencies'] as Map)['pkg_a'], 'any');
    });
  });
}
