import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/radio/ble_service.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/main.dart';

import 'radio_test.dart' show FakeBle;

class CountingBle extends FakeBle {
  int authorizationCalls = 0;

  @override
  Future<void> authorize() async {
    authorizationCalls++;
    await super.authorize();
  }
}

void main() {
  late CountingBle ble;
  late ProviderContainer container;

  Future<void> launch(WidgetTester tester) async {
    // Create stream controllers in the widget test's fake-async zone.
    ble = CountingBle();
    container = ProviderContainer(
      overrides: [bleServiceProvider.overrideWithValue(ble)],
    );
    addTearDown(() {
      container.dispose();
      unawaited(ble.devices.close());
      unawaited(ble.links.close());
      unawaited(ble.packets.close());
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MeshScoutApp(mapContent: ColoredBox(color: Colors.black)),
      ),
    );
  }

  Future<void> select(WidgetTester tester, int tab) async {
    await tester.tap(find.byType(NavigationDestination).at(tab));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> identify(WidgetTester tester) async {
    // Stream cancellation may complete in the root async zone. Drive the
    // service there, then pump the rendered state in the widget-test zone.
    await tester.runAsync(() async {
      final actions = container.read(radioProvider.notifier);
      await actions.scan();
      const device = RadioDevice('radio', 'Companion', -55);
      ble.devices.add(device);
      await actions.stopScan();
      await actions.connect(device);
      ble.links.add(RadioLink.connected);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
  }

  testWidgets('all six tabs navigate without requesting Bluetooth permissions',
      (tester) async {
    await launch(tester);
    expect(find.text('MeshScout'), findsOneWidget);
    expect(find.text('Radio disconnected'), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(6));
    await select(tester, 1);
    expect(find.text('Scan for radios'), findsOneWidget);
    await select(tester, 2);
    expect(find.text('Node discovery is coming soon'), findsOneWidget);
    await select(tester, 3);
    expect(find.text('No coverage observations yet'), findsOneWidget);
    await select(tester, 4);
    expect(find.text('No mapping sessions yet'), findsOneWidget);
    await select(tester, 5);
    expect(find.text('Bluetooth radios'), findsOneWidget);
    await tester.tap(find.text('Bluetooth radios'));
    await tester.pumpAndSettle();
    expect(find.text('Scan for radios'), findsOneWidget);
    expect(ble.authorizationCalls, 0);
  });

  testWidgets('mapping remains disabled even after MeshCore identification',
      (tester) async {
    await launch(tester);
    await identify(tester);
    await tester.pumpAndSettle();
    expect(container.read(radioProvider).phase, RadioPhase.ready);
    expect(find.text('MeshCore companion connected'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byWidgetPredicate((widget) => widget is FilledButton)).onPressed,
        isNull);
    await select(tester, 3);
    expect(tester.widget<FilledButton>(find.byWidgetPredicate((widget) => widget is FilledButton)).onPressed,
        isNull);
    expect(find.textContaining('GPS and coverage recording'), findsOneWidget);
    expect(ble.writes, [appStart, deviceQuery]);
  });

  testWidgets('leaving Radios cancels scanning but keeps a ready foreground link',
      (tester) async {
    await launch(tester);
    await select(tester, 1);
    await tester.tap(find.text('Scan for radios'));
    await tester.pumpAndSettle();
    expect(ble.devices.hasListener, isTrue);
    await select(tester, 2);
    expect(ble.devices.hasListener, isFalse);
    expect(container.read(radioProvider).phase, RadioPhase.idle);
    await identify(tester);
    await tester.pumpAndSettle();
    await select(tester, 1);
    await select(tester, 0);
    expect(container.read(radioProvider).phase, RadioPhase.ready);
    expect(ble.links.hasListener, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(ble.links.hasListener, isFalse);
    expect(find.text('Radio disconnected'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('connection status opens Radios and reports permission failures',
      (tester) async {
    await launch(tester);
    await tester.tap(find.text('Radio disconnected'));
    await tester.pumpAndSettle();
    ble.authorizationFailure = RadioFailure.denied;
    await tester.tap(find.text('Scan for radios'));
    await tester.pumpAndSettle();
    expect(find.text('Radio unavailable · tap to retry'), findsOneWidget);
    expect(find.textContaining('Permission denied'), findsOneWidget);
    expect(ble.scanCalls, 0);
  });

  testWidgets('tabs fit a narrow screen with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    for (var tab = 0; tab < 6; tab++) {
      await select(tester, tab);
      expect(tester.takeException(), isNull);
    }
  });
}
