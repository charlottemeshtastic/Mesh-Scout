import 'dart:async';
import 'package:mesh_scout/features/shell/help_screen.dart';
import 'package:mesh_scout/features/alerts/message_alerts.dart';
import 'package:mesh_scout/features/messages/messages.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/radio/ble_service.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/main.dart';

import 'radio_test.dart' show FakeBle;
import 'mapping_test.dart' show FakeMapping;
import 'package:mesh_scout/features/mapping/mapping_notifier.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';

class CountingBle extends FakeBle {
  int authorizationCalls = 0;

  @override
  Future<void> authorize() async {
    authorizationCalls++;
    await super.authorize();
  }
}

class LoadedMessages extends Messages {
  @override
  MessageState build() => const MessageState(loaded: true);

  @override
  Future<void> load({bool recover = false}) async {}
}

class OpenMessageAlerts extends SilentAlerts {
  bool open = true;
  @override
  Future<bool> consumeOpen() async {
    final value = open;
    open = false;
    return value;
  }
}

void main() {
  late CountingBle ble;
  late ProviderContainer container;
  late FakeMapping mapping;

  Future<void> launch(WidgetTester tester, {AlertService? alerts}) async {
    // Create stream controllers in the widget test's fake-async zone.
    ble = CountingBle();
    mapping = FakeMapping();
    container = ProviderContainer(
      overrides: [
        if (alerts != null) alertServiceProvider.overrideWithValue(alerts),
        if (alerts != null) messagesProvider.overrideWith(LoadedMessages.new),
        bleServiceProvider.overrideWithValue(ble),
        mappingServiceProvider.overrideWithValue(mapping)
      ],
    );
    addTearDown(() {
      container.dispose();
      unawaited(mapping.updates.close());
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
    await tester.pumpAndSettle();
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

  testWidgets(
      'notification opens Messages once and preserves an existing draft',
      (tester) async {
    final alerts = OpenMessageAlerts();
    await launch(tester, alerts: alerts);
    await tester.pumpAndSettle();
    expect(find.byType(MessagesScreen), findsOneWidget);
    final composer = find.byWidgetPredicate((w) =>
        w is TextField &&
        (w.decoration?.labelText?.startsWith('Direct message') ?? false));
    await tester.enterText(composer, 'draft stays');
    alerts.open = true;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.byType(MessagesScreen), findsOneWidget);
    expect(find.text('draft stays'), findsOneWidget);
  });
  testWidgets('all six tabs navigate without requesting Bluetooth permissions',
      (tester) async {
    await launch(tester);
    expect(find.text('MeshScout'), findsOneWidget);
    expect(find.text('Radio disconnected'), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(6));
    await select(tester, 1);
    expect(find.text('Scan for radios'), findsOneWidget);
    await select(tester, 2);
    expect(find.text('Refresh from radio'), findsOneWidget);
    await select(tester, 3);
    expect(find.textContaining('No coverage observations yet'), findsOneWidget);
    await select(tester, 4);
    expect(find.textContaining('No mapping sessions yet'), findsOneWidget);
    await select(tester, 5);
    expect(find.text('Bluetooth radios'), findsOneWidget);
    await tester.tap(find.text('Bluetooth radios'));
    await tester.pumpAndSettle();
    expect(find.text('Scan for radios'), findsOneWidget);
    expect(ble.authorizationCalls, 0);
  });

  testWidgets('GPS route records, saves and reopens from History',
      (tester) async {
    await launch(tester);
    expect(mapping.authorizations, 0);
    await tester.tap(find.text('Start Mapping').first);
    await tester.pumpAndSettle();
    expect(mapping.authorizations, 1);
    expect(find.text('Stop and save route'), findsOneWidget);
    mapping.updates.add(GpsPoint(35.2, -80.8, 5, DateTime.now()));
    await tester.pumpAndSettle();
    expect(find.text('1 GPS points · 0 LoRa observations'), findsOneWidget);
    await tester.tap(find.text('Stop and save route'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await select(tester, 4);
    expect(find.textContaining('1 GPS points'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.route));
    await tester.pumpAndSettle();
    expect(container.read(mappingProvider).selected?.points.length, 1);
    expect(find.text('Start Mapping'), findsOneWidget);
  });

  testWidgets(
      'app switching preserves an identified link; explicit disconnect releases it',
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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Cancellation completes across the stream and widget-test async zones.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
    expect(container.read(radioProvider).phase, RadioPhase.ready);
    expect(ble.links.hasListener, isTrue);
    // Resume must continue showing the actual live connection.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('MeshCore companion connected'), findsOneWidget);
    await tester
        .runAsync(() => container.read(radioProvider.notifier).disconnect());
    await tester.pumpAndSettle();
    expect(ble.links.hasListener, isFalse);
    expect(find.text('Radio disconnected'), findsOneWidget);
  });

  testWidgets('a discovered radio can connect before the scan deadline',
      (tester) async {
    await launch(tester);
    await select(tester, 1);
    await tester.tap(find.text('Scan for radios'));
    await tester.pumpAndSettle();
    ble.devices.add(const RadioDevice('radio', 'Companion', -55));
    await tester.pumpAndSettle();
    expect(container.read(radioProvider).phase, RadioPhase.scanning);
    await tester.tap(find.text('Connect'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(ble.devices.hasListener, isFalse);
    expect(ble.links.hasListener, isTrue);
    expect(container.read(radioProvider).phase, RadioPhase.connecting);
    await tester
        .runAsync(() => container.read(radioProvider.notifier).disconnect());
    await tester.pumpAndSettle();
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
  testWidgets('Messages and guidance fit a small screen at 200 percent text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester, alerts: OpenMessageAlerts());
    await tester.scrollUntilVisible(find.text('All conversations'), 180, scrollable: find.byType(Scrollable).last);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    await tester.pumpAndSettle();
    expect(find.text('1. Connect your radio'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Privacy and network access'), 180);
    expect(tester.takeException(), isNull);
  });

}
