import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';
import 'home_shelf.dart';

const double _rankCardWidth = 100;
const double _rankCoverHeight = 140;
const double _rankCardGap = 12;

/// 最小触控尺寸（Material 48dp）：「更多」与榜单标签共用。
const double _minTapSize = 48;
const double _moreGap = 12;

/// 标签文字在 48dp 热区里的水平内缩上限。列表两端按 `min(它, gutter)`
/// 抵消，让首尾标签的文字落在标签视口的 gutter 上；gutter 小于它时
/// 内缩跟着收窄，首标签仍与标题、卡片的左缘对齐。
const double _boardTextInset = 10;

/// 选中态下划线的尺寸与到文字的间距（Stack 总高 = 文字 + 两者之和）。
const double _boardIndicatorHeight = 2;
const double _boardIndicatorGap = 5;

/// f329399's horizontal TOP-cover rail. Only presentation lives here:
/// HomeRankCell retains the selected board, loader and request generation.
class ClassicHomeRankRail extends StatelessWidget {
  const ClassicHomeRankRail({
    super.key,
    required this.title,
    required this.names,
    required this.selectedIndex,
    required this.books,
    required this.loading,
    required this.onSelect,
    required this.onOpen,
    required this.onMore,
    this.gutter = homeGutter,
  });

  final String title;
  final List<String> names;
  final int selectedIndex;
  final List<MediaItem> books;
  final bool loading;
  final ValueChanged<int> onSelect;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onMore;

