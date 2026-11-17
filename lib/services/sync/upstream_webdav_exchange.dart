import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../models/library_backup.dart';
import '../../models/shelf_identity.dart';
import '../../models/webdav_sync_document.dart';
import '../shelf_store.dart';
import '../webdav_client.dart';
import 'sync_document.dart';
import 'sync_snapshot.dart';
import 'sync_transport.dart';

/// The public file keeps the upstream wire format. The private file is a
/// conditional-write journal for the version information upstream cannot keep.
class UpstreamWebDavExchange {
  UpstreamWebDavExchange(this.publicFile, this.journal);

  factory UpstreamWebDavExchange.connect(WebDavConfig config) =>
      UpstreamWebDavExchange(
        WebDavClient(config),
        WebDavClient(config, forSyncMetadata: true),
      );

  final WebDavClient publicFile;
  final WebDavClient journal;
  static const _externalActor = '00000000000000000000000000000000';

  Future<({SyncDocument document, LibraryBackup? remote, String revision})>
  preview(SyncDocument local, {bool requireJournal = false}) async {
    final state = await _read(requireJournal: requireJournal);
    return (
      document: _merge(state, local),
      remote: state.publicDocument?.backup,
      revision: syncJson([state.publicFile.etag, state.journal.etag]),
    );
  }

  Future<SyncDocument> sync(
    SyncDocument local, {
    bool requireJournal = false,
  }) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final state = await _read(requireJournal: requireJournal);
      final pending = state.pending;
      if (pending != null) {
        final hash = _hash(state.publicFile.bytes);
        var journalEtag = state.journal.etag;
        if (hash != pending.targetHash) {
          if (hash != pending.baseHash) _interrupted();
          // Change the journal ETag before helping finish another writer's
          // proposal. The original writer can no longer cancel it on a 412.
          final adopted = _Proposal(
            pending.baseHash,
            pending.publicBytes,
            pending.document,
          );
          final reservation = _encode(state.committed, adopted);
          if (!await journal.write(reservation, journalEtag)) continue;
          final saved = await journal.read();
          if (_hash(saved.bytes) != _hash(reservation)) continue;
          journalEtag = saved.etag;
          final written = await publicFile.write(
            pending.publicBytes,
            state.publicFile.etag,
          );
          if (!written) continue;
        }
        if (!await journal.write(
          _encode(pending.document, null),
          journalEtag,
        )) {
          continue;
        }
        // A pending proposal may have come from a different device. The next
        // iteration incorporates our local changes against its committed state.
        continue;
      }

      final merged = _merge(state, local);
      final projection = _project(merged, state.publicDocument);
      WebDavSyncDocument.decode(projection);
      final current = state.publicFile.bytes;
      if (_sameProjection(projection, current)) {
        if (syncJson(merged.toJson()) != syncJson(state.committed?.toJson()) &&
            !await journal.write(_encode(merged, null), state.journal.etag)) {
          continue;
        }
        return merged;
      }

