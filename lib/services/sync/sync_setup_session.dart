import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../platform_channel.dart';
import 'cloud_sync_transport.dart';
import 'multi_device_sync_service.dart';
import 'sync_folder_name.dart';
import 'sync_transport.dart';

class SyncFolder {
  const SyncFolder(this.id, this.name, {this.parent = '', this.path = ''});
  final String id, name, parent, path;
}

abstract interface class SyncSetupSession {
  SyncFolder get root;
  Map<String, String> get config;
  Future<List<SyncFolder>> folders(SyncFolder parent);
  Future<SyncFolder> createFolder(SyncFolder parent, String name);
  Map<String, String> select(SyncFolder folder);
  void close();
}

typedef SyncSetupFactory =
    Future<SyncSetupSession> Function(Map<String, String>);

Future<SyncSetupSession> openSyncSetup(Map<String, String> values) async {
  final session = _SetupSession(Map.of(values));
  try {
    await session.connect();
    return session;
  } catch (_) {
    session.close();
    rethrow;
  }
}

class _SetupSession implements SyncSetupSession {
  _SetupSession(this.config);
  @override
  final Map<String, String> config;
  String get provider => config['provider']!;
  bool get cloud => !{'webdav', 'ftp', 'ftps', 'smb'}.contains(provider);
  @override
  late SyncFolder root;
  WebDavSyncTransport? dav;
  WeiyunSyncTransport? weiyun;
  AliSyncTransport? ali;
  AndroidCloudSyncTransport? android;

  Future<void> saveCredentials(Map<String, String> updates) async {
    config.addAll(updates);
    final profile = config['profile'];
    if (profile != null) {
      await MultiDeviceSyncService.instance.saveProviderCredentials(
        provider,
        updates,
        profile: profile,
      );
    }
  }

  Future<void> connect() async {
    config.remove('folderId');
    config.remove('folderParent');
    if (!cloud) {
      final address = Uri.tryParse(config['endpoint'] ?? '');
      if (provider == 'webdav' && address?.scheme != 'https') {
        throw const SyncFailure('WebDAV 同步目录需要 HTTPS');
      }
      if (address == null ||
          address.host.isEmpty ||
          address.userInfo.isNotEmpty ||
          address.hasQuery ||
          address.hasFragment ||
          !(provider == 'webdav' ? {'https'} : {provider}).contains(
            address.scheme,
          )) {
        throw const SyncFailure('请输入完整的服务器地址');
      }
      final uri = address.replace(
        path: address.path.endsWith('/') ? address.path : '${address.path}/',
      );
      root = SyncFolder('$uri', '服务器目录', path: uri.path);
      if (provider == 'webdav') {
        dav = WebDavSyncTransport(
          '$uri',
          config['username'] ?? '',
          config['password'] ?? '',
        );
      }
      return;
    }
    if (provider == 'weiyun') {
      weiyun = WeiyunSyncTransport(config);
      await weiyun!.entries(root: true);
      root = SyncFolder(weiyun!.parent, '授权目录', path: '/');
    } else if (provider == 'ali') {
      ali = AliSyncTransport(config, saveCredentials);
      await ali!.authenticate();
      root = const SyncFolder('root', '我的网盘', path: '/');
    } else {
      android = AndroidCloudSyncTransport(config, saveCredentials);
      await android!.open();
      root = SyncFolder(
        switch (provider) {
          'tianyi' => '-11',
          'mobile139' => '/',
          _ => '',
        },
        '我的网盘',
        path: '/',
      );
    }
  }

  SyncFolder _child(SyncFolder parent, String id, String name) => SyncFolder(
    id,
    name,
    parent: parent.id,
    path:
        '${parent.path.endsWith('/') ? parent.path : '${parent.path}/'}$name/',
  );

