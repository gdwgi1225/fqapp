/// One official UGC short-story card.
///
/// `postId` identifies the feed item. The related book and chapter IDs belong
/// to the normal book catalogue and must stay separate: an UGC post is not a
/// book, and its content is only a preview.
class UgcStoryItem {
  const UgcStoryItem({
    required this.postId,
    required this.relatedBookId,
    required this.relatedChapterId,
    required this.title,
    this.cover = '',
    this.author = '',
    this.summary = '',
    this.schema = '',
  });

  final String postId;
  final String relatedBookId;
  final String relatedChapterId;
  final String title;
  final String cover;
  final String author;
  final String summary;
  final String schema;

  factory UgcStoryItem.fromPostData(Map<String, dynamic> post) {
    final user = _map(post['user_info']);
    final cover = _map(post['post_cover']);
    return UgcStoryItem(
      postId: _string(post['post_id']),
      relatedBookId: _string(post['relate_book_id']),
      relatedChapterId: _string(post['relate_item_id']),
      title: _string(post['title']),
      cover: _string(cover['web_url']).isNotEmpty
          ? _string(cover['web_url'])
          : _string(cover['web_uri']),
      author: _string(user['user_name']),
      summary: _string(post['pure_content']),
      schema: _string(post['schema']),
    );
  }
}

/// One page from the official UGC story feed.
///
/// The cursor fields come from this response and remain the single pagination
/// source for the provider. A legal terminal page can have no `cell_data`.
class UgcStoryPage {
  const UgcStoryPage({
    required this.items,
    required this.nextOffset,
    required this.sessionId,
    required this.hasMore,
  });

  final List<UgcStoryItem> items;
  final int? nextOffset;
  final String? sessionId;
  final bool hasMore;

  factory UgcStoryPage.fromPayload(Map<String, dynamic> payload) {
    final data = _map(payload['data']);
    if (data.isEmpty) throw const FormatException('短篇短故事响应缺少 data');

    final cellView = _map(data['cell_view']);
    final rawCells = cellView['cell_data'];
    final items = <UgcStoryItem>[];
    if (rawCells is List) {
      for (final rawCell in rawCells) {
        final cell = _map(rawCell);
        final post = _map(_map(cell['mixed_data'])['post_data']);
        if (post.isEmpty) continue;
        final item = UgcStoryItem.fromPostData(post);
        if (item.postId.isNotEmpty) items.add(item);
      }
    }

    final nextOffset = _nonNegativeInt(data['next_offset']);
    final hasMore = _bool(data['has_more']);
    if (hasMore && nextOffset == null) {
      throw const FormatException('短篇短故事分页缺少 next_offset');
    }
    final session = _string(data['session_id']).trim();
    return UgcStoryPage(
      items: List.unmodifiable(items),
      nextOffset: nextOffset,
      sessionId: session.isEmpty ? null : session,
      hasMore: hasMore,
    );
  }
}

/// Detail metadata for one UGC post.
///
/// The official feed body is a preview. The detail response may carry a much
/// longer `html_content`, but its truncation fields still define whether the
/// response is explicitly partial. This model preserves that distinction; it
/// does not claim that a long response is the complete article.
class UgcStoryDetail {
  const UgcStoryDetail({
    required this.postId,
    required this.title,
    required this.relatedBookId,
    required this.relatedChapterId,
    required this.truncatedWordCount,
    required this.isTruncated,
    required this.availability,
  });

  final String postId;
  final String title;
  final String relatedBookId;
  final String relatedChapterId;
  final int? truncatedWordCount;
  final bool isTruncated;
  final UgcStoryAvailability availability;

  factory UgcStoryDetail.fromPayload(Map<String, dynamic> payload) {
    final data = _map(payload['data']);
    if (data.isEmpty) throw const FormatException('短篇详情响应缺少 data');
    final html = _string(data['html_content']);
    final status = _nullableInt(data['status']);
    final privacy = _nullableInt(data['ugc_privacy']);
    final truncateFlag = _nullableInt(data['truncate_flag']) ?? 0;
    final truncatedWordCount = _nullableInt(data['truncate_word_num']);
    return UgcStoryDetail(
      postId: _string(data['post_id']),
      title: _string(data['title']),
      relatedBookId: _string(data['relate_book_id']),
      relatedChapterId: _string(data['relate_item_id']),
      truncatedWordCount: truncatedWordCount,
      isTruncated: truncateFlag != 0 || (truncatedWordCount ?? 0) > 0,
      availability: _availability(
        status: status,
        privacy: privacy,
        hasBody: html.isNotEmpty,
      ),
    );
  }
}

enum UgcStoryAvailability { available, restricted, unavailable, unknown }

UgcStoryAvailability _availability({
  required int? status,
  required int? privacy,
  required bool hasBody,
}) {
  if (status == null && privacy == null && !hasBody) {
    return UgcStoryAvailability.unknown;
  }
  if ((status != null && status != 1) || !hasBody) {
    return UgcStoryAvailability.unavailable;
  }
  if (privacy != null && privacy != 0) {
    return UgcStoryAvailability.restricted;
  }
  return status == 1 && privacy == 0
      ? UgcStoryAvailability.available
      : UgcStoryAvailability.unknown;
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) return const {};
  return Map<String, dynamic>.from(value);
}

String _string(Object? value) => value == null ? '' : '$value'.trim();

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(_string(value));
}

int? _nonNegativeInt(Object? value) {
  final parsed = _nullableInt(value);
  return parsed != null && parsed >= 0 ? parsed : null;
}

bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = _string(value).toLowerCase();
  return text == 'true' || text == '1';
}
