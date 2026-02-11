import 'package:args/args.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';
import 'package:kevmoo_scripts/src/tighten.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag(
      'workspace',
      negatable: false,
      help: 'Tighten workspace dependencies',
    );
  final results = parser.parse(args);

  try {
    await tighten(isWorkspace: results['workspace'] as bool);
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
