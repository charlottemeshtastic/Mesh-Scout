import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'radio_notifier.dart';
import 'ble_service.dart';

class RadioDetails {
  const RadioDetails({required this.name, required this.txPower, required this.maxPower,
    required this.frequency, required this.bandwidth, required this.sf, required this.cr,
    required this.millivolts, this.usedKb, this.totalKb, required this.board, required this.firmware});
  final String name, board, firmware;
  final int txPower, maxPower, sf, cr, millivolts;
  final int? usedKb, totalKb;
  final double frequency, bandwidth;
  factory RadioDetails.parse(List<int> self, List<int> device, List<int> battery) {
    if (self.length < 58 || self.length > 90 || self.first != 5 || device.length < 80 || device.first != 13 ||
        ![3, 11].contains(battery.length) || battery.first != 12) throw const FormatException('Invalid radio status response.');
    final data = ByteData.sublistView(Uint8List.fromList(self));
    final batt = ByteData.sublistView(Uint8List.fromList(battery));
    String text(List<int> bytes) => utf8.decode(bytes.takeWhile((b) => b != 0).toList());
    final power = self[2] > 127 ? self[2] - 256 : self[2];
    final max = self[3];
    if (max > 40 || power < -9 || power > max) throw const FormatException('Invalid radio power range.');
    return RadioDetails(name: text(self.sublist(58)), txPower: power, maxPower: max,
      frequency: data.getUint32(48, Endian.little) / 1000, bandwidth: data.getUint32(52, Endian.little) / 1000,
      sf: self[56], cr: self[57], millivolts: batt.getUint16(1, Endian.little),
      usedKb: battery.length == 11 ? batt.getUint32(3, Endian.little) : null,
      totalKb: battery.length == 11 ? batt.getUint32(7, Endian.little) : null,
      board: text(device.sublist(20, 60)), firmware: text(device.sublist(60, 80)));
  }
}
List<int> radioNameCommand(String name) {
  final value = name.trim();
  final bytes = utf8.encode(value);
  if (bytes.isEmpty || bytes.length > 31 || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) throw const FormatException('Use 1–31 UTF-8 bytes without control characters.');
  return [8, ...bytes];
}
List<int> radioPowerCommand(int power, int maximum) {
  if (maximum > 40 || power < -9 || power > maximum) throw const FormatException('Power is outside the radio range.');
  return [12, power & 255];
}

final radioControlsProvider = NotifierProvider<RadioControls, ControlState>(RadioControls.new);
class ControlState {
  const ControlState({this.details, this.busy = false, this.notice});
  final RadioDetails? details;
  final bool busy;
  final String? notice;
}
class RadioControls extends Notifier<ControlState> {
  @override
  ControlState build() {
    ref.listen(radioProvider.select((s) => s.phase), (_, next) {
      if (next != RadioPhase.ready) state = const ControlState();
    });
    return const ControlState();
  }
  Future<void> refresh() => _perform(null);
  Future<void> setName(String value) async {
    try { await _perform(radioNameCommand(value)); }
    catch (e) { state = ControlState(details: state.details, notice: e.toString()); }
  }
  Future<void> setPower(int value) async {
    final details = state.details;
    if (details == null) return;
    try { await _perform(radioPowerCommand(value, details.maxPower)); }
    catch (e) { state = ControlState(details: state.details, notice: e.toString()); }
  }
  Future<void> syncClock() async {
    final stamp = ByteData(4)..setUint32(0, DateTime.now().millisecondsSinceEpoch ~/ 1000, Endian.little);
    await _perform([6, ...stamp.buffer.asUint8List()]);
  }
  Future<void> _perform(List<int>? change) async {
    final radio = ref.read(radioProvider.notifier);
    if (state.busy || !radio.beginControls()) return;
    final token = radio.sessionToken;
    final previous = state.details;
    state = ControlState(details: previous, busy: true);
    try {
      if (change != null) await radio.messageCommand(change, {0}, control: true);
      final self = await radio.messageCommand(appStart, {5}, control: true);
      final device = await radio.messageCommand(deviceQuery, {13}, control: true);
      final battery = await radio.messageCommand([20], {12}, control: true);
      final details = RadioDetails.parse(self, device, battery);
      if (ref.mounted && radio.sessionToken == token) state = ControlState(details: details,
        notice: change == null ? 'Status refreshed.' : 'Radio accepted the change; status refreshed.');
    } catch (e) {
      if (ref.mounted && radio.sessionToken == token) state = ControlState(details: previous,
        notice: 'Request failed or result uncertain. Reconnect before retrying. $e');
    } finally { if (ref.mounted) radio.endControls(token); }
  }
}
class RadioControlsPanel extends ConsumerWidget {
  const RadioControlsPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(radioControlsProvider);
    final radio = ref.watch(radioProvider);
    final actions = ref.read(radioControlsProvider.notifier);
    final ready = radio.phase == RadioPhase.ready && !state.busy && !radio.syncing && !radio.messagingBusy && !radio.channelsLoading;
    final d = state.details;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Radio status and controls'),
      OutlinedButton(onPressed: ready ? actions.refresh : null, child: const Text('Refresh radio status')),
      if (state.busy) const LinearProgressIndicator(),
      if (state.notice != null) Text(state.notice!),
      if (d != null) ...[
        Text('${d.name} · ${d.board} · firmware ${d.firmware}'),
        Text('Battery ${(d.millivolts / 1000).toStringAsFixed(3)} V${d.totalKb == null ? "" : " · storage ${d.usedKb}/${d.totalKb} KB"}'),
        Text('${d.frequency.toStringAsFixed(3)} MHz · ${d.bandwidth} kHz · SF ${d.sf} · CR ${d.cr} · TX ${d.txPower} dBm (max ${d.maxPower})'),
        OutlinedButton(onPressed: ready ? () async {
          final name = await showDialog<String>(context: context, builder: (_) => _RadioValueDialog(title: 'Change radio name', value: d.name));
          if (name != null) await actions.setName(name);
        } : null, child: const Text('Change radio name')),
        OutlinedButton(onPressed: ready ? () async {
          final power = await showDialog<String>(context: context, builder: (_) => _RadioValueDialog(title: 'Set TX power (−9 to ${d.maxPower} dBm)', value: d.txPower.toString(), numeric: true));
          if (power != null) {
            final value = int.tryParse(power);
            if (value != null) await actions.setPower(value);
            else if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a whole-number power value.')));
          }
        } : null, child: const Text('Set transmit power')),
      ],
      OutlinedButton(onPressed: ready ? () async {
        final yes = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Sync radio clock?'),
          content: const Text('Use this phone’s current time. Firmware may reject moving its clock backwards.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sync clock'))]));
        if (yes == true) await actions.syncClock();
      } : null, child: const Text('Sync radio clock')),
    ]);
  }
}
class _RadioValueDialog extends StatefulWidget {
  const _RadioValueDialog({required this.title, required this.value, this.numeric = false});
  final String title, value;
  final bool numeric;
  @override
  State<_RadioValueDialog> createState() => _RadioValueState();
}
class _RadioValueState extends State<_RadioValueDialog> {
  late final text = TextEditingController(text: widget.value);
  @override
  void dispose() { text.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AlertDialog(title: Text(widget.title),
    content: TextField(controller: text, keyboardType: widget.numeric ? const TextInputType.numberWithOptions(signed: true) : TextInputType.text),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Apply'))]);
}
