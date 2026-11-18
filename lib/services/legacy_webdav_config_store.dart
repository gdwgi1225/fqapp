import 'dart:convert';

import 'native_secure_key_storage.dart';
import 'webdav_client.dart';

/// Reads the retired v1 WebDAV settings so the unified setup can prefill them.
///
/// The old cloud-authoritative apply implementation is intentionally not part
/// of the product. All writes and merges go through the unified preview flow.
final class LegacyWebDavConfigStore {
  LegacyWebDavConfigStore._();

  static final _storage = defaultSecureKeyStorage();
  static const _configKey = 'fqapp.webdav.config.v1';

  static Future<WebDavConfig?> readSavedConfig() async {
    final saved = await _storage.read(_configKey);
    return saved == null
        ? null
        : WebDavConfig.fromJson(jsonDecode(saved) as Map<String, dynamic>);
  }
}
