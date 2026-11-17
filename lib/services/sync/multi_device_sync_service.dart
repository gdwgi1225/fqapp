import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import '../../models/library_backup.dart';
import '../encrypted_hive.dart';
import '../library_backup_service.dart';
import '../library_store.dart';
import '../shelf_store.dart';
import '../webdav_client.dart';
import '../webdav_sync_service.dart';
import 'sync_document.dart';
import 'sync_snapshot.dart';
import 'sync_transport.dart';
import 'cloud_sync_transport.dart';
import 'sync_settings_store.dart';
import 'upstream_webdav_exchange.dart';

String newSyncIdentity() => List.generate(
  16,
  (_) => Random.secure().nextInt(256),
).map((v) => v.toRadixString(16).padLeft(2, '0')).join();

class SyncProvider {
  const SyncProvider(this.id, this.title, this.help);
  final String id, title, help;
  bool get available =>
      id == 'webdav' ||
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const values = [
    SyncProvider('webdav', 'WebDAV', '连接 WebDAV 服务并选择同步目录。'),
    SyncProvider('ali', '阿里云盘', '官方手机网页登录，使用网页授权凭据直接读写，支持刷新令牌；登录后可验证持续同步。'),
    SyncProvider(
      'quark',
      '夸克网盘',
      '官方客户端授权，无需粘贴授权码，授权后返回本应用。固定快照通过双区轮换替换；夸克回收站可能保留旧快照。',
    ),
    SyncProvider('tianyi', '天翼云盘', '官方手机网页登录，使用覆盖提交保存固定快照。'),
    SyncProvider('mobile139', '中国移动云盘', '官方手机网页登录，登录后可运行持续同步验证。'),
    SyncProvider(
      'weiyun',
      '腾讯微云',
      '支持从微云官网获取 API Key，或在官方网页用密码或扫码登录。固定快照按双区轮换，仅替换非当前分区。',
    ),
    SyncProvider('ftp', 'FTP', '使用现有 FTP 服务器；账号和文件以明文传输。'),
    SyncProvider('ftps', 'FTPS', 'FTP over TLS，验证服务器证书并加密数据连接。'),
    SyncProvider('smb', 'SMB', '连接 NAS 或电脑的共享文件夹，需要局域网、VPN 或可达网络。'),
  ];
  static SyncProvider byId(String id) =>
      values.firstWhere((v) => v.id == id, orElse: () => values.first);
}

