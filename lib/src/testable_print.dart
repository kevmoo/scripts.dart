import 'dart:async';
import 'dart:io' as io;

import 'package:io/ansi.dart';
import 'package:stack_trace/stack_trace.dart';

void printError(Object value) {
  _theState.printError(value, boldRed: true);
}

void setError({
  required Object message,
  required int exitCode,
  StackTrace? stack,
}) {
  printError(message);
  if (stack != null) {
    final trace = Trace.format(stack);
    _theState.doPrint(trace);
  }

  _theState.exitCode = exitCode;
}

Future<int> wrappedForTesting(Future<void> Function() action) async {
  final state = _TestState();
  await runZoned(action, zoneValues: {_testStateKey: state});
  return state.exitCode;
}

_HelperState get _theState =>
    Zone.current[_testStateKey] as _HelperState? ?? _runtimeState;

const _testStateKey = #_testState;

abstract final class _HelperState {
  int exitCode = 0;
  void printError(Object value, {bool boldRed = false});
  void doPrint(Object value);
}

final _runtimeState = _RuntimeState();

final class _RuntimeState extends _HelperState {
  @override
  void printError(Object value, {bool boldRed = false}) {
    final message = boldRed
        ? wrapWith(value.toString(), [red, styleBold])!
        : value.toString();
    doPrint(message);
  }

  @override
  void doPrint(Object value) {
    io.stderr.writeln(value);
  }
}

final class _TestState extends _HelperState {
  @override
  void printError(Object value, {bool boldRed = false}) {
    print(value.toString());
  }

  @override
  void doPrint(Object value) {
    print(value.toString());
  }
}
