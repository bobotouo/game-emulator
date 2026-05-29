import 'dart:developer' as developer;

/// Audio diagnostics — always uses [print] so `flutter run` / Xcode console show lines.
void logAudio(String message) {
  const tag = '[GBA-Audio]';
  // ignore: avoid_print
  print('$tag $message');
  developer.log(message, name: 'GBA-Audio');
}
