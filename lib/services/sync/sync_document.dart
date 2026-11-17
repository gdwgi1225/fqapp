import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Deterministic JSON is shared by integrity checks and local change detection.
String syncJson(Object? value) => jsonEncode(_sorted(value));
Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((e) => e.toString()).toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

const syncMaxBytes = 32 * 1024 * 1024;
final syncActorPattern = RegExp(r'^[a-f0-9]{32}$');
final syncSlotPattern = RegExp(r'^([a-f0-9]{32})\.([ab])\.json$');

class SyncVersion {
  SyncVersion(this.actor, this.counter, this.wall, this.seen, this.value);
  final String actor;
  final int counter, wall;
  final Map<String, int> seen;
  final Map<String, dynamic>? value;
  String get dot => '$actor:$counter';
  bool observes(SyncVersion other) => (seen[other.actor] ?? 0) >= other.counter;
  Map<String, dynamic> toJson() => {
    'actor': actor,
    'counter': counter,
    'wall': wall,
    'seen': seen,
    'value': value,
  };
  factory SyncVersion.fromJson(Map<String, dynamic> raw) {
    final actor = raw['actor'];
    final counter = raw['counter'], wall = raw['wall'];
    if (actor is! String ||
        !syncActorPattern.hasMatch(actor) ||
        counter is! int ||
        counter < 1 ||
        counter > 9007199254740991 ||
        wall is! int ||
        wall < 0 ||
        wall > 8640000000000000) {
      throw const FormatException('同步记录版本无效');
    }
    final seen = _vector(raw['seen']);
    if ((seen[actor] ?? 0) >= counter) {
      throw const FormatException('同步记录因果版本无效');
    }
    final value = raw['value'];
    if (value != null && value is! Map) {
      throw const FormatException('同步记录内容无效');
    }
    return SyncVersion(
      actor,
      counter,
      wall,
      seen,
      value == null ? null : Map<String, dynamic>.from(value as Map),
    );
  }
}

Map<String, int> _vector(Object? raw) {
  if (raw is! Map || raw.length > 64) {
    throw const FormatException('同步设备版本无效或设备过多');
  }
  final result = <String, int>{};
  for (final e in raw.entries) {
    if (e.key is! String ||
        !syncActorPattern.hasMatch(e.key as String) ||
        e.value is! int ||
        (e.value as int) < 0 ||
        (e.value as int) > 9007199254740991) {
      throw const FormatException('同步设备版本无效');
    }
    result[e.key as String] = e.value as int;
  }
  return result;
}

/// A causal multi-value register per entity. Concurrent deletes win over adds;
/// an explicit re-add after observing the deletion causally supersedes it.
/// Keep concurrent versions: discarding the apparent loser breaks associativity.
class SyncDocument {
  SyncDocument({
    Map<String, int>? vector,
    Map<String, List<SyncVersion>>? records,
  }) : vector = vector ?? {},
       records = records ?? {};
  final Map<String, int> vector;
  final Map<String, List<SyncVersion>> records;

  Map<String, Map<String, dynamic>> get visible => {
    for (final e in records.entries) e.key: ?_selected(e.value),
  };
  static Map<String, dynamic>? _selected(List<SyncVersion> versions) {
    if (versions.any((v) => v.value == null)) return null;
    final sorted = [...versions]
      ..sort((a, b) {
        final time = a.wall.compareTo(b.wall);
        return time != 0 ? time : a.dot.compareTo(b.dot);
      });
    return sorted.isEmpty ? null : sorted.last.value;
  }

  void change(
    String key,
    Map<String, dynamic>? value, {
    required String actor,
    required int wall,
  }) {
    if (!syncActorPattern.hasMatch(actor)) throw ArgumentError('actor');
    if ((!vector.containsKey(actor) && vector.length >= 64) ||
        (vector[actor] ?? 0) >= 9007199254740991) {
      throw const FormatException('同步设备数量或版本超过限制');
    }
    final context = Map<String, int>.from(vector);
    final next = (vector[actor] ?? 0) + 1;
    records[key] = [SyncVersion(actor, next, wall, context, value)];
    vector[actor] = next;
  }

