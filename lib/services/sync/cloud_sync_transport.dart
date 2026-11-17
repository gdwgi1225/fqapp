import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'sync_document.dart';
import 'sync_folder_name.dart';
import 'sync_transport.dart';
import 'weiyun_hash.dart';
import '../platform_channel.dart';
import 'package:flutter/services.dart';

typedef SaveSyncCredentials =
    Future<void> Function(Map<String, String> updates);
SyncTransport createCloudSyncTransport(
  Map<String, String> config,
  SaveSyncCredentials save,
) {
  switch (config['provider']) {
    case 'weiyun':
      return WeiyunSyncTransport(config);
    case 'ali':
      return AliSyncTransport(config, save);
    case 'quark':
    case 'tianyi':
    case 'mobile139':
      return AndroidCloudSyncTransport(config, save);
    default:
      throw const SyncFailure('该服务的持续同步尚未开放，请先选 WebDAV 或已接入的服务');
  }
}

class AndroidCloudSyncTransport implements SyncTransport {
  AndroidCloudSyncTransport(this.config, this.save);
  final Map<String, String> config;
  final SaveSyncCredentials save;
  static const channel = AppMethodChannel('fqapp/cloud_storage');
  String? session;
  Future<T?> call<T>(
    String method, [
    Map<String, dynamic> values = const {},
  ]) async {
    if (!Platform.isAndroid) {
      throw const SyncFailure('这家网盘的登录和同步目前在 Android 端提供');
    }
    try {
      return await channel.invokeMethod<T>(method, {
        'session': session,
        ...values,
      });
    } on PlatformException catch (error) {
      throw SyncFailure(error.message ?? '网盘请求失败，请重新登录后再试');
    }
  }

  Future<void> open() async {
    if (session != null) return;
    final opened = await call<Map>('open', {
      'provider': config['provider'],
      'password': config['password'],
      'forceRefresh': config['forceRefresh'] == 'true',
    });
    if (opened == null) throw const SyncFailure('未能创建网盘会话');
    session = opened['session'] as String;
    // Persist a rotated token before any folder operation can fail.
    await save({'password': opened['credentials'] as String});
  }

  @override
  Future<void> prepare() async {
    await open();
    if ((config['folderId'] ?? '').isNotEmpty) {
      await call('selectFolder', {'folderId': config['folderId']});
    } else {
      await call('prepare', {'folder': _folder(config)});
    }
  }

  @override
  Future<List<String>> list() async =>
      (await call<List>('list') ?? []).cast<String>();
  @override
  Future<Uint8List?> read(String name) {
    checkSlotName(name);
    return call<Uint8List>('read', {'name': name});
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    await call('write', {'name': name, 'bytes': bytes});
  }

  @override
  void close() {
    if (session != null) {
      call('close').catchError((Object _) => null);
      session = null;
    }
  }
}

class CloudHttp {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  Future<({int status, Uint8List bytes})> send(
    String method,
    String address, {
    Map<String, String> headers = const {},
    Uint8List? bytes,
  }) => _send(method, address, headers: headers, bytes: bytes, redirects: 0);

  Future<({int status, Uint8List bytes})> _send(
    String method,
    String address, {
    required Map<String, String> headers,
    Uint8List? bytes,
    required int redirects,
  }) async {
    final uri = Uri.parse(address);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const SyncFailure('云盘返回了不安全的连接');
    }
    try {
      final req = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 30));
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      if (!headers.keys.any((name) => name.toLowerCase() == 'user-agent')) {
        req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 fqapp/1.0');
      }
      if (bytes != null) {
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final response = await req.close().timeout(const Duration(seconds: 45));
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        buffer.add(chunk);
        if (buffer.length > syncMaxBytes) throw const SyncFailure('云盘响应超过大小限制');
      }
      // Signed downloads also redirect when callers supplied a Referer or a
      // file cookie. Bound the chain, and strip credentials across origins.
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          method == 'GET') {
        final next = response.headers.value('location');
        if (next != null) {
          if (redirects >= 5) throw const SyncFailure('云盘下载重定向次数过多');
          final target = uri.resolve(next);
          final forwarded = target.origin == uri.origin
              ? headers
              : {
                  for (final entry in headers.entries)
                    if ({
                      'accept',
                      'range',
                      'referer',
                    }.contains(entry.key.toLowerCase()))
                      entry.key: entry.value,
                };
          return await _send(
            'GET',
            target.toString(),
            headers: forwarded,
            redirects: redirects + 1,
          );
        }
      }
      return (status: response.statusCode, bytes: buffer.takeBytes());
    } on SyncFailure {
      rethrow;
    } catch (_) {
      throw const SyncFailure('云盘连接失败，请检查网络或重新登录');
    }
  }

  Future<Map<String, dynamic>> json(
    String method,
    String url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    final r = await send(
      method,
      url,
      headers: {'Content-Type': 'application/json', ...headers},
      bytes: body == null
          ? null
          : Uint8List.fromList(utf8.encode(jsonEncode(body))),
    );
    if (r.status < 200 || r.status >= 300) {
      throw SyncFailure('云盘接口请求失败（HTTP ${r.status}），可能需要重新登录');
    }
    try {
      return r.bytes.isEmpty
          ? {}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bytes)) as Map);
    } catch (_) {
      throw const SyncFailure('云盘返回内容无效');
    }
  }

  void close() => client.close(force: true);
}

