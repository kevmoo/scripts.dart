import 'dart:async';
import 'dart:io' as io;

Future<String> runProcess(String executable, List<String> arguments) async {
  final result = await io.Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw io.ProcessException(
      executable,
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
  return result.stdout as String;
}
