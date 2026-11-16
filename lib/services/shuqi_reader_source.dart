import '../models/media_item.dart';
import '../models/shuqi_book.dart';
import 'api_client.dart';
import 'library_store.dart';

/// Cache and history share a source-scoped ID; the shelf keeps the upstream ID.
String shuqiReaderId(String bookId) =>
    historyStorageKeyFor(bookId, 'book', source: shuqiSourceId);

String? shuqiBookIdFromReaderId(String readerId) {
  const prefix = 'shuqi:';
  if (!readerId.startsWith(prefix) || readerId.length == prefix.length) {
    return null;
  }
  final bookId = readerId.substring(prefix.length);
  return RegExp(r'^[0-9]+$').hasMatch(bookId) ? bookId : null;
}

Future<List<Chapter>> loadShuqiDirectory(
  String bookId, {
  Future<Map<String, dynamic>> Function(String)? loader,
}) async {
  final payload = await (loader ?? ApiClient.instance.shuqiToc)(bookId);
  final data = payload['data'];
  if (data is! Map) throw StateError('没有取到书旗目录');
  return ShuqiToc.fromJson(Map<String, dynamic>.from(data)).toReaderChapters();
}

Future<String> loadShuqiChapter(
  String bookId,
  Chapter chapter, {
  Future<Map<String, dynamic>> Function(String, String)? loader,
}) async {
  final payload = await (loader ?? ApiClient.instance.shuqiChapter)(
    bookId,
    chapter.itemId,
  );
  final data = payload['data'];
  final text = data is Map ? data['content'] : null;
  if (text is! String || text.trim().isEmpty) {
    throw StateError('这一章没有取到正文（${chapter.title}）');
  }
  return text;
}
