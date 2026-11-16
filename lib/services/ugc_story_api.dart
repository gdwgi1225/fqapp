part of 'api_client.dart';

extension UgcStoryApi on ApiClient {
  /// One page of the official short-story feed.
  ///
  /// The next request must use the returned [UgcStoryPage.sessionId] and
  /// [UgcStoryPage.nextOffset]; callers do not synthesize either cursor.
  Future<UgcStoryPage> ugcStories({int offset = 0, String? sessionId}) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', '不能小于 0');
    }
    final response = await _get(
      _url('/api/v1/recommend/ugc-stories', {
        'offset': '$offset',
        if (sessionId != null && sessionId.trim().isNotEmpty)
          'session_id': sessionId.trim(),
      }),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return decodeResponseBody(bytes.length, () {
      try {
        return UgcStoryPage.fromPayload(_decodeEnvelope(status, bytes));
      } on FormatException catch (error) {
        throw ApiException(error.message);
      }
    });
  }

  /// Scope metadata for one UGC post.
  ///
  /// The response's truncation fields remain authoritative; a long detail body
  /// is not automatically a complete article. The model deliberately does not
  /// expose or cache that body.
  Future<UgcStoryDetail> ugcStoryDetail(String postId) async {
    final id = postId.trim();
    if (id.isEmpty || !id.codeUnits.every((unit) => unit >= 48 && unit <= 57)) {
      throw ArgumentError.value(postId, 'postId', '必须是 UGC 帖子 ID');
    }
    final response = await _get(
      _url('/api/v1/novels/${Uri.encodeComponent(id)}', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return decodeResponseBody(bytes.length, () {
      try {
        return UgcStoryDetail.fromPayload(_decodeEnvelope(status, bytes));
      } on FormatException catch (error) {
        throw ApiException(error.message);
      }
    });
  }
}
