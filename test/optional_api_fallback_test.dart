import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/api_client.dart';

typedef _OptionalLoader = ({
  String name,
  Future<bool> Function(ApiClient) isEmpty,
  Map<String, dynamic> success,
});

void main() {
  final loaders = <_OptionalLoader>[
    (
      name: 'chapter timeline',
      isEmpty: (api) async => (await api.chapterTimeline('chapter')).isEmpty,
      success: {
        'code': 0,
        'data': {'speech_text': '[0,0]<0,0,0>字幕'},
      },
    ),
    (
      name: 'chapter ideas',
      isEmpty: (api) async => (await api.chapterIdeas('chapter')).isEmpty,
      success: {
        'code': 0,
        'data': {
          'data': {
            '1': {'count': 3},
          },
        },
      },
    ),
    (
      name: 'search suggestions',
      isEmpty: (api) async => (await api.searchSuggestions('query')).isEmpty,
      success: {
        'code': 0,
        'data': {
          'query_result': ['suggestion'],
        },
      },
    ),
    (
      name: 'hot search',
      isEmpty: (api) async => (await api.hotSearch()).isEmpty,
      success: {
        'code': 0,
        'data': [
          {
            'search_tag_data': [
              {'tag_title': 'popular'},
            ],
          },
        ],
      },
    ),
    (
      name: 'rank catalogue',
      isEmpty: (api) async => (await api.rankCatalog()).isEmpty,
      success: {
        'code': 0,
        'data': {
          'cell_id_str': 'rank',
          'rank_with_category_data': {
            'rank_algo_list': [
              {'rank_name': '榜单', 'rank_algo': 1},
            ],
          },
        },
      },
    ),
    (
      name: 'chapter summaries',
      isEmpty: (api) async =>
          (await api.chapterSummaries('book', ['chapter'])).isEmpty,
      success: {
        'code': 0,
        'data': {
          'summary_item_data': [
            {'item_id': 'chapter', 'summary': '正文预览'},
          ],
        },
      },
    ),
    (
      name: 'series detail',
      isEmpty: (api) async => (await api.seriesDetail('series')).isEmpty,
      success: {
        'code': 0,
        'data': {
          'video_data': {'series_id_str': 'series', 'series_title': '剧集'},
        },
      },
    ),
  ];

  for (final loader in loaders) {
    group(loader.name, () {
      for (final failure in [
        (name: 'HTTP error', status: 500, body: '{"message":"unavailable"}'),
        (name: 'invalid JSON', status: 200, body: '<html>bad gateway</html>'),
        (
          name: 'upstream unavailable',
          status: 200,
          body: '{"code":1301008,"message":"no available speech text"}',
        ),
      ]) {
        test(
          '${failure.name} follows the optional-call failure contract',
          () async {
            final transport = MockClient(
              (_) async => http.Response.bytes(
                utf8.encode(failure.body),
                failure.status,
              ),
            );
            addTearDown(transport.close);
            final api = ApiClient(
              client: transport,
              baseUrl: 'http://localhost',
            );

            final result = loader.isEmpty(api);
            if (loader.name == 'chapter timeline' &&
                failure.name != 'upstream unavailable') {
              if (failure.name == 'invalid JSON') {
                await expectLater(result, throwsFormatException);
              } else {
                await expectLater(result, throwsA(isA<ApiException>()));
              }
            } else {
              expect(await result, isTrue);
            }
          },
        );
      }

      test('connection failure follows the optional-call contract', () async {
        final transport = MockClient((request) async {
          throw http.ClientException('connection refused', request.url);
        });
        addTearDown(transport.close);
        final result = loader.isEmpty(ApiClient(client: transport));
        if (loader.name == 'chapter timeline') {
          await expectLater(result, throwsA(isA<http.ClientException>()));
        } else {
          expect(await result, isTrue);
        }
      });

      test('valid data still produces a nonempty result', () async {
        final transport = MockClient(
          (_) async =>
              http.Response.bytes(utf8.encode(jsonEncode(loader.success)), 200),
        );
        addTearDown(transport.close);
        expect(await loader.isEmpty(ApiClient(client: transport)), isFalse);
      });
    });
  }

  test('required detail errors remain visible to the caller', () async {
    final transport = MockClient(
      (_) async => http.Response('{"message":"unavailable"}', 500),
    );
    addTearDown(transport.close);
    final api = ApiClient(client: transport);
    await expectLater(api.bookDetail('book'), throwsA(isA<ApiException>()));
  });
}