  @override
  Future<List<SyncFolder>> folders(SyncFolder parent) async {
    final List<SyncFolder> result;
    if (dav != null) {
      final uri = Uri.parse(parent.id);
      final response = await dav!.request(
        'PROPFIND',
        uri,
        headers: {
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        bytes: Uint8List.fromList(
          utf8.encode(
            '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
          ),
        ),
      );
      if (response.status != 207) {
        throw SyncFailure('目录读取失败（HTTP ${response.status}），请检查登录信息');
      }
      final xml = XmlDocument.parse(utf8.decode(response.bytes));
      final byId = <String, SyncFolder>{};
      for (final entry in xml.findAllElements(
        'response',
        namespaceUri: 'DAV:',
      )) {
        if (entry.findAllElements('collection', namespaceUri: 'DAV:').isEmpty) {
          continue;
        }
        final href = entry.getElement('href', namespaceUri: 'DAV:')?.innerText;
        if (href == null) continue;
        final target = uri.resolve(href).normalizePath();
        if (target.userInfo.isNotEmpty ||
            target.hasQuery ||
            target.hasFragment) {
          continue;
        }
        final segments = target.pathSegments
            .where((s) => s.isNotEmpty)
            .toList();
        final base = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (target.origin != uri.origin ||
            segments.length != base.length + 1 ||
            !target.path.startsWith(uri.path)) {
          continue;
        }
        final folder = _child(
          parent,
          '${target.replace(path: '${target.path.replaceFirst(RegExp(r'/+$'), '')}/')}',
          segments.last,
        );
        byId[folder.id] = folder;
      }
      result = byId.values.toList();
    } else if (!cloud) {
      final rows =
          await const AppMethodChannel(
            'fqapp/sync_storage',
          ).invokeMethod<List>('folders', {...config, 'endpoint': parent.id}) ??
          [];
      result = [
        for (final row in rows)
          _child(
            parent,
            '${Uri.parse(parent.id).resolve('${Uri.encodeComponent(row as String)}/')}',
            row,
          ),
      ];
    } else if (weiyun != null) {
      final List<Map<String, dynamic>> rows;
      if (parent.id == root.id) {
        rows = await weiyun!.entries(root: true);
      } else {
        weiyun!
          ..parent = parent.parent
          ..directory = parent.id;
        rows = await weiyun!.entries();
      }
      result = [
        for (final row in rows)
          if (row['dir_key'] is String && row['dir_name'] is String)
            _child(parent, row['dir_key'] as String, row['dir_name'] as String),
      ];
    } else if (ali != null) {
      result = [
        for (final row in await ali!.entries(parent.id))
          if (row['type'] == 'folder')
            _child(parent, row['file_id'] as String, row['name'] as String),
      ];
    } else {
      final rows =
          await android!.call<List>('folders', {'parent': parent.id}) ?? [];
      result = [
        for (final row in rows)
          _child(parent, (row as Map)['id'] as String, row['name'] as String),
      ];
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  @override
  Future<SyncFolder> createFolder(SyncFolder parent, String name) async {
    name = name.trim();
    validateSyncFolderName(name);
    if ((await folders(parent)).any((folder) => folder.name == name)) {
      throw const SyncFailure('目录已存在，请直接选择');
    }
    String id;
    if (!cloud) {
      id = '${Uri.parse(parent.id).resolve('${Uri.encodeComponent(name)}/')}';
      if (dav != null) {
        final response = await dav!.request('MKCOL', Uri.parse(id));
        if (response.status != 201) {
          throw SyncFailure('新建目录失败（HTTP ${response.status}）');
        }
      } else {
        await const AppMethodChannel(
          'fqapp/sync_storage',
        ).invokeMethod<void>('createFolder', {...config, 'endpoint': id});
      }
    } else if (weiyun != null) {
      id =
          (await weiyun!.call('create_dir', {
                'pdir_key': parent.id,
                'dir_name': name,
              }))['dir_key']
              as String;
    } else if (ali != null) {
      id =
          (await ali!.post('/adrive/v2/file/createWithFolders', {
                'drive_id': ali!.drive,
                'parent_file_id': parent.id,
                'name': name,
                'type': 'folder',
                'check_name_mode': 'refuse',
              }))['file_id']
              as String;
    } else {
      id = (await android!.call<String>('createFolder', {
        'parent': parent.id,
        'name': name,
      }))!;
    }
    return _child(parent, id, name);
  }

  @override
  Map<String, String> select(SyncFolder folder) => {
    ...config,
    'endpoint': cloud ? folder.path : folder.id,
    if (cloud) 'folderId': folder.id,
    if (cloud) 'folderParent': folder.parent,
  };

  @override
  void close() {
    dav?.close();
    weiyun?.close();
    ali?.close();
    android?.close();
  }
}
