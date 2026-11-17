import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/listening_session.dart';

import 'support/controlled_player.dart';

/// 音源路由收到的每一次请求。
final _sourceRequests = <Uri>[];

/// 本次测试的音源应答；其他路由由 [_handle] 兜底。
Future<http.Response> Function(http.Request request) _sourceResponse =
    (_) async => http.Response('{}', 404);

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<http.Response> _handle(http.Request request) {
  final path = request.url.path;
  if (path.contains('/audio/books/') && path.contains('/chapters/')) {
    _sourceRequests.add(request.url);
    return _sourceResponse(request);
  }
  return Future.value(_json({'code': 0, 'data': <String, Object>{}}, 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // 听书页默认走 ApiClient.instance；在 mock 客户端所在的 Zone 里先把它
    // 建出来，之后所有请求都经过 _handle。
    http.runWithClient(() => ApiClient.instance, () => MockClient(_handle));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    _sourceRequests.clear();
    _sourceResponse = (_) async => http.Response('{}', 404);
  });

  testWidgets('a 404 audio source fails after one request, not three', (
    tester,
  ) async {
    _sourceResponse = (_) async => _json({'error': '章节不存在'}, 404);

    await _mount(tester);
    await _pumpUntil(tester, () => tester.any(find.text('播放出错，请稍后重试')));

    expect(find.text('播放出错，请稍后重试'), findsOneWidget);
    expect(_sourceRequests, hasLength(1), reason: '404 再试也是同一个结果');
  });

  testWidgets('the NO_THIS_TONE fallback uses the same fail-fast policy', (
    tester,
  ) async {
    _sourceResponse = (request) async {
      // tone 0 是这本纯 TTS 书没有的默认音色；换用音色 1 时给 404。
      final tone = request.url.queryParameters['tone_id'];
      if (tone == '0') {
        return _json({'code': 101000, 'message': 'NO_THIS_TONE'}, 200);
      }
      return _json({'error': '章节不存在'}, 404);
    };

    await _mount(tester);
    await _pumpUntil(tester, () => tester.any(find.text('播放出错，请稍后重试')));

    expect(_sourceRequests.map((url) => url.queryParameters['tone_id']), [
      '0',
      '1',
    ], reason: '回退音色的 404 也只请求一次');
  });

  testWidgets('a 5xx audio source is retried and then plays', (tester) async {
    final sourceAttempts = <String, int>{};
    final timePointAttempts = <String, int>{};
    final subtitleAttempts = <String, int>{};
    _sourceResponse = (request) async {
      final itemId = request.url.pathSegments.last;
      final attempt = (sourceAttempts[itemId] ?? 0) + 1;
      sourceAttempts[itemId] = attempt;
      if (itemId == '1' && attempt == 1) {
        return _json({'error': '服务暂不可用'}, 503);
      }
      return _json(_playinfoPayload(itemId), 200);
    };

    final players = <ControlledNativePlayer>[];
    await _mount(
      tester,
      players: players,
      chapters: [
        Chapter(itemId: '1', title: '第1章', volumeName: ''),
        Chapter(itemId: '2', title: '第2章', volumeName: ''),
        Chapter(itemId: '3', title: '第3章', volumeName: ''),
      ],
      subtitleLoader: (itemId, _) async {
        final attempt = (subtitleAttempts[itemId] ?? 0) + 1;
        subtitleAttempts[itemId] = attempt;
        if (itemId != '3' && attempt <= 3) {
          throw const ApiException('temporary', statusCode: 503);
        }
        if (itemId != '1') return SubtitleTrack.empty;
        return const SubtitleTrack([
          SubtitleCue(startMs: 0, text: '恢复后的服务端字幕'),
        ]);
      },
      timePointLoader: (itemId, _) async {
        final attempt = (timePointAttempts[itemId] ?? 0) + 1;
        timePointAttempts[itemId] = attempt;
        if (itemId == '2') {
          throw const ApiException('temporary', statusCode: 503);
        }
        if (itemId == '3') return AudioTimeTrack.empty;
        if (attempt <= 3) {
          throw const ApiException('temporary', statusCode: 503);
        }
        return const AudioTimeTrack([
          AudioSyncPoint(
            startTime: 0,
            startPara: 0,
            startParaOff: 0,
            endPara: 0,
            endParaOff: 1,
          ),
        ], novelItemId: 'novel-1');
      },
    );
    await _pumpUntil(
      tester,
      () =>
          players.isNotEmpty &&
          players.single.isPlaying &&
          timePointAttempts['1'] == 3 &&
          subtitleAttempts['1'] == 3,
      settleMs: 700,
    );

    expect(sourceAttempts['1'], 2, reason: '5xx 值得再取一次');
    expect(players, isNotEmpty);
    expect(players.single.isPlaying, isTrue);
    expect(ListeningSession.instance.novelChapterId, isNull);

    // 初次 3 次都用完后，用户关闭跟随；30 秒后的同章恢复既不能重新打开
    // followArmed，也不能把字幕 fallback 当成时间点已经终态。
    ListeningSession.instance.setFollowArmed(false);
    await tester.pump(const Duration(seconds: 30));
    await _flush(tester);

    expect(timePointAttempts['1'], 4, reason: '同章在低频恢复探测中成功');
    expect(subtitleAttempts['1'], 4, reason: '字幕轨也由同一次恢复探测补齐');
    expect(ListeningSession.instance.novelChapterId, 'novel-1');
    expect(ListeningSession.instance.subtitles?.cues.single.text, '恢复后的服务端字幕');
    expect(ListeningSession.instance.followArmed, isFalse);

    // 第 2 章再次耗尽后立刻换章；旧章的恢复 timer/request 必须一起失效。
    await tester.ensureVisible(find.byTooltip('下一章'));
    await tester.tap(find.byTooltip('下一章'));
    await _flush(tester);
    await _pumpUntil(
      tester,
      () => timePointAttempts['2'] == 3 && subtitleAttempts['2'] == 3,
      settleMs: 700,
    );
    expect(ListeningSession.instance.chapterId, '2');

    // 暂停时连已排好的恢复 timer 也要撤掉；续播同章才按新的 30 秒窗口
    // 重新探测，且只探一次。
    final secondPlayer = players.last;
    await tester.ensureVisible(find.byTooltip('暂停'));
    await tester.tap(find.byTooltip('暂停'));
    await _flush(tester);
    expect(secondPlayer.isPlaying, isFalse);
    await tester.pump(const Duration(seconds: 31));
    await _flush(tester);
    expect(timePointAttempts['2'], 3);
    expect(subtitleAttempts['2'], 3);

    await tester.ensureVisible(find.byTooltip('播放'));
    await tester.tap(find.byTooltip('播放'));
    await _flush(tester);
    expect(secondPlayer.isPlaying, isTrue);
    await tester.pump(const Duration(seconds: 29));
    await _flush(tester);
    expect(timePointAttempts['2'], 3);
    await tester.pump(const Duration(seconds: 1));
    await _flush(tester);
    expect(timePointAttempts['2'], 4);
    expect(subtitleAttempts['2'], 4);

    // 恢复探测再次失败后又排了下一轮；此时换章，旧章不得再发第 5 次请求。
    await tester.ensureVisible(find.byTooltip('下一章'));
    await tester.tap(find.byTooltip('下一章'));
    await _flush(tester);
    await _pumpUntil(
      tester,
      () => ListeningSession.instance.chapterId == '3',
      settleMs: 700,
    );
    await tester.pump(const Duration(seconds: 31));
    await _flush(tester);

    expect(timePointAttempts['2'], 4);
    expect(subtitleAttempts['2'], 4);
    expect(timePointAttempts['3'], 1, reason: '合法空时间轴是终态，不进入周期恢复');
    expect(subtitleAttempts['3'], 1, reason: '合法空字幕也是终态，不进入周期恢复');
  });
}

