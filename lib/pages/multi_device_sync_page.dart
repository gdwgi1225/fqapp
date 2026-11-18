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
  late String provider = needsReview
      ? 'webdav'
      : store.config['provider'] ?? 'webdav';
  bool updating = false;
  bool initializing = false;
  String? initializationError;
  bool get needsReview => switch (store) {
    final WebDavSyncSettings settings => settings.needsWebDavReview,
    _ => false,
  };
  bool get showWebDavReview => provider == 'webdav' && needsReview;
  String get currentEndpoint => store.configFor(provider)['endpoint'] ?? '';
  bool get configured =>
      store.config['provider'] == provider && currentEndpoint.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (store is MultiDeviceSyncService) initialize();
  }

  Future<void> initialize() async {
    setState(() {
      initializing = true;
      initializationError = null;
    });
    final service = store as MultiDeviceSyncService;
    String? failure;
    try {
      await service.initialize();
    } catch (error) {
      failure = error is StateError ? '本机数据尚未准备好，请稍后重试' : service.status;
    }
    if (!mounted) return;
    setState(() {
      initializing = false;
      if (service.ready) {
        expanded = store.enabled;
        provider = needsReview
            ? 'webdav'
            : store.config['provider'] ?? 'webdav';
      } else {
        initializationError = failure ?? service.status;
      }
    });
  }

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
        provider = needsReview ? 'webdav' : store.config['provider']!;
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
      builder: (context, _) {
        if (initializing) {
          return const Center(child: CircularProgressIndicator());
        }
        if (initializationError case final message?) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(message, textAlign: TextAlign.center),
                ),
                TextButton(onPressed: initialize, child: const Text('重试')),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            SettingsGroupCard(
              children: [
                SettingsRow(
                  title: '启用自动同步',
                  icon: LucideIcons.refresh_cw,
                  iconTile: true,
                  subtitle: '自动同步范围仅含番茄收藏、阅读播放记录和已看剧集',
                  trailing: SettingsSwitch(
                    value: expanded || store.enabled,
                    semanticLabel: '启用自动同步',
                    onChanged: updating ? null : toggle,
                  ),
                ),
              ],
            ),
            if (showWebDavReview) ...[
              const SizedBox(height: 16),
              const Text('请确认 HTTPS 地址和目录，然后切换到多端同步。'),
            ],
            if (expanded || store.enabled || showWebDavReview) ...[
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
                    title: showWebDavReview
                        ? '确认同步设置'
                        : currentEndpoint.isNotEmpty
                        ? '修改同步设置'
                        : '开始配置',
                    icon: LucideIcons.folder,
                    iconTile: true,
                    subtitle: currentEndpoint.isNotEmpty
                        ? currentEndpoint
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
        );
      },
    ),
  );
}