  /// 标题、「更多」、标签行、卡片行共用的左右留白；默认 [homeGutter]。
  /// 测试可传入更小的值覆盖「gutter < 内缩」分支。
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final railHeight =
        _rankCoverHeight +
        8 +
        scaler.scale(13) * 1.35 * 2 +
        4 +
        scaler.scale(11) * 1.3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 按「更多」实际宽度缩窄标题与标签视口；大字号超过 48dp 时
            // 也不会重叠。按钮独占右列，不会把标题到标签的间距撑大。
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(left: gutter),
                    child: HomeSectionHeader(
                      title: title,
                      gutter: 0,
                      topPadding: 8,
                      bottomPadding: names.length > 1 ? 0 : homeHeaderGap,
                    ),
                  ),
                  if (names.length > 1)
                    _BoardNames(
                      names: names,
                      selectedIndex: selectedIndex,
                      onSelect: onSelect,
                      gutter: gutter,
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                top: 8,
                left: _moreGap,
                right: gutter,
                // 单榜单没有标签行时，让卡片从按钮热区下方开始。
                bottom: names.length > 1 ? 0 : 1,
              ),
              child: ClassicHomeBlockMore(onTap: onMore),
            ),
          ],
        ),
        if (loading)
          SizedBox(
            height: railHeight,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: HomePalette.accent,
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: railHeight,
            child: ListView.separated(
              key: const Key('classic_home_rank_rail'),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: gutter),
              itemCount: books.length,
              separatorBuilder: (_, _) => const SizedBox(width: _rankCardGap),
              itemBuilder: (context, index) {
                final item = books[index];
                return _RankCard(
                  key: ValueKey('rank:${item.kind}:${item.id}'),
                  item: item,
                  rank: index + 1,
                  onTap: () => onOpen(item),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Original 12sp action and arrow, with no archive label or code.
class ClassicHomeBlockMore extends StatelessWidget {
  const ClassicHomeBlockMore({
    super.key,
    required this.onTap,
    this.label = '更多',
  });

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Align(
            alignment: Alignment.topCenter,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(LucideIcons.chevron_right, size: 13, color: palette.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain board tabs with the original 16 × 2dp underline.
class _BoardNames extends StatelessWidget {
  const _BoardNames({
    required this.names,
    required this.selectedIndex,
    required this.onSelect,
    required this.gutter,
  });

  final List<String> names;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // 两端补偿与标签内缩共用同一个 inset：gutter 小于内缩时收窄内缩，
    // 让首尾文字的左右缘始终落在视口的 gutter 上，而不是被内缩值顶到
    // 10dp（那样会与标题错位且没有任何断言失败）。
    final inset = math.min(_boardTextInset, gutter);
    final sidePadding = gutter - inset;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: sidePadding),
      child: Row(
        children: [
          for (var index = 0; index < names.length; index++)
            Padding(
              padding: EdgeInsets.only(left: index == 0 ? 0 : 4),
              child: Semantics(
                button: true,
                selected: index == selectedIndex,
                label: names[index],
                onTap: () => onSelect(index),
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => onSelect(index),
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: _minTapSize,
                      minHeight: _minTapSize,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: inset),
                      child: Column(
                        // 盒子至少 48dp 宽；内容更窄（短榜名）时首/末标签
                        // 分别贴向列表两端，让文字 gutter 精确对齐（居中
                        // 会把单字标签推离 7.5dp）。这里只移动「文字 + 指示
                        // 条」这个整体，指示条在下面的 Stack 里单独以文字
                        // 居中，不会被一起推到边缘。内容 ≥ 48dp 时该设置
                        // 没有视觉效果；只有 2 个榜名时没有居中项。
                        crossAxisAlignment: index == 0
                            ? CrossAxisAlignment.start
                            : index == names.length - 1
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.center,
                        // 48dp 热区高于内容（文字 + 下划线 ≈ 23dp）：内容垂直
                        // 居中，上下各留 12.7dp。标题下方的 padding 和卡片的
                        // SizedBox 已置 0，这两段空白正好被热区溢出借走，
                        // 标题→标签、下划线→卡片都是 12.7dp（#384）。
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Stack(
                            children: [
                              Padding(
                                // Stack 总高 = 文字 + 间距 + 指示条高，与
                                // 原来的「文字 + 间距 + 指示条」一致，#384
                                // 的垂直间距不变。
                                padding: const EdgeInsets.only(
                                  bottom:
                                      _boardIndicatorGap +
                                      _boardIndicatorHeight,
                                ),
                                child: Text(
                                  names[index],
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.2,
                                    fontWeight: index == selectedIndex
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: index == selectedIndex
                                        ? palette.ink
                                        : palette.muted,
                                  ),
                                ),
                              ),
                              // 指示条横跨文字宽后居中，天然与文字同中心。
                              // 若让它跟 Column 的 crossAxisAlignment 走，
                              // 首/末标签会偏离文字中心最多 11.9dp（设备实测
                              // 字体；flutter_test 默认字体约 11.5dp）——首屏
                              // 默认选中第 0 个，这是默认视图的视觉回归。单字
                              // 榜名（文字 13dp < 16dp）会被夹成文字宽，是
                              // 「文字贴 gutter」与「指示条固定 16dp」之间
                              // 唯一的取舍。
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Center(
                                  child: Container(
                                    key: const Key('rank_board_indicator'),
                                    width: 16,
                                    height: _boardIndicatorHeight,
                                    decoration: BoxDecoration(
                                      color: index == selectedIndex
                                          ? palette.ink
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(1),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RankCard extends StatelessWidget {
  const _RankCard({
    super.key,
    required this.item,
    required this.rank,
    required this.onTap,
  });

  final MediaItem item;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final score = item.score;
    final meta = item.rankTags.isNotEmpty
        ? item.rankTags.first
        : item.author.isNotEmpty
        ? item.author
        : score != null
        ? homeScoreText(score)
        : '';
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      semanticLabel: '$rank ${item.title}',
      child: SizedBox(
        width: _rankCardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RankCover(item: item, rank: rank),
            const SizedBox(height: 8),
            SizedBox(
              height: scaler.scale(13) * 1.35 * 2,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RankCover extends StatelessWidget {
  const _RankCover({required this.item, required this.rank});

  final MediaItem item;
  final int rank;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _rankCardWidth,
      height: _rankCoverHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            StoryCover(item: item, cacheWidth: 200),
            if (rank <= 3)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'TOP $rank',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
