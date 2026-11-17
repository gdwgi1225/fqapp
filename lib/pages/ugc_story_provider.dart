import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ugc_story.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/user_facing_error.dart';

class UgcStoryState {
  const UgcStoryState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadMore = false,
    this.hasMore = true,
    this.error,
  });

  final List<UgcStoryItem> items;
  final bool isLoading;
  final bool isLoadMore;
  final bool hasMore;

  /// An initial failure has empty [items] and `hasMore=false`; a footer
  /// failure keeps the previous cursor state and therefore remains retryable.
  final String? error;

  UgcStoryState copyWith({
    List<UgcStoryItem>? items,
    bool? isLoading,
    bool? isLoadMore,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) => UgcStoryState(
    items: items ?? this.items,
    isLoading: isLoading ?? this.isLoading,
    isLoadMore: isLoadMore ?? this.isLoadMore,
    hasMore: hasMore ?? this.hasMore,
    error: clearError ? null : error ?? this.error,
  );
}

class UgcStoriesNotifier extends Notifier<UgcStoryState> {
  int _generation = 0;
  int _nextOffset = 0;
  String? _sessionId;
  bool _initialized = false;
  final Set<String> _seen = {};
  BackendRequest? _activeRequest;
  bool _lastFailureWasFirstPage = false;

  @override
  UgcStoryState build() {
    ref.onDispose(() {
      ++_generation;
      final request = _activeRequest;
      _activeRequest = null;
      request?.cancel();
    });
    return const UgcStoryState();
  }

  /// Loads the first page once. A failed first load remains retryable.
  Future<void> load() async {
    if (_initialized || state.isLoading || state.isLoadMore) return;
    if (state.items.isNotEmpty) return;
    await _loadFirstPage();
  }

  /// Replaces the current feed. Any in-flight request from the old generation
  /// is ignored when it returns. Existing items stay visible until a refreshed
  /// page arrives.
  Future<void> refresh() => _loadFirstPage();

  /// Invalidates an in-flight first-page or load-more request without clearing
  /// visible data. Used when the home page leaves the short-story tab.
  void cancelInFlight() {
    final request = _activeRequest;
    if (request == null) return;
    ++_generation;
    _activeRequest = null;
    request.cancel();
    _lastFailureWasFirstPage = false;
    if (state.isLoading && state.items.isEmpty) {
      // A never-completed first page must remain loadable when the tab is
      // entered again.
      _initialized = false;
    }
    state = state.copyWith(isLoading: false, isLoadMore: false);
  }

  /// Appends the next page using only the cursor returned by the previous
  /// response.
  Future<void> loadMore() async {
    if (!_initialized ||
        state.isLoading ||
        state.isLoadMore ||
        state.error != null ||
        !state.hasMore) {
      return;
    }
    final generation = _generation;
    final offset = _nextOffset;
    final sessionId = _sessionId;
    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();
    _lastFailureWasFirstPage = false;
    state = state.copyWith(isLoadMore: true, clearError: true);
    try {
      final page = await ApiClient.instance.withCancellation(
        request,
        () =>
            ApiClient.instance.ugcStories(offset: offset, sessionId: sessionId),
      );
      if (!_isActive(generation)) return;
      final nextOffset = page.nextOffset;
      if (page.hasMore && (nextOffset == null || nextOffset <= offset)) {
        throw const FormatException('短篇分页游标未前进，请稍后重试');
      }
      final merged = [...state.items];
      for (final item in page.items) {
        if (_seen.add(item.postId)) merged.add(item);
      }
      _nextOffset = nextOffset ?? offset;
      _sessionId = page.sessionId ?? sessionId;
      state = UgcStoryState(
        items: List.unmodifiable(merged),
        hasMore: page.hasMore,
      );
    } catch (error) {
      if (!_isActive(generation)) return;
      _lastFailureWasFirstPage = false;
      state = state.copyWith(
        isLoadMore: false,
        hasMore: false,
        error: userFacingError(error),
      );
    } finally {
      if (identical(_activeRequest, request)) _activeRequest = null;
    }
  }

  Future<void> retry() async {
    if (state.error == null || state.isLoading || state.isLoadMore) return;
    final retryFirstPage = _lastFailureWasFirstPage;
    state = state.copyWith(hasMore: true, clearError: true);
    if (retryFirstPage) {
      await _loadFirstPage();
      return;
    }
    await loadMore();
  }

  Future<void> _loadFirstPage() async {
    final generation = ++_generation;
    _initialized = true;
    _activeRequest?.cancel();
    final request = _activeRequest = BackendRequest();
    _lastFailureWasFirstPage = false;
    state = state.copyWith(
      isLoading: true,
      isLoadMore: false,
      clearError: true,
    );
    try {
      final page = await ApiClient.instance.withCancellation(
        request,
        ApiClient.instance.ugcStories,
      );
      if (!_isActive(generation)) return;
      if (page.hasMore && (page.nextOffset == null || page.nextOffset! <= 0)) {
        throw const FormatException('短篇首屏分页游标未前进，请稍后重试');
      }
      _nextOffset = page.nextOffset ?? 0;
      _sessionId = page.sessionId;
      _seen.clear();
      final unique = <UgcStoryItem>[];
      for (final item in page.items) {
        if (_seen.add(item.postId)) unique.add(item);
      }
      state = UgcStoryState(
        items: List.unmodifiable(unique),
        hasMore: page.hasMore,
      );
    } catch (error) {
      if (!_isActive(generation)) return;
      _lastFailureWasFirstPage = true;
      if (state.items.isEmpty) {
        _initialized = false;
        state = UgcStoryState(hasMore: false, error: userFacingError(error));
      } else {
        state = state.copyWith(isLoading: false, error: userFacingError(error));
      }
    } finally {
      if (identical(_activeRequest, request)) _activeRequest = null;
    }
  }

  bool _isActive(int generation) => generation == _generation;
}

final ugcStoriesProvider = NotifierProvider<UgcStoriesNotifier, UgcStoryState>(
  UgcStoriesNotifier.new,
);
