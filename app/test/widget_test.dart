import 'package:flutter_test/flutter_test.dart';
import 'package:freshflow/main.dart';
import 'package:freshflow/providers/app_provider.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('FreshFlow smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppProvider()),
        ],
        child: const FreshFlowApp(),
      ),
    );
    await tester.pump();

    // Verify FreshFlow title is present on login
    expect(find.text('FreshFlow'), findsWidgets);
  });
}
