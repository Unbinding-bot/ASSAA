import 'package:flutter_test/flutter_test.dart';
import 'package:assaa/main.dart';

void main() {
  testWidgets('App boots to the Map tab with a disconnected status',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ASSAA());

    expect(find.text('ASSAA'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
  });
}