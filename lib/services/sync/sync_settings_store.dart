import 'package:flutter/foundation.dart';

class WebDavSyncPreview {
  const WebDavSyncPreview({
    required this.revision,
    required this.cloudShelf,
    required this.cloudHistory,
    required this.cloudEpisodes,
    required this.localShelf,
    required this.localHistory,
    required this.localEpisodes,
    required this.mergedShelf,
    required this.mergedHistory,
    required this.mergedEpisodes,
    required this.localRemovals,
  });

  final String revision;
  final int cloudShelf, cloudHistory, cloudEpisodes;
  final int localShelf, localHistory, localEpisodes;
  final int mergedShelf, mergedHistory, mergedEpisodes;
  final int localRemovals;
}

abstract interface class WebDavSyncSettings {
  bool get needsWebDavReview;
  Future<WebDavSyncPreview> previewWebDav(Map<String, String> config);
}

abstract interface class SyncSettingsStore implements Listenable {
  Map<String, String> get config;
  Map<String, String> configFor(String provider);
  bool get enabled;
  bool get busy;
  String get status;
  DateTime? get lastSuccess;
  Future<void> configure(Map<String, String> config);
  Future<void> setAutoSync(bool enabled);
  Future<void> sync();
}
