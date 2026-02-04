import 'dart:io' as io;

import 'package:io/ansi.dart';
import 'package:stack_trace/stack_trace.dart';

void printError(Object? value) {
  io.stderr.writeln(wrapWith(value.toString(), [red, styleBold]));
}

void setError({
  required Object message,
  required int exitCode,
  StackTrace? stack,
}) {
  printError(message);
  if (stack != null) {
    io.stderr.writeln(Trace.format(stack));
  }
  io.exitCode = exitCode;
}
