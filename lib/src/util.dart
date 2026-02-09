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
    final pubspecs = dir
        .listSync()
        .whereType<File>()
        .where((element) => element.uri.pathSegments.last == 'pubspec.yaml')
        .toList();

    if (pubspecs.isNotEmpty) {
      results.add(dir);
    }

    if (!pubspecs.isNotEmpty || deep) {
      for (var subDir in dir.listSync().whereType<Directory>().where(
        (element) =>
            !element.uri.pathSegments.any((segment) => segment.startsWith('.')),
      )) {
        traverse(subDir, deep: deep);
      }
    }
  }

  traverse(Directory.current, deep: deep);

  results.sort((a, b) => a.path.compareTo(b.path));

  return results;
}
