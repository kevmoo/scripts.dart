import 'package:args/command_runner.dart';
import 'package:io/io.dart';
import 'package:kevmoo_scripts/src/puppy.dart';
import 'package:kevmoo_scripts/src/testable_print.dart';

Future<void> main(List<String> args) async {
  try {
    final puppyArgs = parseRunArgs(args);
    if (puppyArgs.help) {
      print('Run a command in all package directories.');
      print('');
      print('Usage: puppy [arguments] <command to invoke>');
      print('');
      print('Options:');
      print(runArgsUsage);
      return;
    }
    await runPuppy(puppyArgs);
  } on UsageException catch (e) {
    setError(message: e.message, exitCode: ExitCode.usage.code);
  } on PuppyException catch (e) {
    setError(message: e.message, exitCode: ExitCode.software.code);
  } catch (e, stack) {
    setError(
      message: 'An unexpected error occurred: $e',
      exitCode: ExitCode.software.code,
      stack: stack,
    );
  }
}
