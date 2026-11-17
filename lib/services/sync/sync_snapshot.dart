import 'dart:convert';
import 'dart:typed_data';
import '../../models/library_backup.dart';
import '../../models/shelf_identity.dart';
import 'sync_document.dart';

class SyncSnapshot {
  SyncSnapshot(this.values);
  final Map<String, Map<String, dynamic>> values;
  // These snapshots merge the portable Fanqie records. The WebDAV exchange
  // preserves other sources in the shared backup.
  static bool _legacySource(Map<dynamic, dynamic> record) =>
      record['source'] == null || record['source'] == ShelfIdentity.fanqie;

  factory SyncSnapshot.fromBackup(LibraryBackup backup) {
    final raw = jsonDecode(utf8.decode(backup.encode())) as Map;
    final values = <String, Map<String, dynamic>>{};
    for (final item in raw['shelf'] as List) {
      final v = Map<String, dynamic>.from(item as Map);
      if (!_legacySource(v)) continue;
      values['s|${v['kind']}|${v['seriesId'] ?? v['id']}'] = v;
    }
    for (final item in raw['history'] as List) {
      final v = Map<String, dynamic>.from(item as Map);
      if (!_legacySource(v)) continue;
      values['h|${v['kind']}|${v['id']}'] = v;
    }
    for (final item in raw['watched'] as List) {
      for (final e in (item['episodes'] as Map).entries) {
        values['w|${item['id']}|${e.key}'] = {'at': e.value};
      }
    }
    return SyncSnapshot(values);
  }
  Map<String, Map<String, dynamic>> domain(String prefix) => {
    for (final e in values.entries)
      if (e.key.startsWith(prefix)) e.key: e.value,
  };
  bool sameDomain(SyncSnapshot other, String prefix) =>
      syncJson(domain(prefix)) == syncJson(other.domain(prefix));
  void replaceDomain(SyncSnapshot other, String prefix) {
    values.removeWhere((k, _) => k.startsWith(prefix));
    values.addAll(other.domain(prefix));
  }

  static void validateKey(String key, Map<String, dynamic>? value) {
    final parts = key.split('|');
    final id = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');
    const kinds = {'book', 'audio', 'video', 'manju', 'manga'};
    if (parts.length != 3 ||
        !{'s', 'h', 'w'}.contains(parts[0]) ||
        !id.hasMatch(parts[2]) ||
        (parts[0] == 'w'
            ? !id.hasMatch(parts[1])
            : !kinds.contains(parts[1]))) {
      throw const FormatException('同步记录标识无效');
    }
    if (value == null) return;
    if (parts[0] == 'w') {
      final at = value['at'];
      if (at is! int || at < 0 || at > 8640000000000000) {
        throw const FormatException('已看记录时间无效');
      }
    } else if (value['kind'] != parts[1] ||
        (parts[0] == 's' ? value['seriesId'] ?? value['id'] : value['id']) !=
            parts[2]) {
      throw const FormatException('同步记录内容与标识不一致');
    }
  }

  factory SyncSnapshot.fromDocument(SyncDocument document) {
    for (final e in document.records.entries) {
      for (final v in e.value) {
        validateKey(e.key, v.value);
      }
    }
    final result = SyncSnapshot({
      for (final entry in document.visible.entries)
        if (_legacySource(entry.value)) entry.key: entry.value,
    });
    // Reuse the portable-backup validator before any remote data reaches Hive.
    return SyncSnapshot.fromBackup(result.toBackup());
  }
  LibraryBackup toBackup() {
    final watched = <String, Map<String, int>>{};
    for (final e in values.entries.where((e) => e.key.startsWith('w|'))) {
      final p = e.key.split('|');
      (watched[p[1]] ??= {})[p[2]] = e.value['at'] as int;
    }
    final raw = {
      'format': 'fqapp.library-backup',
      'version': 1,
      'createdAt': 0,
      'shelf': domain('s|').values.toList(),
      'history': domain('h|').values.toList(),
      'watched': [
        for (final e in watched.entries) {'id': e.key, 'episodes': e.value},
      ],
      'excludedLocalRecords': 0,
    };
    return LibraryBackup.decode(
      Uint8List.fromList(utf8.encode(jsonEncode(raw))),
    );
  }
}
