import 'sync_transport.dart';

const defaultSyncFolderName = '什锦铺-云同步';

void validateSyncFolderName(String name) {
  if (name.trim().isEmpty ||
      name.length > 64 ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[/\\\x00-\x1f]').hasMatch(name)) {
    throw const SyncFailure('请输入有效目录名，不能包含斜线或控制字符');
  }
}
