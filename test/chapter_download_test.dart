import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_download.dart';

/// 不触磁盘的 [ChapterCache]：读永远 miss，写只记账。
class _FakeChapterCache implements ChapterCache {
  final reads = <String>[];
  final writes =
      <
        ({
          String bookId,
          String chapterId,
          String title,
          String text,
          bool pinned,
        })
      >[];
  int saveBookCalls = 0;

  @override
  int get chapterCapacity => 500;

  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async {
    reads.add(chapterId);
    return null;
  }

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    writes.add((
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    ));
  }

  @override
  Future<void> saveBook(CachedBook book) async {
    saveBookCalls++;
  }

  @override
  Future<Set<String>> cachedChapterIds(String bookId) async => {};

  @override
  Future<CachedBook?> cachedBook(String bookId) async => null;

  @override
  Future<CachedBook?> savedCatalogue(String bookId) async => null;
}

CachedBook _book(int chapterCount) => CachedBook(
  id: 'book-1',
  title: '书',
  chapters: [
    for (var i = 1; i <= chapterCount; i++)
      Chapter(itemId: 'c$i', title: '第$i章', volumeName: ''),
  ],
);

void main() {
  test('双启：三章窗口并发预取，按序写盘且再次 start 被忽略', () async {
    final gates = <String, Completer<void>>{
      'c1': Completer<void>(),
      'c2': Completer<void>(),
      'c3': Completer<void>(),
    };
    final entered = <String, Completer<void>>{
      'c1': Completer<void>(),
      'c2': Completer<void>(),
      'c3': Completer<void>(),
    };
    final settled = <String, Completer<void>>{
      'c1': Completer<void>(),
      'c2': Completer<void>(),
      'c3': Completer<void>(),
    };
    final loaderCalls = <String>[];
    var activeLoaders = 0;
    var maxActiveLoaders = 0;
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(6),
      loader: (chapter) async {
        final id = chapter.itemId;
        loaderCalls.add(id);
        activeLoaders++;
        if (activeLoaders > maxActiveLoaders) {
          maxActiveLoaders = activeLoaders;
        }
        entered[id]?.complete();
        try {
          await gates[id]?.future;
          return '正文$id内容……';
        } finally {
          settled[id]?.complete();
          activeLoaders--;
        }
      },
    );
    addTearDown(download.dispose);

    final first = download.start(startIndex: 0, count: 6);
    await Future.wait(entered.values.map((completer) => completer.future));
    expect(loaderCalls, ['c1', 'c2', 'c3']);
    expect(maxActiveLoaders, 3);
    expect(download.value.running, isTrue);

    // 第二次 start 在运行中：立即返回，不填充第四个 loader，不重置进度。
    final callsBeforeSecondStart = List<String>.of(loaderCalls);
    await download.start(startIndex: 0, count: 6);
    expect(loaderCalls, callsBeforeSecondStart);

    // 后两章先返回，仍必须等 c1；未提交前不能写盘或推进计数。
    gates['c2']!.complete();
    gates['c3']!.complete();
    await Future.wait([settled['c2']!.future, settled['c3']!.future]);
    expect(cache.writes, isEmpty);
    expect(download.value.completed, 0);

    gates['c1']!.complete();
    await first;
    expect(loaderCalls, ['c1', 'c2', 'c3', 'c4', 'c5', 'c6']);
    expect(maxActiveLoaders, 3);
    expect(
      [for (final write in cache.writes) write.chapterId],
      ['c1', 'c2', 'c3', 'c4', 'c5', 'c6'],
    );
    expect(download.value.running, isFalse);
    expect(download.value.completed, 6);
    expect(download.value.total, 6);
    expect(download.value.message, isNotNull);
  });

  test('取消：未消费预取错误被吸收，门开后不补任务也不落盘', () async {
    final gate = Completer<void>();
    final entered = <String, Completer<void>>{
      'c1': Completer<void>(),
      'c2': Completer<void>(),
      'c3': Completer<void>(),
    };
    final loaderCalls = <String>[];
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(6),
      loader: (chapter) async {
        final id = chapter.itemId;
        loaderCalls.add(id);
        entered[id]?.complete();
        if (id == 'c1') await gate.future;
        if (id == 'c3') throw StateError('后章预取失败不会被消费');
        return '正文$id内容……';
      },
    );
    addTearDown(download.dispose);

    final first = download.start(startIndex: 0, count: 6);
    await Future.wait(entered.values.map((completer) => completer.future));
    expect(loaderCalls, ['c1', 'c2', 'c3']);
    expect(download.value.running, isTrue);

    download.cancel();
    expect(download.value.running, isFalse);
    expect(download.value.completed, 0);
    expect(download.value.message, contains('已停止'));

    // 在途的 loader 回包后，批次必须认出 job 已死：不写盘、不改计数、
    // 不覆盖取消的终态。
    gate.complete();
    await first;
    expect(cache.writes, isEmpty);
    expect(loaderCalls, ['c1', 'c2', 'c3']);
    expect(download.value.completed, 0);
    expect(download.value.running, isFalse);
    expect(download.value.message, contains('已停止'));
  });
}