class MultiDeviceSyncService extends ChangeNotifier
    with WidgetsBindingObserver
    implements SyncSettingsStore, WebDavSyncSettings {
  MultiDeviceSyncService._();
  static final instance = MultiDeviceSyncService._();

  static const _secrets = FlutterSecureStorage();
  Box<dynamic>? _box;
  Map<String, String> _config = {};
  final Map<String, Map<String, String>> _providerConfigs = {};
  WebDavConfig? _legacyWebDav;
  WebDavConfig? get _originalWebDav =>
      WebDavSyncService.instance.config ?? _legacyWebDav;
  bool get hasSelectedSyncBackend => _config['unifiedSyncConfirmed'] == 'true';
  @override
  bool get needsWebDavReview =>
      (_originalWebDav?.enabled == true && !hasSelectedSyncBackend) ||
      (_config['provider'] == 'webdav' &&
          Uri.tryParse(_config['endpoint'] ?? '')?.scheme != 'https');

  Map<String, String> _savedWebDav() {
    final saved = _providerConfigs['webdav'];
    if (saved != null) return Map.unmodifiable(saved);
    final legacy = _originalWebDav;
    if (legacy != null) {
      return {
        'provider': 'webdav',
        'endpoint': legacy.directory,
        'username': legacy.username,
        'password': legacy.password,
      };
    }
    return const {};
  }

  @override
  Map<String, String> get config => Map.unmodifiable(_config);
  @override
  Map<String, String> configFor(String provider) {
    if (provider == 'webdav') {
      if (_config['provider'] == 'webdav') return config;
      return _savedWebDav();
    }
    return Map.unmodifiable(
      _providerConfigs[provider] ?? {'provider': provider, 'enabled': 'false'},
    );
  }

  SyncDocument _document = SyncDocument();
  SyncSnapshot _baseline = SyncSnapshot({});
  String _actor = '', _profile = '';
  int _sequence = 0, _failures = 0;
  String _published = '';
  @override
  String status = '未配置多端同步';
  @override
  DateTime? lastSuccess;
  @override
  bool get enabled => _config['enabled'] == 'true' && !needsWebDavReview;
  bool get ready => _box != null;
  @override
  bool busy = false;
  bool _configuring = false;
  Future<void> _queue = Future.value();
  Future<void>? _running;
  Timer? _timer;
  Timer? _webDavPoll;
  DateTime? _lastAttempt;
  SyncTransport? _activeTransport;
  UpstreamWebDavExchange? _activeUpstream;
  bool _stopping = false;
  bool _journalDirty = false;
  bool _upstreamEstablished = false;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> initialize() async {
    if (_box != null || !ShelfStore.instance.isReady) return;
    try {
      _box = await EncryptedHive.openBox(
        Hive,
        'multi_device_sync_v1',
        requireEncryption: true,
      );
      final saved = await _secrets.read(
        key: 'fqapp.multi-device-sync.config.v1',
      );
      if (saved != null) {
        _config = Map<String, String>.from(jsonDecode(saved) as Map);
      }
      final profiles = await _secrets.read(
        key: 'fqapp.multi-device-sync.providers.v1',
      );
      if (profiles != null) {
        final raw = jsonDecode(profiles) as Map;
        for (final entry in raw.entries) {
          _providerConfigs[entry.key as String] = Map<String, String>.from(
            entry.value as Map,
          );
        }
      }
      if (_config['provider'] case final String provider) {
        final cached = _providerConfigs[provider];
        if (cached != null &&
            cached['profile'] == _config['profile'] &&
            cached['password'] != null) {
          _config = {..._config, 'password': cached['password']!};
        }
        _providerConfigs[provider] = Map.of(_config);
      }
      try {
        _legacyWebDav = await WebDavSyncService.readSavedConfig();
      } catch (_) {
        // An unavailable legacy setting does not block an existing profile.
      }
      _loadProfile();
      if (needsWebDavReview) {
        status = '请确认 HTTPS WebDAV 配置和目录后切换到多端同步';
      }
      LibraryStore.instance.historyListenable.addListener(_changed);
      LibraryStore.instance.watchedListenable.addListener(_changed);
      ShelfStore.instance.listenable.addListener(_changed);
      WidgetsBinding.instance.addObserver(this);
      notifyListeners();
      _updateWebDavPolling(WidgetsBinding.instance.lifecycleState);
      if (enabled) {
        _changed();
        unawaited(sync());
      }
    } catch (error) {
      status = '同步初始化失败，本机阅读不受影响';
      notifyListeners();
    }
  }

  void _loadProfile() {
    _profile = _config['profile'] ?? '';
    final raw = _box?.get(_profile);
    _document = SyncDocument();
    _baseline = SyncSnapshot({});
    _actor = newSyncIdentity();
    _sequence = 0;
    _published = '';
    _journalDirty = false;
    _upstreamEstablished = false;
    lastSuccess = null;
    if (raw is String) {
      final saved = jsonDecode(raw) as Map;
      _actor = saved['actor'] as String;
      if (!syncActorPattern.hasMatch(_actor)) {
        throw const FormatException('设备身份无效');
      }
      _document = SyncDocument.fromJson(
        Map<String, dynamic>.from(saved['document'] as Map),
      );
      _baseline = SyncSnapshot({
        for (final e in (saved['baseline'] as Map).entries)
          e.key as String: Map<String, dynamic>.from(e.value as Map),
      });
      _sequence = saved['sequence'] as int;
      _published = saved['published'] as String;
      final timestamp = saved['lastSuccess'] as int?;
      _upstreamEstablished = _hasUpstreamJournal(saved);
      if (timestamp != null) {
        lastSuccess = DateTime.fromMillisecondsSinceEpoch(timestamp);
      }
      // Recover a crash between a library write and the matching journal write.
      final pending = saved['pending'];
      if (pending is Map) _pendingRecovery = Map<String, dynamic>.from(pending);
    }
    status = enabled ? '等待同步' : '未启用多端同步';
  }

  Map<String, dynamic>? _pendingRecovery;
  Future<void> _persist({Map<String, dynamic>? pending}) async {
    await _box!.put(
      _profile,
      jsonEncode({
        'actor': _actor,
        'sequence': _sequence,
        'published': _published,
        'document': _document.toJson(),
        'baseline': _baseline.values,
        'lastSuccess': lastSuccess?.millisecondsSinceEpoch,
        if (_config['provider'] == 'webdav')
          'upstreamEstablished': _upstreamEstablished,
        'pending': ?pending,
      }),
    );
    await _box!.flush();
    _journalDirty = false;
  }

  @override
  Future<void> configure(Map<String, String> config) async {
    if (_configuring) throw const SyncFailure('请等待当前同步设置保存完成');
    _configuring = true;
    final switching =
        ready && config['enabled'] == 'true' && !hasSelectedSyncBackend;
    try {
      if (switching) {
        await WebDavSyncService.instance.suspendForMultiDeviceSync();
      }
      await _configure(config);
    } finally {
      _configuring = false;
      _updateWebDavPolling(WidgetsBinding.instance.lifecycleState);
      if (switching && !hasSelectedSyncBackend) {
        await WebDavSyncService.instance.resumeAfterSetup();
      }
    }
    if (enabled) unawaited(sync());
  }

  Future<void> _configure(Map<String, String> config) async {
    if (!ready) throw const SyncFailure('本机同步存储尚未准备好');
    final submitted = Map<String, String>.of(config);
    final previewRevision = submitted.remove('webdavPreview');
    final key = submitted['provider']!;
    final original = Map<String, String>.of(
      key == 'webdav' ? _savedWebDav() : _providerConfigs[key] ?? {},
    );
    final followsSavedCredential =
        original['profile'] != null &&
        (submitted['password'] ?? '') == (original['password'] ?? '');
    if (_running != null) await _running;
    await _serial(() async {
      final prior = key == 'webdav'
          ? _savedWebDav()
          : _providerConfigs[key] ?? {};
      if (followsSavedCredential && prior['profile'] != original['profile']) {
        throw const SyncFailure('登录状态已变化，请重新打开同步设置后保存');
      }
      final effective = {
        ...submitted,
        if (followsSavedCredential) 'password': prior['password'] ?? '',
      };
      final changed = [
        'provider',
        'endpoint',
        'username',
        'password',
        'domain',
        'implicit',
        'folderId',
        'folderParent',
      ].any((key) => effective[key] != prior[key]);
      final changingWebDav =
          changed || key != _config['provider'] || needsWebDavReview;
      if (key == 'webdav' &&
          effective['enabled'] == 'true' &&
          (previewRevision != null || changingWebDav)) {
        if (previewRevision == null ||
            (await _previewWebDav(effective)).revision != previewRevision) {
          throw const SyncFailure('同步数据已变化，请重新预览后再保存');
        }
      }
      final next = {
        ...effective,
        if (effective['enabled'] == 'true') 'unifiedSyncConfirmed': 'true',
        'profile': changed || (prior['profile'] ?? '').isEmpty
            ? newSyncIdentity()
            : prior['profile']!,
      };
      _timer?.cancel();
      // Store the inactive profile first. An interrupted settings save must
      // never point the old in-memory journal at the new destination.
      await _secrets.write(
        key: 'fqapp.multi-device-sync.providers.v1',
        value: jsonEncode({..._providerConfigs, key: next}),
      );
      await _secrets.write(
        key: 'fqapp.multi-device-sync.config.v1',
        value: jsonEncode(next),
      );
      _config = next;
      _providerConfigs[key] = Map.of(next);
      _pendingRecovery = null;
      _loadProfile();
      if (enabled) await _capture();
      notifyListeners();
    });
  }

  @override
  Future<void> setAutoSync(bool value) async {
    if (_config['provider'] == null) return;
    if (value && needsWebDavReview) {
      throw const SyncFailure('请先重新打开同步设置，确认目标后再启用');
    }
    if (!value) {
      _timer?.cancel();
      _activeTransport?.close();
      _activeUpstream?.close();
    }
    await configure({..._config, 'enabled': '$value'});
  }

  Future<void> _saveProviderConfigs() => _secrets.write(
    key: 'fqapp.multi-device-sync.providers.v1',
    value: jsonEncode(_providerConfigs),
  );

  Future<void> saveProviderCredentials(
    String provider,
    Map<String, String> updates, {
    String? profile,
  }) => _serial(() async {
    final prior = _providerConfigs[provider];
    if (prior == null) return;
    final target = profile ?? prior['profile'];
    if (prior['profile'] == target) {
      _providerConfigs[provider] = {...prior, ...updates};
      await _saveProviderConfigs();
    }
    if (_config['provider'] == provider && _config['profile'] == target) {
      _config = {..._config, ...updates};
      await _secrets.write(
        key: 'fqapp.multi-device-sync.config.v1',
        value: jsonEncode(_config),
      );
    }
    notifyListeners();
  });

  SyncTransport transportFor(Map<String, String> config) {
    final provider = config['provider'];
    if (provider == 'webdav') {
      return WebDavSyncTransport(
        config['endpoint'] ?? '',
        config['username'] ?? '',
        config['password'] ?? '',
      );
    }
    if ({'ftp', 'ftps', 'smb'}.contains(provider)) {
      return NativeSyncTransport(config);
    }
    return createCloudSyncTransport(
      config,
      (updates) => saveProviderCredentials(
        provider!,
        updates,
        profile: config['profile'],
      ),
    );
  }

  void _changed() {
    if (!enabled || !ready || _stopping) return;
    unawaited(
      _serial(() async {
        try {
          if (await _capture()) _schedule();
        } catch (_) {
          status = '本地同步日志写入失败，记录仍保存在本机';
          _schedule();
          notifyListeners();
        }
      }),
    );
  }

  void _schedule() {
    if (_timer?.isActive ?? false) return;
    // Persist every change immediately; coalesce network writes to avoid quota
    // exhaustion while a player updates its position every few seconds.
    final elapsed = DateTime.now().difference(_lastAttempt ?? DateTime(2000));
    final wait = elapsed.inSeconds >= 30 ? 2 : 30 - elapsed.inSeconds;
    _timer = Timer(Duration(seconds: wait), () => unawaited(sync()));
  }

  void _updateWebDavPolling(AppLifecycleState? state) {
    final foreground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (!enabled ||
        _config['provider'] != 'webdav' ||
        _stopping ||
        !foreground) {
      _webDavPoll?.cancel();
      _webDavPoll = null;
      return;
    }
    _webDavPoll ??= Timer.periodic(
      const Duration(minutes: 2),
      (_) => unawaited(sync()),
    );
  }

  Future<SyncSnapshot> _current() async =>
      SyncSnapshot.fromBackup(await LibraryBackupService().capture());

  static WebDavConfig _upstreamConfig(Map<String, String> config) =>
      WebDavConfig(
        directory: config['endpoint'] ?? '',
        username: config['username'] ?? '',
        password: config['password'] ?? '',
        enabled: true,
      );

  static bool _hasUpstreamJournal(Map? saved) =>
      saved?['upstreamEstablished'] == true;

  @override
  Future<WebDavSyncPreview> previewWebDav(Map<String, String> config) async {
    if (!ready) throw const SyncFailure('本机同步存储尚未准备好');
    return _serial(() => _previewWebDav(config));
  }

  Future<WebDavSyncPreview> _previewWebDav(Map<String, String> config) async {
    final current = await _current();
    final prior = _savedWebDav();
    final sameTarget = [
      'endpoint',
      'username',
      'password',
    ].every((key) => prior[key] == config[key]);
    final raw = sameTarget ? _box!.get(prior['profile']) : null;
    final saved = raw is String
        ? jsonDecode(raw) as Map<String, dynamic>
        : null;
    final baseline = saved?['baseline'] as Map? ?? const {};
    final document = saved == null
        ? SyncDocument()
        : SyncDocument.fromJson(saved['document'] as Map<String, dynamic>);
    for (final key in {
      ...baseline.keys.cast<String>(),
      ...current.values.keys,
    }) {
      final value = current.values[key];
      if (syncJson(value) == syncJson(baseline[key])) continue;
      document.change(
        key,
        value,
        actor: saved?['actor'] as String? ?? 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        wall:
            (value?['time'] ?? value?['addedAt'] ?? value?['at']) as int? ?? 0,
      );
    }

    late final ({SyncDocument document, LibraryBackup? remote, String revision})
    preview;
    try {
      final upstream = UpstreamWebDavExchange.connect(_upstreamConfig(config));
      try {
        preview = await upstream.preview(
          document,
          requireJournal: _hasUpstreamJournal(saved),
        );
      } finally {
        upstream.close();
      }
    } on WebDavException catch (error) {
      throw SyncFailure(error.message);
    }

    final remoteBackup = preview.remote;
    final desired = SyncSnapshot.fromDocument(preview.document);
    final backup = desired.toBackup();
    final localBackup = current.toBackup();
    return WebDavSyncPreview(
      revision: sha256
          .convert(
            utf8.encode(
              syncJson([
                config['endpoint'],
                config['username'],
                preview.revision,
                current.values,
              ]),
            ),
          )
          .toString(),
      cloudShelf: remoteBackup?.shelf.length ?? 0,
      cloudHistory: remoteBackup?.history.length ?? 0,
      cloudEpisodes: remoteBackup?.episodeCount ?? 0,
      localShelf: localBackup.shelf.length,
      localHistory: localBackup.history.length,
      localEpisodes: localBackup.episodeCount,
      mergedShelf: backup.shelf.length,
      mergedHistory: backup.history.length,
      mergedEpisodes: backup.episodeCount,
      localRemovals: current.values.keys
          .where((key) => !desired.values.containsKey(key))
          .length,
    );
  }

  Future<bool> _capture() async {
    final current = await _current();
    final pending = _pendingRecovery;
    if (pending != null) {
      final desired = Map<String, dynamic>.from(pending);
      final keys = {..._baseline.values.keys, ...desired.keys};
      for (final key in keys) {
        if (syncJson(current.values[key]) == syncJson(desired[key])) {
          if (desired[key] == null) {
            _baseline.values.remove(key);
          } else {
            _baseline.values[key] = Map<String, dynamic>.from(
              desired[key] as Map,
            );
          }
        }
      }
      _pendingRecovery = null;
    }
    final keys = {...current.values.keys, ..._baseline.values.keys};
    final firstCapture = _box!.get(_profile) == null;
    var changed = false;
    for (final key in keys) {
      if (syncJson(current.values[key]) == syncJson(_baseline.values[key])) {
        continue;
      }
      _document.change(
        key,
        current.values[key],
        actor: _actor,
        wall: firstCapture
            ? ((current.values[key]?['time'] ??
                          current.values[key]?['addedAt'] ??
                          current.values[key]?['at'] ??
                          0)
                      as num)
                  .toInt()
            : DateTime.now().millisecondsSinceEpoch,
      );
      changed = true;
    }
    _baseline = current;
    // Also persist recovery reconciliation when it produced no new operation.
    _journalDirty =
        _journalDirty ||
        changed ||
        pending != null ||
        _box!.get(_profile) == null;
    if (_journalDirty) {
      await _persist();
    }
    return changed;
  }

  SyncTransport _transport() {
    return transportFor(_config);
  }

  @override
  Future<void> sync() {
    if (!ready || !enabled || _stopping || _configuring) {
      return Future.value();
    }
    if (_running != null) return _running!;
    final future = _sync();
    _running = future;
    return future.whenComplete(() => _running = null);
  }

  Future<void> _applyMerged(SyncSnapshot desired) async {
    // Write the intent first so a process death cannot turn a downloaded
    // deletion into a fresh local add on next startup.
    await _persist(pending: desired.values);
    _pendingRecovery = desired.values;
    final backup = desired.toBackup();
    final shelfApplied = await ShelfStore.instance.applySyncedRecords(
      incoming: backup.shelf,
      acceptsCurrent: (shelf) => SyncSnapshot.fromBackup(
        LibraryBackup.capture(shelf: shelf, history: [], watched: {}),
      ).sameDomain(_baseline, 's|'),
    );
    if (shelfApplied) _baseline.replaceDomain(desired, 's|');
    final libraryApplied = await LibraryStore.instance.applySyncedRecords(
      history: backup.history,
      watched: backup.watched,
      acceptsCurrent: (history, watched) {
        final current = SyncSnapshot.fromBackup(
          LibraryBackup.capture(shelf: [], history: history, watched: watched),
        );
        return current.sameDomain(_baseline, 'h|') &&
            current.sameDomain(_baseline, 'w|');
      },
    );
    if (libraryApplied) {
      _baseline.replaceDomain(desired, 'h|');
      _baseline.replaceDomain(desired, 'w|');
    }
    _pendingRecovery = null;
    await _persist();
    await _capture(); // Capture user writes that raced the conditional apply.
  }

  Future<void> _sync() async {
    busy = true;
    status = '正在合并多端记录…';
    notifyListeners();
    _timer?.cancel();
    _lastAttempt = DateTime.now();
    SyncTransport? transport;
    try {
      await _serial(_capture);
      if (_config['provider'] == 'webdav') {
        final upstream = UpstreamWebDavExchange.connect(
          _upstreamConfig(_config),
        );
        _activeUpstream = upstream;
        final published = await _serial(() async => _document.copy());
        final merged = await upstream.sync(
          published,
          requireJournal: _upstreamEstablished,
        );
        final serverVersion = syncJson(merged.toJson());
        await _serial(() async {
          await _capture();
          merged.merge(_document);
          _document = merged;
          _upstreamEstablished = true;
          await _applyMerged(SyncSnapshot.fromDocument(merged));
          lastSuccess = DateTime.now();
          await _persist();
          if (syncJson(_document.toJson()) != serverVersion) {
            _schedule();
          }
        });
        _failures = 0;
        status = '同步完成';
        return;
      }
      transport = _transport();
      _activeTransport = transport;
      final exchange = SyncExchange(transport);
      final slots = await exchange.readAll();
      late SyncSlot outgoing;
      await _serial(() async {
        await _capture();
        final merged = _document.copy();
        for (final slot in slots.values) {
          merged.merge(slot.document);
        }
        final desired = SyncSnapshot.fromDocument(merged);
        _document = merged;
        if ((slots[_actor]?.sequence ?? 0) > _sequence) {
          _sequence = slots[_actor]!.sequence;
        }
        await _applyMerged(desired);
        outgoing = SyncSlot(_actor, _sequence + 1, _document.copy());
      });
      final fingerprint = sha256
          .convert(utf8.encode(syncJson(outgoing.document.toJson())))
          .toString();
      // Recreate our slots if a user intentionally changed/emptied the folder.
      final didPublish =
          fingerprint != _published || !slots.containsKey(_actor);
      if (didPublish) {
        await exchange.publish(outgoing);
      }
      await _serial(() async {
        if (didPublish) _sequence = outgoing.sequence;
        _published = fingerprint;
        lastSuccess = DateTime.now();
        await _persist();
        if (syncJson(_document.toJson()) !=
            syncJson(outgoing.document.toJson())) {
          _schedule();
        }
      });
      _failures = 0;
      status = '同步完成';
    } catch (error) {
      _failures++;
      status = error is SyncFailure
          ? error.message
          : error is WebDavException
          ? error.message
          : error is FormatException
          ? error.message
          : '同步未完成，本机记录已保留';
      if (enabled && !_stopping) {
        _timer = Timer(
          Duration(seconds: min(300, 30 * (1 << min(_failures, 4)))),
          () => unawaited(sync()),
        );
      }
    } finally {
      transport?.close();
      _activeUpstream?.close();
      _activeUpstream = null;
      _activeTransport = null;
      busy = false;
      notifyListeners();
    }
  }

  /// Called before closing Hive on desktop, and by integration tests. Cancels
  /// network IO but flushes the local journal; no reading records are removed.
  Future<void> shutdown() async {
    _stopping = true;
    _timer?.cancel();
    _webDavPoll?.cancel();
    _activeTransport?.close();
    _activeUpstream?.close();
    await _running;
    if (_box == null) return;
    LibraryStore.instance.historyListenable.removeListener(_changed);
    LibraryStore.instance.watchedListenable.removeListener(_changed);
    ShelfStore.instance.listenable.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    if (enabled) await _serial(_capture);
    _timer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _updateWebDavPolling(state);
    if (state == AppLifecycleState.resumed) unawaited(sync());
    if (state == AppLifecycleState.paused) {
      if (_config['provider'] == 'webdav') {
        unawaited(sync());
      } else {
        _changed();
      }
    }
  }
}
