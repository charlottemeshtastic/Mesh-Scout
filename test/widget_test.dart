import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/main.dart';

void main() {
  testWidgets('MeshScout launches', (tester) async {
    await tester.pumpWidget(const MeshScoutApp());
    expect(find.text('MeshScout'), findsOneWidget);
  });
}