Map<String, dynamic> _playinfoPayload(String itemId) => {
  'code': 0,
  'data': [
    {
      'main_url': 'https://cdn.example/1.m4a',
      'item_id': itemId,
      'indate': 86400,
      'video_model': jsonEncode({
        'status': 10,
        'media_type': 'audio',
        'video_duration': 42.0,
        'video_list': [
          {'main_url': 'https://cdn.example/1.m4a'},
        ],
      }),
    },
  ],
};

Widget _app(
  List<ControlledNativePlayer> players, {
  List<Chapter>? chapters,
  SubtitleLoader? subtitleLoader,
  TimePointLoader? timePointLoader,
}) => MaterialApp(
  home: AudioPage(
    bookId: 'book',
    title: '测试听书',
    chapters: chapters ?? [Chapter(itemId: '1', title: '第1章', volumeName: '')],
    historyStore: ControlledReaderStore(),
    voicesLoader: () async => const [AudioVoice(id: '1', label: '音色一')],
    extrasLoader: (_) async => const AudioExtras(),
    subtitleLoader: subtitleLoader ?? (_, _) async => SubtitleTrack.empty,
    timePointLoader: timePointLoader ?? (_, _) async => AudioTimeTrack.empty,
    excerptLoader: (_) async => null,
    directoryLoader: (_) async => const [],
    playerFactory: () {
      final player = ControlledNativePlayer();
      players.add(player);
      return player;
    },
  ),
);

Future<void> _mount(
  WidgetTester tester, {
  List<ControlledNativePlayer>? players,
  List<Chapter>? chapters,
  SubtitleLoader? subtitleLoader,
  TimePointLoader? timePointLoader,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    _app(
      players ?? [],
      chapters: chapters,
      subtitleLoader: subtitleLoader,
      timePointLoader: timePointLoader,
    ),
  );
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 等真实 isolate / 网络回调与重试退避都跑完，直到 [done] 成立。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int settleMs = 16,
}) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(Duration(milliseconds: settleMs));
  }
  expect(done(), isTrue);
}
