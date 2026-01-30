import 'dart:io';

import 'package:git/git.dart';
import 'package:kevmoo_scripts/src/git_clean.dart';

void main(List<String> args) async {
  try {
    // 1. Validating we are in a git repo
    if (!await GitDir.isGitDir('.')) {
      throw GitCleanException('Not a git directory.');
    }

    final gitDir = await GitDir.fromExisting('.');
    await clean(gitDir);
  } on GitCleanException catch (e) {
    print(e);
    exitCode = 1;
  } catch (e) {
    print('An unexpected error occurred: $e');
    exitCode = 1;
  }
}