      final proposal = _Proposal(_hash(current), projection, merged);
      final reservation = _encode(state.committed, proposal);
      if (!await journal.write(reservation, state.journal.etag)) {
        continue;
      }
      final saved = await journal.read();
      if (_hash(saved.bytes) != _hash(reservation)) {
        continue;
      }
      if (!await publicFile.write(projection, state.publicFile.etag)) {
        final observed = await publicFile.read();
        if (_hash(observed.bytes) == proposal.targetHash) continue;
        // A definite precondition failure leaves the old public revision
        // untouched by this writer. Remove only our exact journal proposal.
        await journal.write(_encode(state.committed, null), saved.etag);
        continue;
      }
      if (await journal.write(_encode(merged, null), saved.etag)) {
        return merged;
      }
    }
    throw const SyncFailure('WebDAV 文件同时被修改，请重试同步');
  }

  static Never _interrupted() =>
      throw const SyncFailure('上游文件在上次同步中途被修改，已保留云端文件和本机进度，请检查该目录的备份。');

  Future<_RemoteState> _read({required bool requireJournal}) async {
    final metadata = await journal.read();
    if (requireJournal && metadata.bytes == null) {
      throw const SyncFailure('云端 WebDAV 合并日志已消失，已停止自动重建');
    }
    final file = await publicFile.read();
    final document = file.bytes == null
        ? null
        : WebDavSyncDocument.decode(file.bytes!);
    SyncDocument? committed;
    _Proposal? pending;
    if (metadata.bytes case final bytes?) {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic> ||
          raw['format'] != 'fqapp.webdav-state' ||
          raw['version'] != 1) {
        throw const FormatException('WebDAV 合并日志格式不受支持');
      }
      if (raw['committed'] case final Map<String, dynamic> saved) {
        committed = SyncDocument.fromJson(saved);
      } else if (raw['committed'] != null) {
        throw const FormatException('WebDAV 合并日志损坏');
      }
      if (raw['pending'] case final Map<String, dynamic> candidate) {
        pending = _Proposal.fromJson(candidate);
      } else if (raw['pending'] != null) {
        throw const FormatException('WebDAV 待提交记录损坏');
      }
    }
    return _RemoteState(file, metadata, document, committed, pending);
  }

  SyncDocument _merge(_RemoteState state, SyncDocument local) {
    var base = state.committed;
    if (state.pending case final pending?) {
      final hash = _hash(state.publicFile.bytes);
      if (hash != pending.baseHash && hash != pending.targetHash) {
        _interrupted();
      }
      if (hash == pending.targetHash) base = pending.document;
    }
    final remote = state.publicDocument;
    if (remote == null && base != null) {
      throw const SyncFailure('云端 fqapp-sync.json 已消失，已停止自动重建');
    }
    final upstream = base?.copy() ?? SyncDocument();
    if (remote != null) {
      final before = base?.visible ?? const <String, Map<String, dynamic>>{};
      final incoming = SyncSnapshot.fromBackup(remote.backup).values;
      final removed = <String, int>{};
      for (final row in remote.removedShelf.entries) {
        final key = ShelfIdentity.parseContentKey(
          row.key.substring(ShelfIdentity.storagePrefix.length),
        );
        if (key == null || key.source != ShelfIdentity.fanqie) continue;
        final id = 's|${key.kind}|${key.contentId}';
        if ((incoming[id]?['addedAt'] as int? ?? -1) <= row.value) {
          incoming.remove(id);
          removed[id] = row.value;
        }
      }
      for (final key in {...before.keys, ...incoming.keys, ...removed.keys}) {
        final value = incoming[key];
        if (value == null && before[key] == null) {
          if (!removed.containsKey(key) || upstream.records.containsKey(key)) {
            continue;
          }
        } else if (syncJson(value) == syncJson(before[key])) {
          continue;
        }
        upstream.change(
          key,
          value,
          actor: _externalActor,
          wall:
              removed[key] ??
              (value?['time'] ?? value?['addedAt'] ?? value?['at']) as int? ??
              remote.backup.createdAt.millisecondsSinceEpoch,
        );
      }
    }
    // A not-yet-projected proposal still carries device edits. Include them
    // during a read-only preview, without treating them as upstream edits.
    if (state.pending case final pending?) upstream.merge(pending.document);
    upstream.merge(local);
    SyncSnapshot.fromDocument(upstream);
    return upstream;
  }

  Uint8List _project(SyncDocument merged, WebDavSyncDocument? previous) {
    final desired = SyncSnapshot.fromDocument(merged).toBackup();
    final old = previous?.backup;
    final removed = {...?previous?.removedShelf};
    for (final entry in merged.records.entries) {
      if (!entry.key.startsWith('s|') ||
          !entry.value.any((version) => version.value == null)) {
        continue;
      }
      final parts = entry.key.split('|');
      final key = ShelfIdentity.storageKeyFor(parts[1], parts[2]);
      for (final version in entry.value.where((v) => v.value == null)) {
        if (version.wall > (removed[key] ?? -1)) removed[key] = version.wall;
      }
    }

    final shelf =
        [
          ...desired.shelf,
          for (final record in old?.shelf ?? const <ShelfRecord>[])
            if (record.item.source != ShelfIdentity.fanqie) record,
        ]..sort(
          (a, b) =>
              ShelfStore.keyOf(a.item).compareTo(ShelfStore.keyOf(b.item)),
        );
    for (final record in desired.shelf) {
      final key = ShelfStore.keyOf(record.item);
      // A re-add that observed the deletion wins even with a skewed clock.
      if (record.addedAt.millisecondsSinceEpoch <= (removed[key] ?? -1)) {
        removed.remove(key);
      }
    }
    final history =
        [
          ...desired.history,
          for (final record in old?.history ?? const <Map<String, dynamic>>[])
            if (record['source'] != null &&
                record['source'] != ShelfIdentity.fanqie)
              record,
        ]..sort(
          (a, b) => LibraryBackup.historyIdentity(
            a,
          ).compareTo(LibraryBackup.historyIdentity(b)),
        );
    final watchedIds = desired.watched.keys.toList()..sort();
    final backup = LibraryBackup.capture(
      shelf: shelf,
      history: history,
      watched: {for (final id in watchedIds) id: desired.watched[id]!},
      createdAt: old?.createdAt,
      aiData: old?.aiData,
      groups: old?.groups ?? const {},
    );
    return WebDavSyncDocument(backup, removed).encode();
  }

  static bool _sameProjection(Uint8List candidate, Uint8List? current) =>
      current != null &&
      syncJson(jsonDecode(utf8.decode(candidate))) ==
          syncJson(
            jsonDecode(
              utf8.decode(WebDavSyncDocument.decode(current).encode()),
            ),
          );

  static String? _hash(Uint8List? bytes) =>
      bytes == null ? null : sha256.convert(bytes).toString();

  static Uint8List _encode(SyncDocument? committed, _Proposal? pending) =>
      Uint8List.fromList(
        utf8.encode(
          syncJson({
            'format': 'fqapp.webdav-state',
            'version': 1,
            'committed': committed?.toJson(),
            if (pending != null) 'pending': pending.toJson(),
          }),
        ),
      );

  void close() {
    publicFile.close();
    journal.close();
  }
}

