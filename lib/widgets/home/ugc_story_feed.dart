import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/media_item.dart';
import '../../models/ugc_story.dart';
import '../../pages/detail_page.dart';
import '../../pages/ugc_story_provider.dart';
import '../../services/api_client.dart';
import '../../services/app_links.dart';
import '../../services/app_style_tokens.dart';
import '../../services/backend_transport.dart';
import '../../services/poster_cache.dart';
import '../../services/user_facing_error.dart';
import 'classic_home_feed_states.dart';
import 'classic_home_stream_footer.dart';
import 'home_archive.dart';
import 'home_design.dart';
import 'home_feed_states.dart';
import 'home_shelf.dart';
import 'home_stream_footer.dart';

/// The independent feed behind the home page's 「短篇」 tab.
///
/// This widget owns the UGC feed's refresh, paging and article-entry flow. It
/// deliberately never touches [homeProvider]: the bookstore loader and UGC
/// recommendations have different payloads and pagination cursors.
class UgcStoryFeed extends ConsumerStatefulWidget {
  const UgcStoryFeed({
    super.key,
    required this.scrollController,
    required this.active,
  });

  final ScrollController scrollController;
  final bool active;

  @override
  ConsumerState<UgcStoryFeed> createState() => _UgcStoryFeedState();
}

class _UgcStoryFeedState extends ConsumerState<UgcStoryFeed> {
  late final UgcStoriesNotifier _stories;
  String? _openingPostId;
  bool _loadMoreCheckScheduled = false;
  int _automaticEmptyLoads = 0;
  int _activationRevision = 0;
  BackendRequest? _detailRequest;

  @override
  void initState() {
    super.initState();
    _stories = ref.read(ugcStoriesProvider.notifier);
    widget.scrollController.addListener(_onScroll);
    if (widget.active) _scheduleActivation();
  }

