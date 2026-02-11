import 'dart:async';
import 'dart:io';

import 'package:kevmoo_scripts/src/tighten.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:yaml/yaml.dart';

void main() {
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

    await _runInDir(d.path('simple'), () async {
      // We need to run pub get first so pub downgrade works?
      // Actually tighten runs pub downgrade --tighten immediately.
      // But resolution needs to happen.
      await Process.run('dart', ['pub', 'get']);

      await tighten();

      final pubspec =
          loadYaml(
                File(
                  p.join(d.path('simple'), 'pubspec.yaml'),
                ).readAsStringSync(),
              )
              as YamlMap;

      final pathConstraint = (pubspec['dependencies'] as Map)['path'] as String;
      expect(pathConstraint, isNot('any')); // Should have tightened
    });
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

      // Run pub get in root to set up resolution
      await _runInDir(d.path('workspace_root'), () async {
        final result = await Process.run('dart', ['pub', 'get']);
        if (result.exitCode != 0) {
          fail('dart pub get failed:\n${result.stdout}\n${result.stderr}');
        }
      });
    }

    test('warns if --workspace missing in root', () async {
      await createWorkspace();

      await _runInDir(d.path('workspace_root'), () async {
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

        await zone.run(tighten);

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
    });

    test('reverts changes with --workspace in root', () async {
      await createWorkspace();

      await _runInDir(d.path('workspace_root'), () async {
        await tighten(isWorkspace: true);

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

    test('reverts changes with --workspace in sub-package', () async {
      await createWorkspace();

      await _runInDir(d.path('workspace_root/pkg_b'), () async {
        await tighten(isWorkspace: true);

        final pkgBPubspec =
            loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;

        // Should still be 'any' because it was reverted
        expect((pkgBPubspec['dependencies'] as Map)['pkg_a'], 'any');
      });
    });
  });
}

Future<T> _runInDir<T>(String path, Future<T> Function() action) async {
  final original = Directory.current;
  Directory.current = path;
  try {
    return await action();
  } finally {
    Directory.current = original;
  }
}