String _folder(Map<String, String> config) {
  final folder = config['endpoint']?.trim();
  final name = folder == null || folder.isEmpty
      ? defaultSyncFolderName
      : folder;
  validateSyncFolderName(name);
  return name;
}

class WeiyunSyncTransport implements SyncTransport {
  WeiyunSyncTransport(this.config);
  final Map<String, String> config;
  final http = CloudHttp();
  String parent = '', directory = '', fileParent = '';
  int request = 0;
  String get token {
    final text = config['password'] ?? '';
    final found = RegExp(
      r'(?:WEIYUN_)?MCP_TOKEN\s*[=:]\s*["\x27]?([A-Za-z0-9_.-]{16,2048})(?=["\x27\s;]|$)',
      caseSensitive: false,
    ).firstMatch(text);
    final value = found?.group(1) ?? text.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]{16,2048}$').hasMatch(value)) {
      throw const SyncFailure('未识别到微云 API Key，请粘贴从微云官网复制的完整 API Key');
    }
    return value;
  }

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final result = await http.json(
      'POST',
      'https://www.weiyun.com/api/v3/mcpserver',
      headers: {'WyHeader': 'mcp_token=$token'},
      body: {
        'jsonrpc': '2.0',
        'id': ++request,
        'method': 'tools/call',
        'params': {'name': 'weiyun.$name', 'arguments': arguments},
      },
    );
    if (result['error'] != null) throw const SyncFailure('微云授权或接口请求失败');
    final envelope = result['result'] as Map;
    if (envelope['isError'] == true) {
      throw const SyncFailure('微云拒绝请求，请检查授权目录和 Token');
    }
    for (final item in envelope['content'] as List) {
      if (item['type'] != 'text') continue;
      final data = Map<String, dynamic>.from(
        jsonDecode(item['text'] as String) as Map,
      );
      final error = data['error'];
      final code = data['code'] == null ? 0 : int.tryParse('${data['code']}');
      if ((error != null && error != '' && error != false && error != 0) ||
          code != 0) {
        throw SyncFailure('微云 $name 操作失败（服务码 ${code ?? '未知'}），请检查授权目录');
      }
      return data;
    }
    throw const SyncFailure('微云响应无效');
  }

  Future<List<Map<String, dynamic>>> entries({bool root = false}) async {
    final all = <Map<String, dynamic>>[];
    const pageSize = 50; // Official MCP list limit.
    for (var offset = 0; offset < 10000; offset += pageSize) {
      final r = await call('list', {
        'limit': pageSize,
        'offset': offset,
        'get_type': 0,
        if (!root) 'dir_key': directory,
        if (!root) 'pdir_key': parent,
      });
      if (root) parent = r['pdir_key'] as String? ?? '';
      if (!root &&
          r['pdir_key'] is String &&
          (r['pdir_key'] as String).isNotEmpty) {
        fileParent = r['pdir_key'] as String;
      }
      final dirs = (r['dir_list'] as List? ?? []).cast<Map>();
      final files = (r['file_list'] as List? ?? []).cast<Map>();
      all.addAll([...dirs, ...files].map((e) => Map<String, dynamic>.from(e)));
      final finish = r['finish_flag'];
      if (finish == true ||
          finish == 1 ||
          finish == '1' ||
          (finish == null && dirs.length + files.length < pageSize)) {
        return all;
      }
    }
    throw const SyncFailure('微云授权目录项目过多，请选择专用目录');
  }

  @override
  Future<void> prepare() async {
    if (directory.isNotEmpty) return;
    if ((config['folderId'] ?? '').isNotEmpty) {
      directory = config['folderId']!;
      parent = config['folderParent'] ?? '';
      if (parent.isEmpty) throw const SyncFailure('请选择微云同步目录');
      return;
    }
    final roots = await entries(root: true);
    final name = _folder(config);
    final existing = roots.where((e) => e['dir_name'] == name).toList();
    if (existing.length > 1) throw const SyncFailure('微云存在重名同步文件夹，请更换目录名');
    directory = existing.isEmpty
        ? (await call('create_dir', {
                'pdir_key': parent,
                'dir_name': name,
              }))['dir_key']
              as String
        : existing.single['dir_key'] as String;
    if (parent.isEmpty || directory.isEmpty) {
      throw const SyncFailure('微云未授予文件目录权限');
    }
  }

  @override
  Future<List<String>> list() async =>
      (await entries()).map((e) => e['filename']).whereType<String>().toList();
  @override
  Future<Uint8List?> read(String name) async {
    checkSlotName(name);
    final matches = (await entries())
        .where((e) => e['filename'] == name)
        .toList();
    if (matches.isEmpty) return null;
    if (matches.length > 1) throw const SyncFailure('微云产生了重名快照，暂停同步以避免覆盖');
    final r = await call('download', {
      'items': [
        {
          'file_id': matches.single['file_id'],
          'pdir_key': fileParent.isEmpty ? directory : fileParent,
        },
      ],
    });
    final item = (r['items'] as List).first as Map;
    final response = await http.send(
      'GET',
      item['https_download_url'] as String,
      headers: {'Cookie': item['cookie'] as String? ?? ''},
    );
    if (response.status != 200) throw const SyncFailure('微云快照下载失败');
    return response.bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    final prior = (await entries())
        .where((entry) => entry['filename'] == name)
        .toList();
    if (prior.length > 1) throw const SyncFailure('微云存在重名快照，已停止替换');
    if (prior.isNotEmpty) {
      // The MCP upload tool has no overwrite option. SyncExchange targets only
      // the inactive a/b snapshot, leaving the committed counterpart intact.
      // Remove only this exact app-owned slot, without accumulating trash.
      await call('delete', {
        'file_list': [
          {
            'file_id': prior.single['file_id'],
            'pdir_key': fileParent.isEmpty ? directory : fileParent,
          },
        ],
        'delete_completely': true,
      });
      var removed = false;
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!(await entries()).any((entry) => entry['filename'] == name)) {
          removed = true;
          break;
        }
        if (attempt < 5) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      if (!removed) throw const SyncFailure('微云旧分区尚未更新，请稍后重试');
    }
    final hashes = weiyunUploadHashes(bytes);
    final pre = {
      'filename': name,
      'file_size': bytes.length,
      'pdir_key': directory,
      ...hashes,
    };
    for (var round = 0; round < 512; round++) {
      final r = await call('upload', pre);
      if (r['file_exist'] == true || r['upload_state'] == 2) return;
      final channels = r['channel_list'] as List? ?? [];
      final writable = channels
          .cast<Map>()
          .where((c) => (c['len'] as num) > 0)
          .toList();
      if (writable.isEmpty) throw const SyncFailure('微云未返回上传通道');
      final channel = writable.first;
      final offset = channel['offset'] as int;
      final end = min(bytes.length, offset + (channel['len'] as int));
      if (offset < 0 || end <= offset) throw const SyncFailure('微云上传范围无效');
      final sent = await call('upload', {
        'filename': name,
        'file_size': bytes.length,
        'file_sha': hashes['file_sha'],
        'block_sha_list': [],
        'check_sha': hashes['check_sha'],
        'upload_key': r['upload_key'],
        'channel_list': channels,
        'channel_id': channel['id'],
        'ex': r['ex'],
        'file_data': base64Encode(bytes.sublist(offset, end)),
      });
      if (sent['upload_state'] == 2) return;
    }
    throw const SyncFailure('微云上传尚未完成');
  }

  @override
  void close() => http.close();
}