class _RemoteState {
  const _RemoteState(
    this.publicFile,
    this.journal,
    this.publicDocument,
    this.committed,
    this.pending,
  );

  final WebDavRemote publicFile, journal;
  final WebDavSyncDocument? publicDocument;
  final SyncDocument? committed;
  final _Proposal? pending;
}

class _Proposal {
  _Proposal(this.baseHash, this.publicBytes, this.document, {String? writer})
    : writer =
          writer ??
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';

  final String? baseHash;
  final String writer;
  final Uint8List publicBytes;
  final SyncDocument document;
  String get targetHash => sha256.convert(publicBytes).toString();

  factory _Proposal.fromJson(Map<String, dynamic> json) {
    final bytes = Uint8List.fromList(utf8.encode(json['projection'] as String));
    final projection = WebDavSyncDocument.decode(bytes);
    final document = SyncDocument.fromJson(
      json['document'] as Map<String, dynamic>,
    );
    if (syncJson(SyncSnapshot.fromBackup(projection.backup).values) !=
        syncJson(SyncSnapshot.fromDocument(document).values)) {
      throw const FormatException('WebDAV 待提交文件与合并日志不一致');
    }
    return _Proposal(
      json['base'] as String?,
      bytes,
      document,
      writer: json['writer'] as String,
    );
  }

  Map<String, Object?> toJson() => {
    'base': baseHash,
    'writer': writer,
    'projection': utf8.decode(publicBytes),
    'document': document.toJson(),
  };
}
