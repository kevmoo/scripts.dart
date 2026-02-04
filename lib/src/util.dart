import 'package:io/ansi.dart';

void printError(Object? value) {
  print(wrapWith(value.toString(), [red, styleBold]));
}
