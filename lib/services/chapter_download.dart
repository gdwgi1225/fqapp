import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'chapter_cache_store.dart';
import 'chapter_text_formatter.dart';

typedef _ChapterPrefetch = ({ChapterContent? content, Object? error});

/// Progress of one chapter batch, in the shape both surfaces render: the
/// reader's cache panel and the detail page's download action.
@immutable
class ChapterDownloadState {
  const ChapterDownloadState({
    this.running = false,
    this.completed = 0,
    this.total = 0,
    this.incompleteImages = 0,
    this.message,
  });

  final bool running;
  final int completed;
  final int total;

  /// Saved without fresh illustrations: one online view still refreshes them.
  final int incompleteImages;

  /// Final report, or the stop notice. Null before the first batch and while
  /// one is still running.
  final String? message;

  double get fraction => total == 0 ? 0 : completed / total;
}

/// One batch of chapters written through [cache].
///
/// Extracted from the cache sheet so the detail page can download a whole book
/// without it; both now run this loop instead of keeping two copies. The rules
/// the sheet established stay: text already on disk is reused, chapters whose
/// illustrations expired are refreshed, and each chapter reaches
/// [onContentAvailable] before its own disk write (a failed save still leaves
/// the downloaded chapter available to an open reader).
///
/// Up to [_maxPrefetchedChapters] chapter bodies are fetched ahead. Publication,
/// progress and disk writes remain ordered: a later response never overtakes
/// the chapter before it.
///
/// Note: 详情页「下载」直接下全本，批次与面板共用同一实现 — 见
/// .agents/notes/implemented/feature/2026-09-20-offline-whole-book-download.md
class ChapterDownload extends ValueNotifier<ChapterDownloadState> {
  ChapterDownload({
    required this.cache,
    required this.book,
    required this.loader,
    this.onContentAvailable,
  }) : super(const ChapterDownloadState());

  final ChapterCache cache;
  final CachedBook book;
  final Future<String> Function(Chapter chapter) loader;
  final void Function(Chapter chapter, String text)? onContentAvailable;

  static const _maxPrefetchedChapters = 3;

  int _job = 0;
  bool _disposed = false;

  /// Downloads up to [count] chapters starting at [startIndex]. Ignored while a
  /// batch runs, so a double tap cannot interleave two of them.
  ///
  /// [pin] marks the batch as the user's own download: those chapters are
  /// written outside the cache's automatic budget and are never evicted, so a
  /// whole-book batch is not truncated by [ChapterCache.chapterCapacity].
  Future<void> start({
    required int startIndex,
    required int count,
    bool pin = false,
  }) async {
    if (_disposed || value.running) return;
    final job = ++_job;
    final chapters = book.chapters
        .skip(startIndex.clamp(0, book.chapters.length))
        .take(count <= 0 ? 0 : count)
        .toList(growable: false);
    var completed = 0;
    var incompleteImages = 0;
    value = ChapterDownloadState(running: true, total: chapters.length);
    try {
      await cache.saveBook(book);
      if (!_alive(job)) return;

      final prefetched = <Future<_ChapterPrefetch>>[];
      var nextPrefetch = 0;
      void fillWindow() {
        while (nextPrefetch < chapters.length &&
            prefetched.length < _maxPrefetchedChapters) {
          prefetched.add(_prefetch(job, chapters[nextPrefetch++]));
        }
      }

      fillWindow();
      for (var index = 0; index < chapters.length; index++) {
        if (!_alive(job)) return;
        final chapter = chapters[index];
        final ahead = await prefetched.removeAt(0);
        if (!_alive(job)) return;
        final error = ahead.error;
        if (error != null) throw error;

        // Earlier writes may have evicted the cache observed by the prefetch.
        // Re-read at the ordered commit point before publishing anything.
        final cached = await cache.read(
          bookId: book.id,
          chapterId: chapter.itemId,
        );
        if (!_alive(job)) return;
        var previous = _readCachedChapter(cached, chapter.title);

        final ChapterContent content;
        final bool shouldWrite;
        if (ahead.content != null) {
          content = ahead.content!.preferCompleteCache(previous);
          shouldWrite = !identical(content, previous);
        } else if (previous == null || previous.needsImageRefresh()) {
          // A prefetched cache hit no longer covers this chapter. Fetch again
          // instead of restoring the stale snapshot that was evicted.
          final fetched = await _fetch(chapter);
          if (!_alive(job)) return;
          // A reader refresh may have completed while this fallback fetched.
          final latest = await cache.read(
            bookId: book.id,
            chapterId: chapter.itemId,
          );
          if (!_alive(job)) return;
          previous = _readCachedChapter(latest, chapter.title);
          content = fetched.preferCompleteCache(previous);
          shouldWrite = !identical(content, previous);
        } else {
          content = previous;
          shouldWrite = false;
        }
        final cachedText = content.toCacheText();
        // Publish before queuing the disk write so older reader requests can
        // no longer queue a stale write behind it.
        onContentAvailable?.call(chapter, cachedText);
        if (!_alive(job)) return;
        if (shouldWrite || pin) {
          await cache.write(
            bookId: book.id,
            chapterId: chapter.itemId,
            title: chapter.title,
            text: cachedText,
            pinned: pin,
          );
        }
        if (!_alive(job)) return;
        completed++;
        if (content.needsImageRefresh()) incompleteImages++;
        value = ChapterDownloadState(
          running: true,
          completed: completed,
          total: chapters.length,
          incompleteImages: incompleteImages,
        );
        if (_alive(job)) fillWindow();
      }
      if (!_alive(job)) return;
      value = ChapterDownloadState(
        completed: completed,
        total: chapters.length,
        incompleteImages: incompleteImages,
        message: incompleteImages == 0
            ? '缓存完成，可从书架的离线缓存入口继续阅读'
            : '已保存 $completed/${chapters.length} 章，其中 $incompleteImages 章插图未更新，联网后可重试',
      );
    } catch (_) {
      if (!_alive(job)) return;
      // Fence already-started prefetches before reporting the ordered failure.
      // Their futures capture errors, so results no longer consumed are inert.
      ++_job;
      value = ChapterDownloadState(
        completed: completed,
        total: chapters.length,
        message: '缓存未完成，已保存 $completed/${chapters.length} 章。检查网络后可重试',
      );
    }
  }

