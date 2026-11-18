import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/webdav_sync_document.dart';
import 'package:fqapp/services/sync/sync_document.dart';
import 'package:fqapp/services/sync/upstream_webdav_exchange.dart';
import 'package:fqapp/services/webdav_client.dart';

void main() {
  test('WebDAV projection keeps the AI container opaque', () async {
    const opaque = 'opaque-ai-container-not-gzip:中文:%%%';
    final dav = _TestDav()
      ..public.seed(
        WebDavSyncDocument(
          LibraryBackup.capture(
            shelf: const [],
            history: [
              {'id': 'remote', 'kind': 'book', 'time': 1},
            ],
            watched: const {},
            aiData: opaque,
          ),
        ).encode(),
      );
    final local = SyncDocument()
      ..change(
        'h|book|local',
        {'id': 'local', 'kind': 'book', 'time': 2},
        actor: '11111111111111111111111111111111',
        wall: 2,
      );
    final exchange = dav.exchange();
    try {
      await exchange.sync(local);
    } finally {
      exchange.close();
    }

    final projected = WebDavSyncDocument.decode(dav.public.bytes!);
    expect(projected.backup.aiData, opaque);
    expect(projected.backup.history.map((row) => row['id']), contains('local'));
    expect(dav.public.writes, greaterThan(0));
  });

  test('rejects a corrupt outer WebDAV container before any PUT', () async {
    final dav = _TestDav()
      ..public.seed(Uint8List.fromList(utf8.encode('{broken')));
    final exchange = dav.exchange();
    try {
      await expectLater(
        exchange.preview(SyncDocument()),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('DAV_JSON'),
          ),
        ),
      );
    } finally {
      exchange.close();
    }
    expect(dav.public.writes + dav.journal.writes, 0);
  });

  test('rejects a public WebDAV container over 20 MB', () {
    final oversized = Uint8List(20 * 1024 * 1024 + 1);
    expect(
      () => WebDavSyncDocument.decode(oversized),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('DAV_SIZE'),
        ),
      ),
    );
  });
}

const _config = WebDavConfig(
  directory: 'https://dav.example.com/books/',
  username: 'reader',
  password: 'secret',
  enabled: false,
);

class _TestDav {
  final public = _TestDavResource();
  final journal = _TestDavResource();

  UpstreamWebDavExchange exchange() => UpstreamWebDavExchange(
    WebDavClient(_config, client: MockClient(public.handle)),
    WebDavClient(
      _config,
      forSyncMetadata: true,
      client: MockClient(journal.handle),
    ),
  );
}

class _TestDavResource {
  Uint8List? bytes;
  int version = 0;
  int writes = 0;

  void seed(Uint8List value) {
    bytes = value;
    version++;
  }

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'GET') {
      final value = bytes;
      return value == null
          ? http.Response('', 404)
          : http.Response.bytes(value, 200, headers: {'etag': '"$version"'});
    }
    if (request.method != 'PUT') return http.Response('', 405);
    writes++;
    final existed = bytes != null;
    if ((!existed && request.headers['if-none-match'] != '*') ||
        (existed && request.headers['if-match'] != '"$version"')) {
      return http.Response('', 412);
    }
    bytes = request.bodyBytes;
    version++;
    return http.Response('', existed ? 204 : 201);
  }
}
