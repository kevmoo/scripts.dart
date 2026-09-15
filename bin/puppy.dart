import 'package:kevmoo_scripts/src/puppy.dart';
import 'package:kevmoo_scripts/src/shared/gh_args.dart';

Future<void> main(List<String> args) async {
  await runCliGuarded(() async {
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
  });
}