  /// Stops the running batch. Chapters already written stay on disk.
  void cancel() {
    ++_job;
    final state = value;
    value = ChapterDownloadState(
      completed: state.completed,
      total: state.total,
      incompleteImages: state.incompleteImages,
      message: '已停止缓存，已保存的章节会保留',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    ++_job;
    super.dispose();
  }

  Future<_ChapterPrefetch> _prefetch(int job, Chapter chapter) async {
    try {
      if (!_alive(job)) return (content: null, error: null);
      final cached = await cache.read(
        bookId: book.id,
        chapterId: chapter.itemId,
      );
      if (!_alive(job)) return (content: null, error: null);
      final content = _readCachedChapter(cached, chapter.title);
      if (content != null && !content.needsImageRefresh()) {
        return (content: null, error: null);
      }
      final fetched = await _fetch(chapter);
      if (!_alive(job)) return (content: null, error: null);
      return (content: fetched, error: null);
    } catch (error) {
      if (!_alive(job)) return (content: null, error: null);
      return (content: null, error: error);
    }
  }

  Future<ChapterContent> _fetch(Chapter chapter) async {
    final text = await loader(chapter).timeout(const Duration(seconds: 30));
    final fetched = ChapterContent.isStructuredCache(text)
        ? ChapterContent.fromCacheText(text)
        : ChapterContent.fromPlainText(text, illustrationsChecked: false);
    if (fetched.withoutLeadingTitle(chapter.title).isEmpty) {
      throw StateError('章节正文为空');
    }
    return fetched;
  }

  bool _alive(int job) => !_disposed && job == _job;
}

/// The whole-book batch a detail page started.
///
/// The batch outlives the page that asked for it: leaving the detail page must
/// not silently kill a download the user started with one tap. A page that
/// comes back attaches to the same batch instead of starting a second one, so
/// at most one whole-book batch is ever in flight. A finished batch is kept
/// until a page reports it or the next batch replaces it, which is what lets a
/// page that was rebuilt mid-download still show the result.
class WholeBookDownload {
  WholeBookDownload._();

  static ChapterDownload? _active;

  /// The batch in flight, or the one that finished most recently.
  static ChapterDownload? get active => _active;

  static ChapterDownload start({
    required ChapterCache cache,
    required CachedBook book,
    required Future<String> Function(Chapter chapter) loader,
    required int startIndex,
    required int count,
  }) {
    // Only one whole-book batch at a time. The previous one is cancelled, not
    // disposed: a page still listening to it (the stack keeps the book the user
    // just left) has to be told the batch ended, or it would sit on a progress
    // readout that no longer moves. Cancelling reports it through the usual
    // terminal state, and the chapters it already wrote stay on disk.
    _active?.cancel();
    final download = ChapterDownload(cache: cache, book: book, loader: loader);
    _active = download;
    // The batch is fire-and-forget: its page (or the next one) reads progress
    // from the notifier instead of awaiting the future.
    // Pinned: a whole-book download is the user's own copy of the book, so the
    // cache's LRU budget must not truncate it or evict it later.
    unawaited(download.start(startIndex: startIndex, count: count, pin: true));
    return download;
  }

  /// Drops [download] once it is finished so its catalogue can be collected.
  /// A running batch is kept — the user may still come back to it.
  ///
  /// The finished batch is released, never disposed: pages call this from the
  /// notifier's own listener, and disposing a notifier while it is dispatching
  /// is an error. Nothing is left listening to a finished batch anyway.
  static void release(ChapterDownload download) {
    if (identical(_active, download) && !download.value.running) {
      _active = null;
    }
  }
}

ChapterContent? _readCachedChapter(String? text, String title) {
  if (text == null) return null;
  try {
    final content = ChapterContent.fromCacheText(text);
    return content.withoutLeadingTitle(title).isEmpty ? null : content;
  } on FormatException {
    return null;
  }
}