class AliSyncTransport implements SyncTransport {
  AliSyncTransport(this.config, this.save);
  final Map<String, String> config;
  final SaveSyncCredentials save;
  final http = CloudHttp();
  String access = '', drive = '', directory = '';
  Map<String, String> get headers => {
    'Authorization': 'Bearer $access',
    'Origin': 'https://www.alipan.com',
    'Referer': 'https://www.alipan.com/',
  };
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final result = await http.json(
      'POST',
      'https://api.alipan.com$path',
      headers: headers,
      body: body,
    );
    if (result['code'] != null) throw const SyncFailure('阿里云盘接口拒绝请求，请重新登录');
    return result;
  }

  Future<List<Map<String, dynamic>>> entries(String parent) async {
    final entries = <Map<String, dynamic>>[];
    String marker = '';
    for (var page = 0; page < 50; page++) {
      final r = await post('/v2/file/list', {
        'drive_id': drive,
        'parent_file_id': parent,
        'limit': 200,
        'marker': marker,
        'order_by': 'name',
        'order_direction': 'ASC',
      });
      entries.addAll(
        (r['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
      );
      marker = r['next_marker'] as String? ?? '';
      if (marker.isEmpty) return entries;
    }
    throw const SyncFailure('阿里目录项目过多，请选择专用同步目录');
  }

  Future<void> authenticate() async {
    if (drive.isNotEmpty) return;
    Map token;
    try {
      token = jsonDecode(config['password'] ?? '') as Map;
    } catch (_) {
      throw const SyncFailure('请先通过阿里云盘网页登录');
    }
    access = token['access_token'] as String? ?? '';
    final refresh = token['refresh_token'] as String?;
    if (refresh != null && refresh.isNotEmpty) {
      final r = await http.json(
        'POST',
        'https://auth.alipan.com/v2/account/token',
        body: {'refresh_token': refresh, 'grant_type': 'refresh_token'},
      );
      if (r['access_token'] is! String) throw const SyncFailure('阿里登录失效，请重新登录');
      access = r['access_token'] as String;
      await save({'password': jsonEncode(r)});
    }
    drive = (await post('/v2/user/get', {}))['default_drive_id'] as String;
  }

  @override
  Future<void> prepare() async {
    if (directory.isNotEmpty) return;
    await authenticate();
    if ((config['folderId'] ?? '').isNotEmpty) {
      directory = config['folderId']!;
      return;
    }
    final name = _folder(config);
    final folders = (await entries(
      'root',
    )).where((e) => e['name'] == name).toList();
    if (folders.length > 1) throw const SyncFailure('阿里存在重名同步目录');
    if (folders.isNotEmpty && folders.single['type'] != 'folder') {
      throw const SyncFailure('同名项目不是文件夹');
    }
    directory = folders.isEmpty
        ? (await post('/adrive/v2/file/createWithFolders', {
                'drive_id': drive,
                'parent_file_id': 'root',
                'name': name,
                'type': 'folder',
                'check_name_mode': 'refuse',
              }))['file_id']
              as String
        : folders.single['file_id'] as String;
  }

  @override
  Future<List<String>> list() async => (await entries(directory))
      .map((e) => e['name'])
      .whereType<String>()
      .where(syncSlotPattern.hasMatch)
      .toList();
  @override
  Future<Uint8List?> read(String name) async {
    checkSlotName(name);
    final files = (await entries(
      directory,
    )).where((e) => e['name'] == name).toList();
    if (files.isEmpty) return null;
    if (files.length > 1) throw const SyncFailure('阿里产生重名快照，已暂停同步');
    final url =
        (await post('/v2/file/get_download_url', {
              'drive_id': drive,
              'file_id': files.single['file_id'],
              'expire_sec': 600,
            }))['url']
            as String;
    // These OSS V4 links sign Ali's legacy official download Referer.
    // Substituting the current alipan.com web origin invalidates the signature.
    final r = await http.send(
      'GET',
      url,
      headers: {'Referer': 'https://www.aliyundrive.com/'},
    );
    if (r.status != 200) {
      final diagnostic = utf8.decode(
        r.bytes.take(4096).toList(),
        allowMalformed: true,
      );
      final code = RegExp(
        r'<Code>([A-Za-z][A-Za-z0-9_.-]{0,63})</Code>',
      ).firstMatch(diagnostic)?.group(1);
      throw SyncFailure(
        '阿里快照下载失败（HTTP ${r.status}${code == null ? '' : '，$code'}）',
      );
    }
    return r.bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    checkSlotName(name);
    // Overwrite only the inactive fixed slot. Never implement repeated sync by
    // trashing and recreating files: that would grow the user's recycle bin.
    final prior = (await entries(
      directory,
    )).where((e) => e['name'] == name).toList();
    if (prior.length > 1) throw const SyncFailure('阿里存在重名快照，已暂停同步');
    final created = await post('/adrive/v2/file/createWithFolders', {
      'drive_id': drive,
      'parent_file_id': directory,
      'name': name,
      'type': 'file',
      'size': bytes.length,
      'check_name_mode': 'overwrite',
      'content_hash_name': 'none',
      'proof_version': 'v1',
      'part_info_list': [
        {'part_number': 1},
      ],
    });
    if (created['rapid_upload'] != true) {
      final parts = created['part_info_list'] as List;
      if (parts.length != 1) throw const SyncFailure('阿里返回了不支持的上传分片');
      final r = await http.send(
        'PUT',
        parts.single['upload_url'] as String,
        bytes: bytes,
      );
      if (r.status < 200 || r.status >= 300) {
        throw const SyncFailure('阿里快照上传失败');
      }
      await post('/v2/file/complete', {
        'drive_id': drive,
        'file_id': created['file_id'],
        'upload_id': created['upload_id'],
      });
    }
  }

  @override
  void close() => http.close();
}
