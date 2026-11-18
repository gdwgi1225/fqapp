import 'package:material_ui/material_ui.dart';

import '../services/app_style_tokens.dart';
import '../widgets/wenku/wenku_ui.dart';
import '../widgets/settings/settings_widgets.dart';
import 'multi_device_sync_page.dart';

class WebDavSyncPage extends StatelessWidget {
  const WebDavSyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    final classic = AppStyleTokens.of(context).isClassic;
    final body = SafeArea(
      top: classic,
      bottom: classic,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: classic
                ? const EdgeInsets.all(16)
                : featurePadding(context),
            children: [
              const Text(
                '旧版 WebDAV 直接同步已停用',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                '旧流程会在每次同步时用云端记录覆盖本机，可能把较新的阅读进度恢复成旧进度。'
                '升级后必须先预览本机与云端的合并结果，再保存并启用自动同步。',
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('open-multi-device-sync'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MultiDeviceSyncPage(),
                  ),
                ),
                child: const Text('打开多端同步设置'),
              ),
              const SizedBox(height: 16),
              const Text(
                '原有 WebDAV 地址和账号会预填到新设置。请重新连接、选择同步目录并预览；'
                '只有预览内容未变化时才能保存启用。本迁移入口不会写入账号、云端或本机书架。',
              ),
            ],
          ),
        ),
      ),
    );
    return classic
        ? SettingsScaffold(title: 'WebDAV 安全升级', body: body)
        : ArchiveFeaturePage(
            title: 'WebDAV 安全升级',
            code: 'SYNC / WEBDAV',
            child: body,
          );
  }
}
