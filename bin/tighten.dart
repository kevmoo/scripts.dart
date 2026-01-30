import 'dart:io';

import 'package:kevmoo_scripts/src/tighten.dart';

void main(List<String> args) async {
  try {
    await tighten();
  } on TightenException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } catch (e, stack) {
    stderr.writeln('An unexpected error occurred: $e');
    stderr.writeln(stack);
    exitCode = 1;
  }
}
