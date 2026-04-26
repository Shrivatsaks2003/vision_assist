import 'package:flutter_test/flutter_test.dart';

import 'package:vision_assist/main.dart';

void main() {
  testWidgets('app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const VisionAssistApp());

    expect(find.text('Vision Assist'), findsNothing);
  });
}
