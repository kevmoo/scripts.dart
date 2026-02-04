import 'dart:async';
import 'dart:io' as io;

import 'package:io/ansi.dart';
import 'package:stack_trace/stack_trace.dart';

void printError(Object? value) {
  final message = wrapWith(value.toString(), [red, styleBold]);
  if (_testState != null) {
    print(message);
  } else {
    io.stderr.writeln(message);
  }
}

void setError({
  required Object message,
  required int exitCode,
  StackTrace? stack,
}) {
  printError(message);
  if (stack != null) {
    final trace = Trace.format(stack);
    if (_testState != null) {
      print(trace);
    } else {
      io.stderr.writeln(trace);
    }
  }

  if (_testState != null) {
    _testState!.exitCode = exitCode;
  } else {
    io.exitCode = exitCode;
  }
}

Future<int> wrappedForTesting(Future<void> Function() action) async {
  final state = _TestState();
  await runZoned(action, zoneValues: {_testStateKey: state});
  return state.exitCode;
}

_TestState? get _testState => Zone.current[_testStateKey] as _TestState?;

const _testStateKey = #_testState;

class _TestState {
  int exitCode = 0;
}
