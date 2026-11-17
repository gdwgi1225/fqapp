import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import '../platform_channel.dart';
import 'sync_document.dart';

/// Storage only. Merge semantics are independent of the hosting service.
abstract interface class SyncTransport {
  Future<void> prepare();
  Future<List<String>> list();
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List bytes);
  void close();
}

class SyncFailure implements Exception {
  const SyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

void checkSlotName(String name) {
  if (!syncSlotPattern.hasMatch(name)) throw const SyncFailure('同步文件名无效');
}

class WebDavSyncTransport implements SyncTransport {
  WebDavSyncTransport(String endpoint, String username, String password)
    : root = Uri.parse(endpoint.endsWith('/') ? endpoint : '$endpoint/'),
      authorization =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}' {
    if (!{'https', 'http'}.contains(root.scheme) ||
        root.host.isEmpty ||
        root.userInfo.isNotEmpty ||
        root.hasQuery ||
        root.hasFragment) {
      throw const SyncFailure('请输入完整的 WebDAV 文件夹地址');
    }
    client.connectionTimeout = const Duration(seconds: 20);
  }
  final Uri root;
  final String authorization;
  final HttpClient client = HttpClient();
  Future<({int status, Uint8List bytes})> request(
    String method,
    Uri uri, {
    Uint8List? bytes,
    Map<String, String> headers = const {},
  }) async {
    try {
      final req = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 30));
      // Redirects must never forward a password to a different service.
      req.followRedirects = false;
      req.headers.set(HttpHeaders.authorizationHeader, authorization);
      headers.forEach(req.headers.set);
      if (bytes != null) {
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final response = await req.close().timeout(const Duration(seconds: 45));
      final data = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        data.add(chunk);
        if (data.length > syncMaxBytes) throw const SyncFailure('远程文件超过同步大小限制');
      }
      return (status: response.statusCode, bytes: data.takeBytes());
    } on SyncFailure {
      rethrow;
    } catch (_) {
      throw const SyncFailure('WebDAV 连接失败，请检查地址、网络和证书');
    }
  }

  @override
  Future<void> prepare() async {
    // Only create the folder explicitly configured by the user. Do not create
    // arbitrary missing parent paths or touch files outside that folder.
    final r = await request('MKCOL', root);
    if (![200, 201, 204, 405].contains(r.status)) {
      throw SyncFailure('WebDAV 文件夹不可用（HTTP ${r.status}）');
    }
  }

  @override
  Future<List<String>> list() async {
    final r = await request(
      'PROPFIND',
      root,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      bytes: Uint8List.fromList(
        utf8.encode(
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
        ),
      ),
    );
    if (r.status != 207) throw SyncFailure('WebDAV 列表失败（HTTP ${r.status}）');
    try {
      final xml = XmlDocument.parse(utf8.decode(r.bytes));
      final names = <String>{};
      for (final e in xml.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'href' && e.name.namespaceUri == 'DAV:',
      )) {
        final target = root.resolve(e.innerText);
        if (target.origin != root.origin) continue;
        final segments = target.pathSegments;
        final name = segments.isEmpty ? '' : segments.last;
        if (syncSlotPattern.hasMatch(name) &&
            root.resolve(name).path == target.path) {
          names.add(name);
        }
      }
      return names.toList();
    } catch (_) {
      throw const SyncFailure('WebDAV 返回了无效的文件列表');
    }
  }

  @override
  Future<Uint8List?> read(String name) async {
    checkSlotName(name);
    final r = await request('GET', root.resolve(name));
    if (r.status == 404) return null;
    if (r.status != 200) throw SyncFailure('WebDAV 读取失败（HTTP ${r.status}）');
    return r.bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    final r = await request(
      'PUT',
      root.resolve(name),
      bytes: bytes,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    );
    if (![200, 201, 204].contains(r.status)) {
      throw SyncFailure('WebDAV 写入失败（HTTP ${r.status}）');
    }
  }

  @override
  void close() => client.close(force: true);
}

class NativeSyncTransport implements SyncTransport {
  NativeSyncTransport(this.config);
  final Map<String, String> config;
  static const channel = AppMethodChannel('fqapp/sync_storage');
  Future<T?> _call<T>(String action, [String? name, Uint8List? bytes]) async {
    if (!Platform.isAndroid) {
      throw const SyncFailure('FTP、FTPS 和 SMB 当前在 Android 端提供');
    }
    try {
      return await channel.invokeMethod<T>(action, {
        ...config,
        'name': ?name,
        'bytes': ?bytes,
      });
    } catch (_) {
      throw const SyncFailure('存储连接失败，请检查地址、账号、目录和权限');
    }
  }

  @override
  Future<void> prepare() async {
    await _call('prepare');
  }

  @override
  Future<List<String>> list() async =>
      (await _call<List>('list') ?? []).cast<String>();
  @override
  Future<Uint8List?> read(String name) {
    checkSlotName(name);
    return _call<Uint8List>('read', name);
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    await _call('write', name, bytes);
  }

  @override
  void close() {}
}

/// Both slots are read; incomplete writes fall back to the last valid slot.
/// Each installation writes only its own pair, so concurrent installations
/// cannot overwrite each other even when a server ignores conditional PUT.
class SyncExchange {
  SyncExchange(this.transport);
  final SyncTransport transport;
  Future<Map<String, SyncSlot>> readAll({bool prepare = true}) async {
    if (prepare) await transport.prepare();
    final names = (await transport.list())
        .where(syncSlotPattern.hasMatch)
        .toSet();
    if (names.length > 128) throw const SyncFailure('同步目录超过 64 台设备，请更换目录');
    final slots = <String, SyncSlot>{};
    final failed = <String>{};
    for (final name in names) {
      final actor = name.substring(0, 32);
      final bytes = await transport.read(name);
      if (bytes == null) {
        failed.add(actor);
        continue;
      }
      try {
        final slot = SyncSlot.decode(bytes, name);
        if ((slots[actor]?.sequence ?? 0) < slot.sequence) slots[actor] = slot;
      } catch (_) {
        failed.add(actor);
      }
    }
    if (failed.any((actor) => !slots.containsKey(actor))) {
      throw const SyncFailure('有设备的两个快照均不可读，已保留本地数据，请稍后重试');
    }
    return slots;
  }

  Future<void> publish(SyncSlot slot) async {
    final bytes = slot.encode();
    await transport.write(slot.filename, bytes);
    // Some cloud lists/download links briefly expose the prior committed
    // version. Retry reads only; never resend a write or accept stale bytes.
    bool matches(Uint8List? actual) {
      if (actual == null || actual.length != bytes.length) return false;
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != actual[i]) return false;
      }
      return true;
    }

    for (var attempt = 0; attempt < 5; attempt++) {
      if (matches(await transport.read(slot.filename))) return;
      if (attempt < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw const SyncFailure('写入后校验失败，保留待同步状态');
  }
}
