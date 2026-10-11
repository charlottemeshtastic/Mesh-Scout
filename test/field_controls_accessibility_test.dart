import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/common/mesh_data.dart';
import 'package:mesh_scout/features/mapping/field_tools.dart';
import 'package:mesh_scout/features/mapping/smart_ping.dart';
import 'package:mesh_scout/features/nodes/repeater_details.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/sync/sync_controls.dart';

class EmptyNotes extends FieldNotes {
  @override
  Future<List<Map<String,dynamic>>> build() async => [];
}
class EmptyRepeaters extends RepeaterDetails {
  @override
  Future<List<Map<String,String>>> build() async => [];
}
class NoRadio extends RadioNotifier {
  @override
  RadioState build() => const RadioState();
}
void main() {
  testWidgets('new field controls remain scrollable at 200 percent text', (tester) async {
    tester.view.physicalSize=const Size(320,700);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides:[fieldNotesProvider.overrideWith(EmptyNotes.new),
      repeaterDetailsProvider.overrideWith(EmptyRepeaters.new),radioProvider.overrideWith(NoRadio.new)],
      child:MaterialApp(builder:(context,child) => MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:const TextScaler.linear(2)),child:child!),
        home:const Scaffold(body:SingleChildScrollView(child:Column(children:[SmartPingControls(),CloudSyncControls()]))))));
    await tester.pumpAndSettle();expect(tester.takeException(),isNull);
    expect(find.text('Smart discovery pinging'),findsOneWidget);
    await tester.scrollUntilVisible(find.text('Export last conflict details'),250,scrollable:find.byType(Scrollable).first);
    expect(tester.takeException(),isNull);
  });
  testWidgets('repeater details remain usable with large text and full keys', (tester) async {
    tester.view.physicalSize=const Size(320,700);tester.view.devicePixelRatio=1;addTearDown(tester.view.reset);
    final contact=MeshContact(key:'a'*64,name:'Test repeater',type:2,lastAdvert:null,latitude:null,longitude:null);
    await tester.pumpWidget(ProviderScope(overrides:[repeaterDetailsProvider.overrideWith(EmptyRepeaters.new)],
      child:MaterialApp(builder:(context,child) => MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:const TextScaler.linear(2)),child:child!),
        home:RepeaterDetailsScreen(contact:contact))));
    await tester.pumpAndSettle();expect(tester.takeException(),isNull);
    await tester.scrollUntilVisible(find.text('Save repeater information'),250,scrollable:find.byType(Scrollable).first);
    expect(tester.takeException(),isNull);
  });
}