  void merge(SyncDocument other) {
    final nextVector = Map<String, int>.from(vector);
    final nextRecords = Map<String, List<SyncVersion>>.from(records);
    for (final e in other.vector.entries) {
      if (e.value > (nextVector[e.key] ?? 0)) nextVector[e.key] = e.value;
    }
    if (nextVector.length > 64 ||
        {...records.keys, ...other.records.keys}.length > 150000) {
      throw const FormatException('同步设备或记录数量超过限制');
    }
    for (final e in other.records.entries) {
      final all = <String, SyncVersion>{};
      for (final v in [...?records[e.key], ...e.value]) {
        final prior = all[v.dot];
        if (prior != null && syncJson(prior.toJson()) != syncJson(v.toJson())) {
          throw const FormatException('同一设备版本出现不同内容，请更换设备身份');
        }
        all[v.dot] = v;
      }
      final frontier =
          all.values
              .where(
                (v) => !all.values.any((candidate) => candidate.observes(v)),
              )
              .toList()
            ..sort((a, b) => a.dot.compareTo(b.dot));
      if (frontier.length > 64) {
        throw const FormatException('同步记录并发版本过多');
      }
      nextRecords[e.key] = frontier;
    }
    vector
      ..clear()
      ..addAll(nextVector);
    records
      ..clear()
      ..addAll(nextRecords);
  }

  Map<String, dynamic> toJson() => {
    'vector': vector,
    'records': {
      for (final e in records.entries)
        e.key: e.value.map((v) => v.toJson()).toList(),
    },
  };
  SyncDocument copy() => SyncDocument.fromJson(toJson());
  factory SyncDocument.fromJson(Map<String, dynamic> raw) {
    final vector = _vector(raw['vector']);
    final records = raw['records'];
    if (records is! Map || records.length > 150000) {
      throw const FormatException('同步记录数量无效');
    }
    final result = <String, List<SyncVersion>>{};
    for (final e in records.entries) {
      if (e.key is! String ||
          (e.key as String).length > 300 ||
          e.value is! List ||
          (e.value as List).isEmpty ||
          (e.value as List).length > 64) {
        throw const FormatException('同步记录格式无效');
      }
      final values = (e.value as List)
          .map((v) => SyncVersion.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
      for (final v in values) {
        if ((vector[v.actor] ?? 0) < v.counter ||
            v.seen.entries.any((e) => (vector[e.key] ?? 0) < e.value)) {
          throw const FormatException('同步记录缺少因果上下文');
        }
      }
      final dots = values.map((v) => v.dot).toSet();
      if (dots.length != values.length ||
          values.any((v) => values.any((candidate) => candidate.observes(v)))) {
        throw const FormatException('同步记录因果前沿无效');
      }
      result[e.key as String] = values;
    }
    return SyncDocument(vector: vector, records: result);
  }
}

class SyncSlot {
  SyncSlot(this.device, this.sequence, this.document);
  final String device;
  final int sequence;
  final SyncDocument document;
  String get filename => '$device.${sequence.isEven ? 'a' : 'b'}.json';
  Uint8List encode() {
    final body = {
      'format': 'fqapp.multi-device-sync',
      'version': 1,
      'device': device,
      'sequence': sequence,
      'document': document.toJson(),
    };
    final bytes = utf8.encode(
      syncJson({
        'body': body,
        'sha256': sha256.convert(utf8.encode(syncJson(body))).toString(),
      }),
    );
    if (bytes.length > syncMaxBytes) {
      throw const FormatException('同步快照超过32MB，已保留本地记录');
    }
    return Uint8List.fromList(bytes);
  }

  factory SyncSlot.decode(Uint8List bytes, String filename) {
    if (bytes.length > syncMaxBytes) throw const FormatException('同步文件过大');
    final outer = jsonDecode(utf8.decode(bytes)) as Map;
    final body = Map<String, dynamic>.from(outer['body'] as Map);
    if (sha256.convert(utf8.encode(syncJson(body))).toString() !=
        outer['sha256']) {
      throw const FormatException('同步文件校验失败，可能尚未写完');
    }
    final device = body['device'], sequence = body['sequence'];
    if (body['format'] != 'fqapp.multi-device-sync' ||
        body['version'] != 1 ||
        device is! String ||
        !syncActorPattern.hasMatch(device) ||
        sequence is! int ||
        sequence < 1 ||
        sequence > 9007199254740991) {
      throw const FormatException('同步文件格式不兼容');
    }
    final slot = SyncSlot(
      device,
      sequence,
      SyncDocument.fromJson(Map<String, dynamic>.from(body['document'] as Map)),
    );
    if (filename != slot.filename) throw const FormatException('同步文件身份不匹配');
    return slot;
  }
}
