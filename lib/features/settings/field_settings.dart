import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Field-recording preferences persisted with the other app settings.
class FieldSettings {
  const FieldSettings(
      {this.autoStopParked = true,
      this.parkedMinutes = 10,
      this.aircraftGuard = true,
      this.disconnectAlert = true,
      this.allCoverage = false,
      this.recentCoverageOnly = false,
      this.recentCoverageDays = 30,
      this.groupNodes = true,
      this.matchPreset = false,
      this.guideSeen = false});

  /// Whether a recording stops and saves after the phone stays in place.
  final bool autoStopParked;

  /// Minutes without moving more than [parkedRadiusMetres] before auto-stop.
  final int parkedMinutes;

  /// Whether fixes above aircraft altitude or speed end the recording.
  final bool aircraftGuard;

  /// Whether an unexpected radio link loss plays an alert.
  final bool disconnectAlert;

  /// Whether the map shows measured cells from every saved session.
  final bool allCoverage;

  /// Whether saved-coverage cells older than [recentCoverageDays] are hidden.
  final bool recentCoverageOnly;

  /// Age limit in days for [recentCoverageOnly].
  final int recentCoverageDays;

  /// Whether nodes sharing a location collapse into one map marker.
  final bool groupNodes;

  /// Whether History and saved coverage show only the connected radio preset.
  final bool matchPreset;

  /// Whether the first-run quick guide has been shown.
  final bool guideSeen;

  static const parkedRadiusMetres = 30.0;
  static const parkedChoices = [5, 10, 15, 30];
  static const recentChoices = [7, 30, 90, 365];

  FieldSettings copyWith(
          {bool? autoStopParked,
          int? parkedMinutes,
          bool? aircraftGuard,
          bool? disconnectAlert,
          bool? allCoverage,
          bool? recentCoverageOnly,
          int? recentCoverageDays,
          bool? groupNodes,
          bool? matchPreset,
          bool? guideSeen}) =>
      FieldSettings(
          autoStopParked: autoStopParked ?? this.autoStopParked,
          parkedMinutes: parkedMinutes ?? this.parkedMinutes,
          aircraftGuard: aircraftGuard ?? this.aircraftGuard,
          disconnectAlert: disconnectAlert ?? this.disconnectAlert,
          allCoverage: allCoverage ?? this.allCoverage,
          recentCoverageOnly: recentCoverageOnly ?? this.recentCoverageOnly,
          recentCoverageDays: recentCoverageDays ?? this.recentCoverageDays,
          groupNodes: groupNodes ?? this.groupNodes,
          matchPreset: matchPreset ?? this.matchPreset,
          guideSeen: guideSeen ?? this.guideSeen);

  Map<String, Object> toJson() => {
        'autoStopParked': autoStopParked,
        'parkedMinutes': parkedMinutes,
        'aircraftGuard': aircraftGuard,
        'disconnectAlert': disconnectAlert,
        'allCoverage': allCoverage,
        'recentCoverageOnly': recentCoverageOnly,
        'recentCoverageDays': recentCoverageDays,
        'groupNodes': groupNodes,
        'matchPreset': matchPreset,
        'guideSeen': guideSeen,
      };

  /// Reads saved values, keeping defaults for anything missing or invalid.
  factory FieldSettings.fromJson(Map<String, dynamic> json) {
    const defaults = FieldSettings();
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    int choice(String key, List<int> allowed, int fallback) =>
        allowed.contains(json[key]) ? json[key] as int : fallback;
    return FieldSettings(
        autoStopParked: flag('autoStopParked', defaults.autoStopParked),
        parkedMinutes:
            choice('parkedMinutes', parkedChoices, defaults.parkedMinutes),
        aircraftGuard: flag('aircraftGuard', defaults.aircraftGuard),
        disconnectAlert: flag('disconnectAlert', defaults.disconnectAlert),
        allCoverage: flag('allCoverage', defaults.allCoverage),
        recentCoverageOnly:
            flag('recentCoverageOnly', defaults.recentCoverageOnly),
        recentCoverageDays: choice(
            'recentCoverageDays', recentChoices, defaults.recentCoverageDays),
        groupNodes: flag('groupNodes', defaults.groupNodes),
        matchPreset: flag('matchPreset', defaults.matchPreset),
        guideSeen: flag('guideSeen', defaults.guideSeen));
  }
}

final fieldSettingsProvider =
    NotifierProvider<FieldSettingsNotifier, FieldSettings>(
        FieldSettingsNotifier.new);

class FieldSettingsNotifier extends Notifier<FieldSettings> {
  @override
  FieldSettings build() => const FieldSettings();

  /// Replaces the settings; preferences persist the change.
  void set(FieldSettings value) => state = value;

  /// Applies one change to the current settings.
  void update(FieldSettings Function(FieldSettings) change) =>
      state = change(state);
}

/// Requests the first-run guide once saved preferences confirm it is unseen.
final firstRunGuideProvider =
    NotifierProvider<FirstRunGuide, bool>(FirstRunGuide.new);

class FirstRunGuide extends Notifier<bool> {
  @override
  bool build() => false;

  /// Marks the guide as pending (true) or handled (false).
  void set(bool value) => state = value;
}
