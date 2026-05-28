import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gba_emulator/main.dart';

void main() {
  testWidgets('App should render', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: GBAEmulatorApp(),
      ),
    );

    expect(find.text('游戏库'), findsOneWidget);
  });
}
