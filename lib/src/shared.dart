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
