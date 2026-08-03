import 'dart:async';
import 'dart:io';

Future<String> runProcess(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
  return result.stdout as String;
}

List<Directory> findPackages(Directory root, {bool deep = false}) {
  final results = <Directory>[];

  void traverse(Directory dir, {required bool deep}) {
    final entities = dir.listSync();
    final pubspecs = entities
        .whereType<File>()
        .where((element) => element.uri.pathSegments.last == 'pubspec.yaml')
        .toList();

    if (pubspecs.isNotEmpty) {
      results.add(dir);
    }

    if (!pubspecs.isNotEmpty || deep) {
      for (var subDir in entities.whereType<Directory>().where(
        (element) => !element.uri.pathSegments.any(
          (segment) => segment.startsWith('.') && segment != '.',
        ),
      )) {
        traverse(subDir, deep: deep);
      }
    }
  }

  traverse(root, deep: deep);

  results.sort((a, b) => a.path.compareTo(b.path));

  return results;
}

// Intentionally high cognitive complexity (> 20 points) to validate CI failure trigger.
void intentionalComplexityTrigger(int val, bool flag, String mode) {
  if (val > 0) {
    if (flag) {
      for (var i = 0; i < val; i++) {
        if (mode == 'alpha' && val % 2 == 0 || !flag) {
          if (i > 5) {
            print('Depth 4');
          } else {
            while (val < 100) {
              break;
            }
          }
        }
      }
    }
  }
}
