import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/services/secure_key_provider.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureKeys = MethodChannel('fqapp/secure_keys');
  setUp(() {
    setSingleChapterPrefs({'reader_page_mode': 'scroll'});
    SecureKeyProvider.instance.resetForTest();
    // Opening Shuqi now initializes the encrypted chapter catalogue. Resolve
    // its platform dependency instead of leaving a native-key timeout pending.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureKeys, (call) async {
          if (call.method == 'read') return base64Encode(List.filled(32, 7));
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureKeys, null);
    SecureKeyProvider.instance.resetForTest();
  });
  testWidgets('a toc failure keeps the book detail and offers a retry', (
    tester,
  ) async {
    var tocCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ShuqiDetailPage(
          bookId: '34078',
          bookLoader: (_) async => {
            'data': {
              'bookId': '34078',
              'name': '凡人修仙传',
              'author': '忘语',
              'intro': '一个普通山村小子',
              'kind': '玄幻',
              'coverUrl': '',
              'wordCount': '2451万字',
              'lastChapter': '第2451章',
              'status': '完结',
              'chapterTotalNum': 2451,
            },
          },
          tocLoader: (_) async {
            tocCalls++;
            if (tocCalls == 1) throw StateError('toc down');
            return {
              'data': {
                'path': 'h5',
                'total': 1,
                'chapters': [
                  {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
                ],
              },
            };
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 详情已经拿到，不能因为目录失败而整页报错。
    expect(find.text('忘语'), findsOneWidget);
    expect(find.text('一个普通山村小子'), findsOneWidget);
    expect(find.text('加载失败，请稍后重试'), findsOneWidget);
    // 「开始阅读」在目录为空时禁用，但详情本身仍然可见。
    expect(find.text('目录未加载'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pumpAndSettle();

    expect(tocCalls, 2);
    expect(find.text('加载失败，请稍后重试'), findsNothing);
    expect(find.text('第1章 山边小村'), findsOneWidget);
    expect(find.text('共 1 章'), findsOneWidget);
  });

  testWidgets('Shuqi resumes saved progress and respects catalogue choices', (
    tester,
  ) async {
    final history = MemoryReaderStore(
      entry: {
        'id': 'shuqi:34078',
        'bookId': 'shuqi:34078',
        'contentId': '34078',
        'source': 'shuqi',
        'kind': 'book',
        'chapterId': '2180323',
        'episode': 0,
        'positionVersion': 2,
        'textOffset': 300,
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ShuqiDetailPage(
          bookId: '34078',
          readerStore: history,
          chapterLoader: (chapter) async => List.generate(
            80,
            (i) => '${chapter.title} 第 $i 段用于验证阅读进度恢复的正文。',
          ).join('\n'),
          bookLoader: (_) async => {
            'data': {
              'bookId': '34078',
              'name': '凡人修仙传',
              'author': '忘语',
              'coverUrl': '',
            },
          },
          tocLoader: (_) async => {
            'data': {
              'path': 'h5',
              'total': 2,
              'chapters': [
                {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
                {'chapterId': '2180323', 'title': '第2章 山中修行', 'isVip': false},
              ],
            },
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('继续阅读'), findsOneWidget);
    await tester.tap(find.text('继续阅读'));
    await tester.pumpAndSettle();

    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.localOnly, isTrue);
    expect(
      reader.startIndex,
      1,
      reason: 'the chapter ID survives index changes',
    );
    expect(reader.readerStore, same(history));
    final position = tester
        .widget<ListView>(find.byKey(const ValueKey('reader-paragraph-list')))
        .controller!;
    expect(position.offset, greaterThan(0));
    expect(history.entry!['textOffset'], 300);
    expect(history.entry!['source'], 'shuqi');
    expect(history.entry!['contentId'], '34078');
    position.jumpTo(700);
    await tester.pump(const Duration(seconds: 2));
    expect(history.entry!['position'], 700);
    expect(history.seconds, 0);

    Navigator.of(tester.element(find.byType(ReaderPage))).pop();
    await tester.pumpAndSettle();
    expect(find.text('继续阅读'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shuqi-chapter-0')));
    await tester.pumpAndSettle();
    final selected = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(selected.startIndex, 0);
    expect(history.entry!['chapterId'], '2180322');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(history.seconds, 0);
  });
}
