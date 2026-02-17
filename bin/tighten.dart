import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:kevmoo_scripts/src/tighten.dart';

void main(List<String> args) async {
  final TightenOptions options;
  try {
    options = parseTightenOptions(args);
  } on UsageException catch (e) {
    setError(message: e.message, exitCode: ExitCode.usage.code);
    print(e.usage);
    return;
  }

  if (options.help) {
    print('Tighten workspace dependencies.');
    print('');
    print(tightenUsage);
    return;
  }

  try {
    await tighten(isWorkspace: options.workspace);
  } on TightenException catch (e) {
    setError(message: e.message, exitCode: ExitCode.config.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
