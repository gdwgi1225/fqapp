import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/sync/multi_device_sync_service.dart';
import '../services/sync/sync_settings_store.dart';
import '../services/sync/sync_setup_session.dart';
import '../services/sync/sync_transport.dart';
import '../widgets/settings/settings_widgets.dart';
import 'sync_setup_page.dart';

class MultiDeviceSyncPage extends StatefulWidget {
  const MultiDeviceSyncPage({
    super.key,
    this.store,
    this.openSession,
    this.login,
  });
  final SyncSettingsStore? store;
  final SyncSetupFactory? openSession;
  final CloudSyncLogin? login;
  @override
  State<MultiDeviceSyncPage> createState() => _MultiDeviceSyncPageState();
}

class _MultiDeviceSyncPageState extends State<MultiDeviceSyncPage> {
  late final store = widget.store ?? MultiDeviceSyncService.instance;
  late bool expanded = store.enabled;
  late String provider = store.config['provider'] ?? 'webdav';
  bool updating = false;
  bool get needsReview => switch (store) {
    final WebDavSyncSettings settings => settings.needsWebDavReview,
    _ => false,
  };
  bool get configured =>
      store.config['provider'] == provider &&
      (store.config['endpoint'] ?? '').isNotEmpty;

  void notice(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> toggle(bool value) async {
    setState(() {
      expanded = value;
      updating = true;
    });
    try {
      if (!value || (configured && !needsReview)) {
        await store.setAutoSync(value);
      }
    } catch (error) {
      if (mounted) {
        setState(() => expanded = store.enabled);
        notice(error is SyncFailure ? error.message : '设置未能保存，请重试');
      }
    } finally {
      if (mounted) setState(() => updating = false);
    }
  }

  Future<void> chooseProvider() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('存储服务'),
        children: [
          RadioGroup<String>(
            groupValue: provider,
            onChanged: (value) {
              if (value != null) Navigator.pop(dialog, value);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in SyncProvider.values.where(
                  (item) => item.available,
                ))
                  RadioListTile<String>(
                    value: item.id,
                    title: Text(
                      item.id == 'weiyun' ? '${item.title}（操作繁琐）' : item.title,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final previous = provider;
    setState(() => provider = selected);
    final saved = await setup();
    if (!saved && mounted) setState(() => provider = previous);
  }

  Future<bool> setup() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SyncSetupPage(
          provider: provider,
          store: store,
          openSession: widget.openSession ?? openSyncSetup,
          login: widget.login ?? loginCloudSync,
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() {
        provider = store.config['provider']!;
        expanded = store.enabled;
      });
    }
    return saved == true;
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '多端同步',
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          SettingsGroupCard(
            children: [
              SettingsRow(
                title: '启用自动同步',
                icon: LucideIcons.refresh_cw,
                iconTile: true,
                subtitle: '自动同步书架、阅读和播放进度',
                trailing: SettingsSwitch(
                  value: expanded || store.enabled,
                  semanticLabel: '启用自动同步',
                  onChanged: updating ? null : toggle,
                ),
              ),
            ],
          ),
          if (needsReview) ...[
            const SizedBox(height: 16),
            const Text('请确认 HTTPS 地址和目录，然后切换到多端同步。'),
          ],
          if (expanded || store.enabled || needsReview) ...[
            const SizedBox(height: 16),
            SettingsGroupCard(
              children: [
                SettingsRow(
                  title: '存储服务',
                  icon: LucideIcons.cloud,
                  iconTile: true,
                  value: SyncProvider.byId(provider).available
                      ? SyncProvider.byId(provider).title
                      : '请选择',
                  onTap: chooseProvider,
                ),
                SettingsRow(
                  title: needsReview
                      ? '确认同步设置'
                      : configured
                      ? '修改同步设置'
                      : '开始配置',
                  icon: LucideIcons.folder,
                  iconTile: true,
                  subtitle: configured
                      ? store.config['endpoint']
                      : '登录、选择目录并保存',
                  onTap: SyncProvider.byId(provider).available
                      ? setup
                      : chooseProvider,
                ),
              ],
            ),
            if (configured && store.enabled) ...[
              const SizedBox(height: 16),
              SettingsGroupCard(
                children: [
                  SettingsRow(
                    title: store.busy ? '正在同步…' : '立即同步',
                    icon: LucideIcons.refresh_cw,
                    iconTile: true,
                    subtitle: store.status,
                    onTap: store.busy ? null : store.sync,
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    ),
  );
}
