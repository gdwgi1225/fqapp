import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// The storage package owns this platform-interface dependency; the existing
// test suite imports it directly to install a controlled in-memory backend.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/webdav_sync_document.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/sync/sync_document.dart';
import 'package:fqapp/services/sync/sync_snapshot.dart';
import 'package:fqapp/services/sync/sync_transport.dart';
import 'package:fqapp/services/sync/multi_device_sync_service.dart';
import 'package:fqapp/services/sync/upstream_webdav_exchange.dart';
import 'package:fqapp/services/webdav_client.dart';

import 'support/secure_key_storage_mock.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

const config = WebDavConfig(
  directory: 'https://dav.example.com/books/',
  username: 'reader',
  password: 'private-password',
  enabled: false,
);

MediaItem item(
  String id, {
  String kind = 'book',
  String source = 'fanqie',
  String? title,
}) => MediaItem(
  id: id,
  kind: kind,
  title: title ?? id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  source: source,
);
LibraryBackup backup({
  List<ShelfRecord> shelf = const [],
  List<Map<String, dynamic>> history = const [],
  Map<String, Map<String, int>> watched = const {},
  String? aiData,
  Map<String, dynamic> groups = const {},
  DateTime? createdAt,
}) => LibraryBackup.capture(
  shelf: shelf,
  history: history,
  watched: watched,
  aiData: aiData,
  groups: groups,
  createdAt: createdAt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reader exposes the exact mist blue background and persists it',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        ReaderThemePreset.mistBlue.backgroundColor,
        const Color(0xFFD8E4F0),
      );
      expect(
        ReaderThemePreset.mistBlue.theme(ThemeData()).scaffoldBackgroundColor,
        const Color(0xFFD8E4F0),
      );
      final prefs = const ReaderPreferences(
        themePreset: ReaderThemePreset.mistBlue,
      );
      await prefs.save();
      expect(
        (await ReaderPreferences.load()).themePreset,
        ReaderThemePreset.mistBlue,
      );
      expect(ReaderThemePreset.light.backgroundColor, const Color(0xFFFAF9F6));
    },
  );

  test(
    'merge keeps the newest position even when the reader went backwards',
    () {
      final older = WebDavSyncDocument(
        backup(
          history: [
            {'id': '123', 'kind': 'book', 'chapterId': 'c9', 'time': 100},
            {
              'id': 'shuqi:123',
              'bookId': 'shuqi:123',
              'contentId': '123',
              'source': 'shuqi',
              'kind': 'book',
              'chapterId': 's9',
              'time': 101,
            },
          ],
        ),
      );
      final newer = WebDavSyncDocument(
        backup(
          history: [
            {'id': '123', 'kind': 'book', 'chapterId': 'c2', 'time': 200},
            {
              'id': 'shuqi:123',
              'bookId': 'shuqi:123',
              'contentId': '123',
              'source': 'shuqi',
              'kind': 'book',
              'chapterId': 's2',
              'time': 201,
            },
            {'id': 'book2', 'kind': 'audio', 'position': 38.5, 'time': 201},
          ],
        ),
      );
      for (final merged in [older.merge(newer), newer.merge(older)]) {
        final decoded = WebDavSyncDocument.decode(merged.encode());
        expect(
          decoded.backup.history.firstWhere(
            (e) => e['id'] == '123' && e['source'] != 'shuqi',
          )['chapterId'],
          'c2',
        );
        expect(
          decoded.backup.history.firstWhere(
            (e) => e['id'] == '123' && e['source'] == 'shuqi',
          )['chapterId'],
          's2',
        );
        expect(decoded.backup.history, hasLength(3));
      }
    },
  );

  test('merge retains AI backup data from either device', () {
    final local = WebDavSyncDocument(
      LibraryBackup.capture(
        shelf: const [],
        history: const [],
        watched: const {},
        aiData: 'local-ai',
      ),
    );
    final remote = WebDavSyncDocument(
      LibraryBackup.capture(
        shelf: const [],
        history: const [],
        watched: const {},
        aiData: 'remote-ai',
      ),
    );

    expect(local.merge(remote).backup.aiData, 'local-ai');
    expect(remote.merge(local).backup.aiData, 'remote-ai');
  });

  test(
    'shelf tombstone defeats an offline copy but permits a later re-add',
    () {
      final old = WebDavSyncDocument(
        backup(
          shelf: [
            ShelfRecord(
              item: item('one'),
              addedAt: DateTime.fromMillisecondsSinceEpoch(100),
            ),
          ],
        ),
      );
      final removed = WebDavSyncDocument(backup(), {'shelf_v1:book:one': 200});
      expect(old.merge(removed).backup.shelf, isEmpty);
      expect(removed.merge(old).backup.shelf, isEmpty);
      final readded = WebDavSyncDocument(
        backup(
          shelf: [
            ShelfRecord(
              item: item('one'),
              addedAt: DateTime.fromMillisecondsSinceEpoch(300),
            ),
          ],
        ),
      );
      expect(removed.merge(readded).backup.shelf.single.item.id, 'one');
    },
  );

  test('creates missing WebDAV collections before retrying upload', () async {
    final methods = <String>[];
    var puts = 0;
    final client = WebDavClient(
      config,
      client: MockClient((request) async {
        methods.add('${request.method} ${request.url.path}');
        if (request.method == 'MKCOL') return http.Response('', 201);
        return http.Response('', ++puts == 1 ? 409 : 201);
      }),
    );
    expect(await client.write(Uint8List(0), null), isTrue);
    expect(methods, [
      'PUT /books/fqapp-sync.json',
      'MKCOL /books/',
      'PUT /books/fqapp-sync.json',
    ]);
    client.close();
  });

  test('reads BOM, legacy empty tombstones and portable backup files', () {
    final original = WebDavSyncDocument(
      backup(
        history: [
          {'id': 'legacy', 'kind': 'book', 'time': 1},
        ],
      ),
    );
    final raw = jsonDecode(utf8.decode(original.encode())) as Map;
    raw.remove('removedShelf');
    final decoded = WebDavSyncDocument.decode(
      Uint8List.fromList(utf8.encode('\uFEFF${jsonEncode(raw)}')),
    );
    expect(decoded.backup.history.single['id'], 'legacy');
    expect(decoded.removedShelf, isEmpty);
    expect(
      WebDavSyncDocument.decode(
        original.backup.encode(),
      ).backup.history.single['id'],
      'legacy',
    );
    raw['removedShelf'] = [];
    expect(
      () => WebDavSyncDocument.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(raw))),
      ),
      throwsFormatException,
    );
  });

  test('rejects unsupported documents and malformed tombstones', () {
    expect(
      () => WebDavSyncDocument.decode(Uint8List.fromList(utf8.encode('{}'))),
      throwsFormatException,
    );
    final raw =
        jsonDecode(utf8.decode(WebDavSyncDocument(backup()).encode())) as Map;
    raw['removedShelf'] = {'unexpected-key': -1};
    expect(
      () => WebDavSyncDocument.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(raw))),
      ),
      throwsFormatException,
    );
  });

  test(
    'uses conditional writes, Basic auth and never follows redirects',
    () async {
      final requests = <http.Request>[];
      final client = WebDavClient(
        config,
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response('{}', 200, headers: {'etag': '"v1"'});
          }
          return http.Response(
            '',
            request.headers['if-match'] == '"v1"' ? 412 : 201,
          );
        }),
      );
      addTearDown(client.close);
      expect((await client.read()).etag, '"v1"');
      expect(await client.write(Uint8List(0), '"v1"'), isFalse);
      expect(await client.write(Uint8List(0), null), isTrue);
      expect(requests.last.headers['if-none-match'], '*');
      expect(requests.first.followRedirects, isFalse);
      for (final request in requests) {
        expect(request.headers['accept-encoding'], 'identity');
      }
      expect(
        requests.first.url.toString(),
        'https://dav.example.com/books/fqapp-sync.json',
      );
      expect(
        requests.first.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('reader:private-password'))}',
      );
    },
  );

  test(
    'authentication, weak ETags, redirects and oversized files fail safely',
    () async {
      for (final response in [
        http.Response('', 401),
        http.Response('', 302),
        http.Response('{}', 200, headers: {'etag': 'W/"v1"'}),
        http.Response('{}', 200),
      ]) {
        final client = WebDavClient(
          config,
          client: MockClient((_) async => response),
        );
        await expectLater(client.read(), throwsA(isA<WebDavException>()));
        client.close();
      }
      final client = WebDavClient(
        config,
        client: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
        client.write(Uint8List(WebDavClient.maxBytes + 1), null),
        throwsA(isA<WebDavException>()),
      );
      client.close();
      expect(
        () => const WebDavConfig(
          directory: 'http://dav.example.com/',
          username: '',
          password: '',
          enabled: false,
        ).fileUri,
        throwsA(isA<WebDavException>()),
      );
    },
  );

  group('unified WebDAV exchange', () {
    late Directory directory;
    late Map<String, String> secureKeys;
    late Map<String, String> flutterSecureValues;
    late _TestDav dav;
    late UpstreamWebDavExchange exchange;
    late _LocalWebDav local;

    setUp(() async {
      flutterSecureValues = {};
      secureKeys = mockSecureKeyStorage(flutterSecureValues);
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('fqapp-webdav-');
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      dav = _TestDav();
      exchange = dav.exchange();
      local = _LocalWebDav();
    });

    tearDown(() async {
      exchange.close();
      await Hive.close().timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <void>[],
      );
      await directory.delete(recursive: true);
    });

    test(
      'legacy WebDAV prefill is review-only until the real service saves',
      () async {
        const activeKey = 'fqapp.multi-device-sync.config.v1';
        const providersKey = 'fqapp.multi-device-sync.providers.v1';
        const profile = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        const active = {
          'provider': 'ftp',
          'enabled': 'false',
          'endpoint': 'ftp://old.example/',
          'username': 'old-user',
          'password': '',
          'profile': profile,
        };
        secureKeys['fqapp.webdav.config.v1'] = jsonEncode({
          ...config.toJson(),
          'enabled': true,
        });
        flutterSecureValues
          ..[activeKey] = jsonEncode(active)
          ..[providersKey] = jsonEncode({'ftp': active});
        final storage = _DelayedSecureStorage(flutterSecureValues);
        FlutterSecureStoragePlatform.instance = storage;
        final nativeBefore = Map<String, String>.of(secureKeys);
        final modernBefore = Map<String, String>.of(flutterSecureValues);
        final service = MultiDeviceSyncService.instance;
        Future<void>? initialization;
        var shutDown = false;

        try {
          initialization = service.initialize();
          final concurrent = service.initialize();
          expect(identical(initialization, concurrent), isTrue);

          await storage.activeConfigReadStarted.future;
          expect(service.ready, isFalse);
          storage.releaseFirstRead.complete();
          await initialization;
          await concurrent;

          expect(service.ready, isTrue);
          expect(service.configFor('webdav'), {
            'provider': 'webdav',
            'endpoint': config.directory,
            'username': config.username,
            'password': config.password,
          });
          expect(service.needsWebDavReview, isTrue);
          expect(service.enabled, isFalse);
          expect(storage.writes, isEmpty);
          expect(secureKeys, nativeBefore);
          expect(flutterSecureValues, modernBefore);
          final activeBefore = Map<String, String>.of(service.config);
          final submitted = Map<String, String>.of(active)..remove('profile');

          await expectLater(
            service.configure({
              'provider': 'webdav',
              'enabled': 'true',
              'endpoint': config.directory,
              'username': config.username,
              'password': config.password,
            }),
            throwsA(
              isA<SyncFailure>().having(
                (error) => error.message,
                'message',
                contains('重新预览'),
              ),
            ),
          );
          expect(service.config, activeBefore);
          expect(service.enabled, isFalse);
          expect(storage.writes, isEmpty);
          expect(secureKeys, nativeBefore);
          expect(flutterSecureValues, modernBefore);

          final syncBox = EncryptedHive.box<dynamic>(
            Hive,
            'multi_device_sync_v1',
          );
          expect(syncBox.isEmpty, isTrue);
          storage.failNextWrite = providersKey;

          await expectLater(
            service.configure(submitted),
            throwsA(isA<StateError>()),
          );

          expect(syncBox.containsKey(profile), isTrue);
          expect(storage.writes, [providersKey]);
          expect(service.config, activeBefore);
          expect(service.enabled, isFalse);
          expect(secureKeys, nativeBefore);
          expect(flutterSecureValues, modernBefore);
          final preparedProfile = syncBox.get(profile) as String;
          final writesBeforePreparedFailure = List<String>.of(storage.writes);

          Future<void> expectRejectedProfile(String encoded) async {
            await syncBox.put(profile, encoded);
            await syncBox.flush();
            await expectLater(
              service.configure(submitted),
              throwsFormatException,
            );
            expect(service.config, activeBefore);
            expect(service.enabled, isFalse);
            expect(storage.writes, writesBeforePreparedFailure);
            expect(secureKeys, nativeBefore);
            expect(flutterSecureValues, modernBefore);
          }

          await expectRejectedProfile('not-json');

          final badBaseline =
              jsonDecode(preparedProfile) as Map<String, dynamic>;
          badBaseline['baseline'] = {
            'x|book|bad-id': {
              'id': 'bad-id',
              'kind': 'book',
              'title': '坏基线',
              'addedAt': 1,
            },
          };
          await expectRejectedProfile(jsonEncode(badBaseline));

          final badDocument =
              jsonDecode(preparedProfile) as Map<String, dynamic>;
          final actor = badDocument['actor'] as String;
          badDocument['document'] = {
            'vector': {actor: 1},
            'records': {
              's|book|foreign-id': [
                {
                  'actor': actor,
                  'counter': 1,
                  'wall': 1,
                  'seen': <String, int>{},
                  'value': {
                    'id': 'foreign-id',
                    'kind': 'book',
                    'title': '非番茄记录',
                    'cover': '',
                    'author': '',
                    'badge': '',
                    'ep': '',
                    'source': 'shuqi',
                    'addedAt': 1,
                  },
                },
              ],
            },
          };
          await expectRejectedProfile(jsonEncode(badDocument));

          final badPending =
              jsonDecode(preparedProfile) as Map<String, dynamic>;
          badPending['pending'] = {
            's|book|pending-id': {
              'id': 'pending-id',
              'kind': 'book',
              'title': '缺收藏时间',
            },
          };
          await expectRejectedProfile(jsonEncode(badPending));

          await syncBox.put(profile, preparedProfile);
          await syncBox.flush();
          await ShelfStore.instance.add(item('kept-local'));
          final successfulConfig = <String, String>{
            ...active,
            'endpoint': 'ftp://new.example/',
          }..remove('profile');
          storage.writes.clear();

          await service.configure(successfulConfig);

          final newProfile = service.config['profile']!;
          expect(newProfile, isNot(profile));
          expect(service.config['endpoint'], 'ftp://new.example/');
          expect(service.config['enabled'], 'false');
          expect(service.enabled, isFalse);
          expect(storage.writes, [providersKey, activeKey]);
          expect(syncBox.containsKey(profile), isTrue);
          expect(syncBox.containsKey(newProfile), isTrue);
          expect(
            jsonDecode(flutterSecureValues[activeKey]!) as Map<String, dynamic>,
            service.config,
          );
          expect(
            (jsonDecode(flutterSecureValues[providersKey]!) as Map)['ftp'],
            service.config,
          );
          expect(secureKeys, nativeBefore);
          expect(ShelfStore.instance.contains('book', 'kept-local'), isTrue);
          final afterConfigure = Map<String, String>.of(flutterSecureValues);

          await service.shutdown();
          shutDown = true;
          expect(flutterSecureValues, afterConfigure);
          expect(syncBox.containsKey(profile), isTrue);
          expect(syncBox.containsKey(newProfile), isTrue);
          expect(ShelfStore.instance.contains('book', 'kept-local'), isTrue);
        } finally {
          if (!storage.releaseFirstRead.isCompleted) {
            storage.releaseFirstRead.complete();
          }
          if (initialization != null) {
            try {
              await initialization;
            } catch (_) {}
          }
          if (!shutDown) await service.shutdown();
        }
      },
    );

    test(
      'preview counts only fanqie records owned by the unified sync domain',
      () async {
        dav.seed(
          WebDavSyncDocument(
            backup(
              shelf: [
                ShelfRecord(
                  item: item('fanqie'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(10),
                ),
                ShelfRecord(
                  item: item('123', source: 'shuqi'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(20),
                ),
              ],
              history: [
                {'id': 'fanqie', 'kind': 'book', 'time': 10},
                {
                  'id': '123',
                  'bookId': '123',
                  'source': 'shuqi',
                  'kind': 'book',
                  'time': 20,
                },
              ],
              watched: {
                'show': {'ep1': 30},
              },
            ),
          ).encode(),
        );

        final preview = await exchange.preview(SyncDocument());
        final scoped = SyncSnapshot.fromBackup(preview.remote!).toBackup();

        expect(scoped.shelf.single.item.id, 'fanqie');
        expect(scoped.history.single['id'], 'fanqie');
        expect(scoped.episodeCount, 1);
        final merged = SyncSnapshot.fromDocument(preview.document).values;
        expect(merged.keys, contains('s|book|fanqie'));
        expect(merged.keys, isNot(contains('s|book|123')));
      },
    );

    test('opaque cloud AI survives sync without local decoding', () async {
      // Sync must treat legacy AI data as opaque, even when it is not a
      // valid AI payload and therefore cannot be restored locally.
      const opaqueAi = 'opaque-ai-from-legacy-service';
      dav.seed(
        WebDavSyncDocument(
          backup(
            shelf: [
              ShelfRecord(
                item: item('cloud'),
                addedAt: DateTime.fromMillisecondsSinceEpoch(10),
              ),
            ],
            aiData: opaqueAi,
          ),
        ).encode(),
      );
      await ShelfStore.instance.add(item('local'));

      await local.sync(exchange);

      final remote = WebDavSyncDocument.decode(dav.public.bytes!);
      expect(remote.backup.aiData, opaqueAi);
      expect(
        ShelfStore.instance.records().map((record) => record.item.id).toSet(),
        {'cloud', 'local'},
      );
    });

    test(
      'fanqie sync preserves legacy owners, groups and local assignments',
      () async {
        final groups = ShelfGroupStore.instance;
        await groups.init();
        final localGroup = await groups.addGroup('本机分类');
        await groups.assignMany([item('local-assigned')], localGroup);
        final remoteGroups = {
          'version': 1,
          'groups': {
            'gcloud-1': {'name': '云端分类', 'at': 1, 'deleted': false},
          },
          'assignments': {
            'book:cloud': {'group': 'gcloud-1', 'at': 1},
          },
        };
        dav.seed(
          WebDavSyncDocument(
            backup(
              shelf: [
                ShelfRecord(
                  item: item('cloud'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(10),
                ),
                ShelfRecord(
                  item: item('123', source: 'shuqi'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(20),
                ),
              ],
              history: [
                {'id': 'fanqie', 'kind': 'book', 'time': 10},
                {
                  'id': '123',
                  'bookId': '123',
                  'source': 'shuqi',
                  'kind': 'book',
                  'time': 20,
                },
              ],
              groups: remoteGroups,
            ),
          ).encode(),
        );
        await LibraryStore.instance.addHistory({
          'id': 'new-history',
          'kind': 'book',
          'time': 30,
        });

        await local.sync(exchange);

        final remote = WebDavSyncDocument.decode(dav.public.bytes!);
        expect(remote.backup.shelf.map((record) => record.item.id).toSet(), {
          'cloud',
          '123',
        });
        expect(
          remote.backup.history.singleWhere(
            (record) => record['source'] == 'shuqi',
          )['id'],
          '123',
        );
        expect(remote.backup.groups, remoteGroups);
        expect(groups.groups[localGroup], '本机分类');
        expect(groups.groupOf(item('local-assigned')), localGroup);
      },
    );

    test(
      'an older cloud record cannot overwrite newer local shelf or progress',
      () async {
        await _putShelf(item('same', title: '本机新标题'), addedAt: 900);
        await LibraryStore.instance.addHistory({
          'id': 'progress',
          'kind': 'book',
          'chapterId': 'local-new',
          'time': 900,
        });
        dav.seed(
          WebDavSyncDocument(
            backup(
              shelf: [
                ShelfRecord(
                  item: item('same', title: '云端旧标题'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(100),
                ),
              ],
              history: [
                {
                  'id': 'progress',
                  'kind': 'book',
                  'chapterId': 'cloud-old',
                  'time': 100,
                },
              ],
            ),
          ).encode(),
        );

        await local.sync(exchange);

        expect(ShelfStore.instance.records().single.item.title, '本机新标题');
        expect(
          (await LibraryStore.instance.historyEntry('progress'))?['chapterId'],
          'local-new',
        );
        final remote = WebDavSyncDocument.decode(dav.public.bytes!);
        expect(remote.backup.shelf.single.item.title, '本机新标题');
        expect(remote.backup.history.single['chapterId'], 'local-new');
      },
    );

    test('a later reader rewind supersedes the older synced chapter', () async {
      dav.seed(
        WebDavSyncDocument(
          backup(
            history: [
              {
                'id': 'progress',
                'kind': 'book',
                'chapterId': 'chapter-9',
                'time': 900,
              },
            ],
          ),
        ).encode(),
      );
      await local.sync(exchange);
      expect(
        (await LibraryStore.instance.historyEntry('progress'))?['chapterId'],
        'chapter-9',
      );

      await LibraryStore.instance.addHistory({
        'id': 'progress',
        'kind': 'book',
        'chapterId': 'chapter-2',
        'time': 100,
      });
      await local.sync(exchange);

      expect(
        (await LibraryStore.instance.historyEntry('progress'))?['chapterId'],
        'chapter-2',
      );
      expect(
        WebDavSyncDocument.decode(
          dav.public.bytes!,
        ).backup.history.single['chapterId'],
        'chapter-2',
      );
    });

    test(
      'local-only and source-qualified records survive fanqie application',
      () async {
        final imported = item('local_100_abcd');
        final shuqi = item('123', source: 'shuqi');
        await ShelfStore.instance.add(imported);
        await ShelfStore.instance.add(shuqi);
        dav.seed(
          WebDavSyncDocument(
            backup(
              shelf: [
                ShelfRecord(
                  item: item('cloud'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(10),
                ),
              ],
            ),
          ).encode(),
        );

        await local.sync(exchange);

        expect(
          ShelfStore.instance.records().map((record) => record.item.id).toSet(),
          {'local_100_abcd', '123', 'cloud'},
        );
        expect(
          WebDavSyncDocument.decode(
            dav.public.bytes!,
          ).backup.shelf.map((record) => record.item.id),
          ['cloud'],
        );
      },
    );

    test(
      'legacy history migrates before the first sync document is published',
      () async {
        SharedPreferences.setMockInitialValues({
          'hist': jsonEncode([
            {
              'id': 'legacy',
              'title': '旧版进度',
              'chapterId': 'chapter-3',
              'position': 42,
              'time': 100,
            },
          ]),
        });
        await LibraryStore.instance.init();

        await local.sync(exchange);

        final remote = WebDavSyncDocument.decode(dav.public.bytes!);
        expect(remote.backup.history.single['id'], 'legacy');
        expect(remote.backup.history.single['kind'], 'book');
        expect(remote.backup.history.single['chapterId'], 'chapter-3');
        expect(
          (await LibraryStore.instance.historyEntry('legacy'))?['position'],
          42,
        );
      },
    );

    test(
      'a fresh upload journals its proposal before the public file',
      () async {
        await ShelfStore.instance.add(item('local'));

        await local.sync(exchange);

        expect(dav.public.writes, 1);
        expect(dav.journal.writes, 2);
        expect(dav.log.where((entry) => entry.endsWith('PUT')).toList(), [
          'journal PUT',
          'public PUT',
          'journal PUT',
        ]);
        expect(
          WebDavSyncDocument.decode(
            dav.public.bytes!,
          ).backup.shelf.single.item.id,
          'local',
        );
      },
    );

    test(
      'a fresh device conditionally applies the online fanqie shelf',
      () async {
        dav.seed(
          WebDavSyncDocument(
            backup(
              shelf: [
                ShelfRecord(
                  item: item('from-other-device'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(10),
                ),
              ],
            ),
          ).encode(),
        );
        expect(ShelfStore.instance.records(), isEmpty);

        await local.sync(exchange);

        expect(
          ShelfStore.instance.records().single.item.id,
          'from-other-device',
        );
      },
    );

    test(
      'preview is read-only and a later confirmed sync applies the merge',
      () async {
        await ShelfStore.instance.add(item('local-only'));
        dav.seed(
          WebDavSyncDocument(
            backup(
              shelf: [
                ShelfRecord(
                  item: item('cloud-only'),
                  addedAt: DateTime.fromMillisecondsSinceEpoch(10),
                ),
              ],
            ),
          ).encode(),
        );
        await local.capture();
        final publicBefore = dav.public.bytes!.toList();
        final journalBefore = dav.journal.bytes?.toList();

        final preview = await exchange.preview(local.document.copy());

        expect(dav.public.bytes, orderedEquals(publicBefore));
        if (journalBefore == null) {
          expect(dav.journal.bytes, isNull);
        } else {
          expect(dav.journal.bytes, orderedEquals(journalBefore));
        }
        expect(dav.public.writes, 0);
        expect(dav.journal.writes, 0);
        expect(
          SyncSnapshot.fromDocument(preview.document).values.keys,
          containsAll(<String>['s|book|local-only', 's|book|cloud-only']),
        );

        await local.sync(exchange);
        expect(
          ShelfStore.instance.records().map((record) => record.item.id).toSet(),
          {'local-only', 'cloud-only'},
        );
        expect(
          WebDavSyncDocument.decode(
            dav.public.bytes!,
          ).backup.shelf.map((record) => record.item.id).toSet(),
          {'local-only', 'cloud-only'},
        );
      },
    );

    test(
      'offline history deletion is retained and uploaded on retry',
      () async {
        dav.seed(
          WebDavSyncDocument(
            backup(
              history: [
                {'id': 'one', 'kind': 'book', 'time': 1},
              ],
            ),
          ).encode(),
        );
        await local.sync(exchange);
        await LibraryStore.instance.removeHistoryEntry('one', 'book');
        final publicBefore = dav.public.bytes!.toList();

        dav.offline = true;
        await expectLater(
          local.sync(exchange),
          throwsA(isA<WebDavException>()),
        );
        expect(dav.public.bytes, orderedEquals(publicBefore));
        expect(await LibraryStore.instance.historyEntry('one'), isNull);

        dav.offline = false;
        await local.sync(exchange);
        expect(
          WebDavSyncDocument.decode(dav.public.bytes!).backup.history,
          isEmpty,
        );
      },
    );

    test(
      'a pending offline deletion survives a sync document restart',
      () async {
        dav.seed(
          WebDavSyncDocument(
            backup(
              history: [
                {'id': 'one', 'kind': 'book', 'time': 1},
              ],
            ),
          ).encode(),
        );
        await local.sync(exchange);
        await LibraryStore.instance.removeHistoryEntry('one', 'book');
        dav.offline = true;
        await expectLater(
          local.sync(exchange),
          throwsA(isA<WebDavException>()),
        );

        local = _LocalWebDav(
          document: SyncDocument.fromJson(
            jsonDecode(jsonEncode(local.document.toJson()))
                as Map<String, dynamic>,
          ),
          baseline: SyncSnapshot({
            for (final entry in local.baseline.values.entries)
              entry.key: Map<String, dynamic>.from(entry.value),
          }),
          journalEstablished: true,
        );
        dav.offline = false;
        await local.sync(exchange);

        expect(
          WebDavSyncDocument.decode(dav.public.bytes!).backup.history,
          isEmpty,
        );
        expect(await LibraryStore.instance.historyEntry('one'), isNull);
      },
    );

    test(
      'fanqie shelf removal uses a tombstone and preserves legacy owners',
      () async {
        final fanqie = item('fanqie');
        final legacy = item('123', source: 'shuqi');
        dav.seed(
          WebDavSyncDocument(
            backup(
              shelf: [
                ShelfRecord(
                  item: fanqie,
                  addedAt: DateTime.fromMillisecondsSinceEpoch(100),
                ),
                ShelfRecord(
                  item: legacy,
                  addedAt: DateTime.fromMillisecondsSinceEpoch(100),
                ),
              ],
            ),
          ).encode(),
        );
        await local.sync(exchange);
        await ShelfStore.instance.removeKeys([ShelfStore.keyOf(fanqie)]);

        await local.sync(exchange);

        final remote = WebDavSyncDocument.decode(dav.public.bytes!);
        expect(remote.backup.shelf.single.item.id, legacy.id);
        expect(remote.removedShelf.keys, [ShelfStore.keyOf(fanqie)]);
        expect(ShelfStore.instance.containsItem(fanqie), isFalse);
      },
    );

    test(
      'a conditional conflict keeps the deletion and remote addition',
      () async {
        dav.seed(
          WebDavSyncDocument(
            backup(
              history: [
                {'id': 'one', 'kind': 'book', 'time': 1},
              ],
            ),
          ).encode(),
        );
        await local.sync(exchange);
        await LibraryStore.instance.removeHistoryEntry('one', 'book');
        dav.public.injectBeforeWrite = WebDavSyncDocument(
          backup(
            history: [
              {'id': 'one', 'kind': 'book', 'time': 1},
              {'id': 'two', 'kind': 'book', 'time': 2},
            ],
          ),
        ).encode();

        await local.sync(exchange);

        final remote = WebDavSyncDocument.decode(dav.public.bytes!);
        expect(remote.backup.history.map((record) => record['id']), ['two']);
        expect(await LibraryStore.instance.historyEntry('one'), isNull);
        expect((await LibraryStore.instance.historyEntry('two'))?['id'], 'two');
      },
    );

    test(
      'forgetting watched episodes does not delete unrelated history',
      () async {
        dav.seed(
          WebDavSyncDocument(
            backup(
              history: [
                {'id': 'show', 'kind': 'video', 'time': 1},
              ],
              watched: {
                'show': {'ep1': 1},
              },
            ),
          ).encode(),
        );
        await local.sync(exchange);
        expect(await LibraryStore.instance.watchedEpisodeIds('show'), {'ep1'});

        await LibraryStore.instance.forgetWatchedEpisodes('show');
        await local.sync(exchange);

        final remote = WebDavSyncDocument.decode(dav.public.bytes!);
        expect(remote.backup.watched, isEmpty);
        expect(remote.backup.history.single['id'], 'show');
        expect(await LibraryStore.instance.historyEntry('show'), isNotNull);
      },
    );

    test(
      'a vanished established cloud file is not recreated from stale state',
      () async {
        dav.seed(
          WebDavSyncDocument(
            backup(
              history: [
                {'id': 'one', 'kind': 'book', 'time': 1},
              ],
            ),
          ).encode(),
        );
        await local.sync(exchange);
        dav.public.remove();

        await expectLater(
          local.sync(exchange),
          throwsA(
            isA<SyncFailure>().having(
              (error) => error.message,
              'message',
              contains('已消失'),
            ),
          ),
        );
        expect(dav.public.bytes, isNull);
        expect(await LibraryStore.instance.historyEntry('one'), isNotNull);
      },
    );

    test(
      'a corrupt merge journal stops before the public file changes',
      () async {
        await ShelfStore.instance.add(item('keep'));
        await local.sync(exchange);
        final publicBefore = dav.public.bytes!.toList();
        dav.journal.bytes = Uint8List.fromList(utf8.encode('not-json'));
        dav.journal.version++;
        await ShelfStore.instance.add(item('new'));

        await expectLater(local.sync(exchange), throwsFormatException);

        expect(dav.public.bytes, orderedEquals(publicBefore));
        expect(ShelfStore.instance.contains('book', 'keep'), isTrue);
        expect(ShelfStore.instance.contains('book', 'new'), isTrue);
      },
    );

    test(
      'invalid remote data never replaces the public file or local shelf',
      () async {
        await ShelfStore.instance.add(item('keep'));
        final invalid = Uint8List.fromList(utf8.encode('not-json'));
        dav.public.bytes = invalid;
        dav.public.version = 1;

        await expectLater(local.sync(exchange), throwsFormatException);

        expect(dav.public.bytes, orderedEquals(invalid));
        expect(ShelfStore.instance.contains('book', 'keep'), isTrue);
      },
    );

    test(
      'conditional shelf application preserves a user tap during sync',
      () async {
        final baseline = SyncSnapshot({});
        final incoming = SyncSnapshot.fromBackup(
          backup(
            shelf: [
              ShelfRecord(
                item: item('cloud'),
                addedAt: DateTime.fromMillisecondsSinceEpoch(10),
              ),
            ],
          ),
        ).toBackup();
        await ShelfStore.instance.add(item('racing'));

        final applied = await ShelfStore.instance.applySyncedRecords(
          incoming: incoming.shelf,
          acceptsCurrent: (shelf) => SyncSnapshot.fromBackup(
            LibraryBackup.capture(shelf: shelf, history: [], watched: {}),
          ).sameDomain(baseline, 's|'),
        );

        expect(applied, isFalse);
        expect(ShelfStore.instance.records().map((record) => record.item.id), [
          'racing',
        ]);
      },
    );

    test(
      'a missing journal after establishment blocks automatic rebuilding',
      () async {
        await ShelfStore.instance.add(item('one'));
        await local.sync(exchange);
        final publicBefore = dav.public.bytes!.toList();
        dav.journal.remove();
        await ShelfStore.instance.add(item('two'));

        await expectLater(
          local.sync(exchange),
          throwsA(
            isA<SyncFailure>().having(
              (error) => error.message,
              'message',
              contains('合并日志已消失'),
            ),
          ),
        );

        expect(dav.public.bytes, orderedEquals(publicBefore));
        expect(ShelfStore.instance.contains('book', 'two'), isTrue);
      },
    );
  });
}

class _LocalWebDav {
  _LocalWebDav({
    SyncDocument? document,
    SyncSnapshot? baseline,
    this.journalEstablished = false,
  }) : document = document ?? SyncDocument(),
       baseline = baseline ?? SyncSnapshot({});

  static const _actor = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  String get actor => _actor;
  SyncDocument document;
  SyncSnapshot baseline;
  bool journalEstablished;
  int _nextWall = 10000;

  Future<SyncSnapshot> current() async {
    final library = await LibraryStore.instance.backupSnapshot();
    return SyncSnapshot.fromBackup(
      LibraryBackup.capture(
        shelf: ShelfStore.instance.records(),
        history: library.history,
        watched: library.watched,
      ),
    );
  }

  Future<void> capture() async {
    final currentSnapshot = await current();
    final firstCapture = document.vector.isEmpty;
    final keys = {...baseline.values.keys, ...currentSnapshot.values.keys};
    for (final key in keys) {
      final value = currentSnapshot.values[key];
      if (syncJson(value) == syncJson(baseline.values[key])) continue;
      final rawWall = value?['time'] ?? value?['addedAt'] ?? value?['at'];
      document.change(
        key,
        value,
        actor: actor,
        wall: firstCapture
            ? rawWall is num
                  ? rawWall.toInt()
                  : 0
            : _nextWall++,
      );
    }
    baseline = currentSnapshot;
  }

  Future<SyncDocument> sync(
    UpstreamWebDavExchange exchange, {
    bool? requireJournal,
  }) async {
    await capture();
    final merged = await exchange.sync(
      document.copy(),
      requireJournal: requireJournal ?? journalEstablished,
    );
    journalEstablished = true;
    await capture();
    merged.merge(document);
    document = merged.copy();
    await apply(SyncSnapshot.fromDocument(document));
    return document.copy();
  }

  Future<bool> apply(SyncSnapshot desired) async {
    final backup = desired.toBackup();
    final shelfApplied = await ShelfStore.instance.applySyncedRecords(
      incoming: backup.shelf,
      acceptsCurrent: (shelf) => SyncSnapshot.fromBackup(
        LibraryBackup.capture(shelf: shelf, history: [], watched: {}),
      ).sameDomain(baseline, 's|'),
    );
    if (shelfApplied) baseline.replaceDomain(desired, 's|');
    final libraryApplied = await LibraryStore.instance.applySyncedRecords(
      history: backup.history,
      watched: backup.watched,
      acceptsCurrent: (history, watched) {
        final current = SyncSnapshot.fromBackup(
          LibraryBackup.capture(shelf: [], history: history, watched: watched),
        );
        return current.sameDomain(baseline, 'h|') &&
            current.sameDomain(baseline, 'w|');
      },
    );
    if (libraryApplied) {
      baseline.replaceDomain(desired, 'h|');
      baseline.replaceDomain(desired, 'w|');
    }
    await capture();
    return shelfApplied && libraryApplied;
  }
}

class _DelayedSecureStorage extends TestFlutterSecureStoragePlatform {
  _DelayedSecureStorage(super.data);

  final activeConfigReadStarted = Completer<void>();
  final releaseFirstRead = Completer<void>();
  final writes = <String>[];
  String? failNextWrite;
  bool _delayed = false;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (!_delayed && key == 'fqapp.multi-device-sync.config.v1') {
      _delayed = true;
      activeConfigReadStarted.complete();
      await releaseFirstRead.future;
    }
    return super.read(key: key, options: options);
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    writes.add(key);
    if (failNextWrite == key) {
      failNextWrite = null;
      throw StateError('secure write failed');
    }
    await super.write(key: key, value: value, options: options);
  }
}

class _TestDav {
  final public = _TestDavResource();
  final journal = _TestDavResource();
  final log = <String>[];
  bool offline = false;

  UpstreamWebDavExchange exchange() => UpstreamWebDavExchange(
    WebDavClient(
      config,
      client: MockClient((request) {
        log.add('public ${request.method}');
        return public.handle(request, offline);
      }),
    ),
    WebDavClient(
      config,
      forSyncMetadata: true,
      client: MockClient((request) {
        log.add('journal ${request.method}');
        return journal.handle(request, offline);
      }),
    ),
  );

  void seed(Uint8List bytes) => public.seed(bytes);
}

class _TestDavResource {
  Uint8List? bytes;
  int version = 0;
  int writes = 0;
  Uint8List? injectBeforeWrite;

  void seed(Uint8List value) {
    bytes = value;
    version++;
  }

  void remove() {
    bytes = null;
    version++;
  }

  Future<http.Response> handle(http.Request request, bool offline) async {
    if (offline) throw http.ClientException('offline');
    if (request.method == 'GET') {
      final value = bytes;
      return value == null
          ? http.Response('', 404)
          : http.Response.bytes(value, 200, headers: {'etag': '"$version"'});
    }
    if (request.method != 'PUT') return http.Response('', 405);
    writes++;
    final injected = injectBeforeWrite;
    if (injected != null) {
      injectBeforeWrite = null;
      seed(injected);
    }
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

Future<void> _putShelf(MediaItem value, {required int addedAt}) async {
  await EncryptedHive.box<dynamic>(
    Hive,
    ShelfStore.boxName,
  ).put(ShelfStore.keyOf(value), {
    'id': value.id,
    'kind': value.kind,
    'title': value.title,
    'cover': value.cover,
    'author': value.author,
    'badge': value.badge,
    'ep': value.ep,
    'addedAt': addedAt,
  });
}