  @override
  void didUpdateWidget(covariant UgcStoryFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
      if (widget.active) _scheduleLoadMoreCheck();
    }
    if (!oldWidget.active && widget.active) {
      _scheduleActivation();
    } else if (oldWidget.active && !widget.active) {
      _deactivate();
    }
  }

  @override
  void dispose() {
    _activationRevision++;
    final detailRequest = _detailRequest;
    _detailRequest = null;
    detailRequest?.cancel();
    widget.scrollController.removeListener(_onScroll);
    _stories.cancelInFlight();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !widget.active) return;
    final controller = widget.scrollController;
    if (!controller.hasClients) return;
    final position = controller.position;
    if (position.pixels >= position.maxScrollExtent - 600) {
      _maybeLoadMore();
    }
  }

  void _scheduleLoadMoreCheck() {
    if (_loadMoreCheckScheduled || !widget.active) return;
    _loadMoreCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreCheckScheduled = false;
      if (mounted) _maybeLoadMore();
    });
  }

  void _maybeLoadMore() {
    if (!widget.active) return;
    final state = ref.read(ugcStoriesProvider);
    if (state.isLoading ||
        state.isLoadMore ||
        !state.hasMore ||
        state.error != null) {
      return;
    }
    if (state.items.isNotEmpty) {
      _automaticEmptyLoads = 0;
    } else if (_automaticEmptyLoads >= 3) {
      return;
    } else {
      _automaticEmptyLoads++;
    }
    final controller = widget.scrollController;
    if (!controller.hasClients ||
        controller.position.pixels >=
            controller.position.maxScrollExtent - 600) {
      unawaited(_stories.loadMore());
    }
  }

  Future<void> _refresh() {
    _automaticEmptyLoads = 0;
    return _stories.refresh();
  }

  Future<void> _retry() {
    _automaticEmptyLoads = 0;
    return _stories.retry();
  }

  Future<void> _continueEmptyLoadMore() {
    _automaticEmptyLoads = 0;
    return _stories.loadMore();
  }

  void _scheduleActivation() {
    final revision = ++_activationRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active || revision != _activationRevision) return;
      _stories.cancelInFlight();
      unawaited(_stories.load());
      _maybeLoadMore();
    });
  }

  void _deactivate() {
    final revision = ++_activationRevision;
    final detailRequest = _detailRequest;
    _detailRequest = null;
    detailRequest?.cancel();
    _openingPostId = null;
    _automaticEmptyLoads = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.active || revision != _activationRevision) return;
      _stories.cancelInFlight();
    });
  }

  Future<void> _openStory(UgcStoryItem item) async {
    if (!widget.active || _openingPostId != null || item.postId.isEmpty) return;
    final activationRevision = _activationRevision;
    final request = BackendRequest();
    _detailRequest = request;
    setState(() => _openingPostId = item.postId);
    UgcStoryDetail? detail;
    Object? failure;
    try {
      detail = await ApiClient.instance.withCancellation(
        request,
        () => ApiClient.instance.ugcStoryDetail(item.postId),
      );
    } catch (error) {
      failure = error;
    } finally {
      if (identical(_detailRequest, request)) _detailRequest = null;
    }
    if (!mounted ||
        !widget.active ||
        activationRevision != _activationRevision) {
      if (mounted && _openingPostId == item.postId) _openingPostId = null;
      return;
    }
    setState(() => _openingPostId = null);

    if (detail == null) {
      final message = failure == null
          ? '暂时无法确认这篇短篇的阅读范围。'
          : userFacingError(failure);
      await _showScopeNotice(
        title: '暂时无法打开',
        message: '$message\n\n可前往官方阅读，完整范围以官方页面为准。',
        item: item,
        detail: null,
        allowRelatedBook: false,
      );
      return;
    }

    final matches =
        detail.postId == item.postId &&
        detail.relatedBookId == item.relatedBookId &&
        detail.relatedChapterId == item.relatedChapterId &&
        detail.relatedBookId.isNotEmpty &&
        detail.relatedChapterId.isNotEmpty;
    if (!matches) {
      await _showScopeNotice(
        title: '关联信息不一致',
        message:
            '详情返回的短篇、书籍或章节与列表不一致，暂不打开关联书籍。'
            '你仍可前往官方页面查看。',
        item: item,
        detail: detail,
        allowRelatedBook: false,
      );
      return;
    }

    switch (detail.availability) {
      case UgcStoryAvailability.available:
        if (detail.isTruncated) {
          final remaining = detail.truncatedWordCount ?? 0;
          await _showScopeNotice(
            title: '当前提供试读',
            message: remaining > 0
                ? '当前仅提供试读内容，剩余 $remaining 字未返回。'
                      '完整阅读以官方开放范围为准。'
                : '当前仅提供试读内容，正文仍有部分未返回。'
                      '完整阅读以官方开放范围为准。',
            item: item,
            detail: detail,
            allowRelatedBook: true,
          );
        } else {
          await _openRelatedBook(item, detail);
        }
      case UgcStoryAvailability.restricted:
        await _showScopeNotice(
          title: '内容受发布权限限制',
          message: '这篇短篇的访问范围受限。可查看关联书籍，或前往官方阅读。',
          item: item,
          detail: detail,
          allowRelatedBook: true,
        );
      case UgcStoryAvailability.unavailable:
        await _showScopeNotice(
          title: '当前内容不可用',
          message: '这篇短篇的访问状态受限。关联书籍仍按现有详情、书架与阅读流程打开。',
          item: item,
          detail: detail,
          allowRelatedBook: true,
        );
      case UgcStoryAvailability.unknown:
        await _showScopeNotice(
          title: '阅读范围待确认',
          message:
              '暂时无法确认这篇短篇的完整可读范围。'
              '可查看关联书籍，或前往官方阅读。',
          item: item,
          detail: detail,
          allowRelatedBook: true,
        );
    }
  }

  Future<void> _showScopeNotice({
    required String title,
    required String message,
    required UgcStoryItem item,
    required UgcStoryDetail? detail,
    required bool allowRelatedBook,
  }) async {
    final official = _officialTarget(item, detail);
    final action = await showDialog<_StoryOpenAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          if (official.isNotEmpty)
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_StoryOpenAction.official),
              child: const Text('官方阅读'),
            ),
          if (allowRelatedBook)
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_StoryOpenAction.relatedBook),
              child: const Text('查看关联书籍'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _StoryOpenAction.relatedBook:
        if (detail != null) await _openRelatedBook(item, detail);
      case _StoryOpenAction.official:
        await openAppLink(context, official);
      case null:
        return;
    }
  }

  String _officialTarget(UgcStoryItem item, UgcStoryDetail? detail) {
    final schema = item.schema.trim();
    if (schema.isNotEmpty && resolveAppLink(schema) != null) return schema;
    final chapterId = item.relatedChapterId.isNotEmpty
        ? item.relatedChapterId
        : detail?.relatedChapterId ?? '';
    if (chapterId.isEmpty) return '';
    return 'https://fanqienovel.com/reader/${Uri.encodeComponent(chapterId)}';
  }

  Future<void> _openRelatedBook(
    UgcStoryItem item,
    UgcStoryDetail detail,
  ) async {
    final relatedBook = MediaItem(
      id: detail.relatedBookId,
      title: item.title,
      cover: item.cover,
      author: item.author,
      badge: '',
      ep: '',
      kind: 'book',
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(item: relatedBook, autoOpenReader: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ugcStoriesProvider);
    if (widget.active) _scheduleLoadMoreCheck();
    final palette = HomePalette.of(context);
    final classic = AppStyleTokens.of(context).isClassic;
    return ColoredBox(
      color: palette.canvas,
      child: RefreshIndicator(
        color: palette.eink ? palette.ink : HomePalette.accent,
        backgroundColor: palette.surface,
        onRefresh: _refresh,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = ((constraints.maxWidth - 760) / 2)
                .clamp(homeGutter, constraints.maxWidth / 2)
                .toDouble();
            return CustomScrollView(
              key: const Key('ugc_story_feed'),
              controller: widget.scrollController,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: _slivers(state, side, classic),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _slivers(UgcStoryState state, double side, bool classic) {
    if (state.items.isEmpty) {
      final Widget body;
      if (state.isLoading || state.isLoadMore) {
        body = classic
            ? const ClassicHomeFeedLoading(message: '正在加载短篇')
            : const HomeFeedLoading(message: '正在加载短篇');
      } else if (state.error != null) {
        body = classic
            ? ClassicHomeFeedError(
                headline: '短篇还在路上',
                message: '暂时无法加载短篇，稍后再试一次。',
                detail: state.error!,
                onRetry: _refresh,
              )
            : HomeFeedError(
                headline: '短篇还在路上',
                message: '暂时无法加载短篇，稍后再试一次。',
                detail: state.error!,
                onRetry: _refresh,
              );
      } else {
        final canContinue = state.hasMore;
        body = classic
            ? ClassicHomeFeedEmpty(
                title: '暂无短篇',
                message: canContinue ? '已检查多页，暂时没有可显示的短篇' : '稍后刷新，看看新到的故事',
                actionLabel: canContinue ? '继续加载短篇' : '刷新短篇',
                onRefresh: canContinue ? _continueEmptyLoadMore : _refresh,
              )
            : HomeFeedEmpty(
                title: '暂无短篇',
                message: canContinue ? '已检查多页，暂时没有可显示的短篇' : '稍后刷新，看看新到的故事',
                actionLabel: canContinue ? '继续加载短篇' : '刷新短篇',
                onRefresh: canContinue ? _continueEmptyLoadMore : _refresh,
              );
      }
      return [SliverFillRemaining(hasScrollBody: false, child: body)];
    }

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(side, 20, side, 10),
        sliver: SliverToBoxAdapter(
          child: _UgcFeedHeading(count: state.items.length),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(side, 0, side, 8),
        sliver: SliverList.builder(
          itemCount: state.items.length,
          itemBuilder: (context, index) {
            final item = state.items[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _UgcStoryCard(
                key: ValueKey('home_ugc_story_${item.postId}'),
                item: item,
                busy: _openingPostId == item.postId,
                onOpen: () => _openStory(item),
              ),
            );
          },
        ),
      ),
      _footer(state, classic),
      SliverToBoxAdapter(child: SizedBox(height: homeBottomClearance(context))),
    ];
  }

  Widget _footer(UgcStoryState state, bool classic) {
    if (classic) {
      if (state.isLoadMore) {
        return const SliverToBoxAdapter(
          child: ClassicHomeStreamFooter.loading(),
        );
      }
      if (state.error != null) {
        return SliverToBoxAdapter(
          child: ClassicHomeStreamFooter.retry(onRetry: _retry),
        );
      }
      if (!state.hasMore) {
        return const SliverToBoxAdapter(child: ClassicHomeStreamFooter.done());
      }
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    if (state.isLoadMore) {
      return SliverToBoxAdapter(
        child: HomeStreamFooter.loading(onRetry: _retry),
      );
    }
    if (state.error != null) {
      return SliverToBoxAdapter(child: HomeStreamFooter.retry(onRetry: _retry));
    }
    if (!state.hasMore) {
      return const SliverToBoxAdapter(child: HomeStreamFooter.done());
    }
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }
}

enum _StoryOpenAction { relatedBook, official }

class _UgcFeedHeading extends StatelessWidget {
  const _UgcFeedHeading({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final classic = AppStyleTokens.of(context).isClassic;
    return Row(
      children: [
        Text(
          '今日短篇',
          style: TextStyle(
            fontSize: classic ? 18 : 16,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: palette.ink,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: palette.line)),
        const SizedBox(width: 10),
        Text(
          '$count 篇',
          style: TextStyle(fontSize: 12, height: 1.2, color: palette.muted),
        ),
      ],
    );
  }
}

class _UgcStoryCard extends StatelessWidget {
  const _UgcStoryCard({
    super.key,
    required this.item,
    required this.busy,
    required this.onOpen,
  });

  final UgcStoryItem item;
  final bool busy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final tokens = AppStyleTokens.of(context);
    final radius = BorderRadius.circular(tokens.isClassic ? 14 : 16);
    final title = item.title.trim().isEmpty ? '未命名短篇' : item.title.trim();
    final summary = item.summary.replaceAll(RegExp(r'\s+'), ' ').trim();
    final author = item.author.trim();
    final imageWidth = (MediaQuery.sizeOf(context).width * 0.24).clamp(
      82.0,
      108.0,
    );
    final staticLoading =
        palette.eink || MediaQuery.disableAnimationsOf(context);
    return HomePressable(
      onTap: onOpen,
      borderRadius: radius,
      semanticLabel: author.isEmpty ? '$title，短篇' : '$title，作者 $author，短篇',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: radius,
          border: Border.all(color: palette.line, width: 0.8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: imageWidth,
                child: AspectRatio(
                  aspectRatio: 5 / 7,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      tokens.isClassic ? 10 : 12,
                    ),
                    child: _UgcStoryCover(item: item, width: imageWidth),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: palette.soft,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: palette.line),
                          ),
                          child: Text(
                            '短篇',
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.1,
                              fontWeight: FontWeight.w700,
                              color: palette.accentText,
                            ),
                          ),
                        ),
                        if (author.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.2,
                                color: palette.muted,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 9),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          color: palette.body,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (busy && !staticLoading)
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: palette.muted,
                            ),
                          )
                        else
                          Icon(
                            busy
                                ? LucideIcons.hourglass
                                : LucideIcons.book_open,
                            size: 13,
                            color: palette.accentText,
                          ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            busy ? '正在确认内容范围' : '查看试读与关联书籍',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: palette.accentText,
                            ),
                          ),
                        ),
                        Icon(
                          LucideIcons.chevron_right,
                          size: 15,
                          color: palette.muted,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UgcStoryCover extends StatelessWidget {
  const _UgcStoryCover({required this.item, required this.width});

  final UgcStoryItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.eink
              ? const [Colors.white, Colors.white]
              : const [Color(0xFF75695A), Color(0xFF203A35)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            item.title.trim().isEmpty ? '短篇' : item.title.trim(),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              height: 1.35,
              fontWeight: FontWeight.w700,
              color: palette.eink ? Colors.black : Colors.white,
            ),
          ),
        ),
      ),
    );
    Widget cover;
    if (item.cover.isEmpty) {
      cover = fallback;
    } else {
      cover = CachedNetworkImage(
        cacheManager: PosterCache.instance,
        imageUrl: item.cover,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        memCacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).ceil(),
        fadeInDuration: palette.eink || MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      );
    }
    if (!palette.eink) return cover;
    return ColorFiltered(
      colorFilter: einkCoverFilter,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: Colors.black)),
        child: cover,
      ),
    );
  }
}
