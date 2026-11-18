import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/sync/sync_folder_name.dart';
import '../services/sync/sync_setup_session.dart';
import '../services/sync/sync_transport.dart';
import '../widgets/settings/settings_widgets.dart';

class SyncFolderPicker extends StatefulWidget {
  const SyncFolderPicker({
    super.key,
    required this.session,
    this.previousFolderId,
    this.previousFolderName,
  });
  final SyncSetupSession session;
  final String? previousFolderId;
  final String? previousFolderName;
  @override
  State<SyncFolderPicker> createState() => _SyncFolderPickerState();
}

class _SyncFolderPickerState extends State<SyncFolderPicker> {
  late final stack = [widget.session.root];
  List<SyncFolder> folders = [];
  bool loading = true;
  String? error;
  SyncFolder get current => stack.last;
  List<String> get currentPathSegments {
    return current.path.split('/').where((part) => part.isNotEmpty).toList();
  }

  bool get isCloud => !{
    'webdav',
    'ftp',
    'ftps',
    'smb',
  }.contains(widget.session.config['provider']);
  bool get showShortcuts => isCloud && stack.length == 1;
  bool get canSelect {
    if (loading || error != null) return false;
    return switch (widget.session.config['provider']) {
      'webdav' => true,
      'ftp' || 'ftps' => currentPathSegments.isNotEmpty,
      'smb' => currentPathSegments.length > 1,
      _ => stack.length > 1,
    };
  }

  List<SyncFolder> get shortcutFolders {
    if (!showShortcuts) return const [];
    final previous =
        folders
            .where((folder) => folder.id == widget.previousFolderId)
            .firstOrNull ??
        folders
            .where((folder) => folder.name == widget.previousFolderName)
            .firstOrNull;
    return [
      ?previous,
      for (final folder in folders)
        if (folder.name == defaultSyncFolderName && folder.id != previous?.id)
          folder,
    ];
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.session.folders(current);
      if (mounted) setState(() => folders = result);
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is SyncFailure
              ? failure.message
              : '目录读取失败，请检查连接后重试',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NewFolderDialog(
        initialName: widget.session.config['provider'] == 'webdav'
            ? ''
            : defaultSyncFolderName,
      ),
    );
    if (name != null && mounted) await createFolder(name);
  }

  Future<void> createFolder(String name, {bool useImmediately = false}) async {
    if (loading || error != null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final folder = await widget.session.createFolder(current, name);
      if (!mounted) return;
      if (useImmediately) {
        Navigator.pop(context, folder);
        return;
      }
      stack.add(folder);
      await load();
    } catch (failure) {
      if (!mounted) return;
      if (useImmediately) {
        await load();
      } else {
        setState(() => loading = false);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failure is SyncFailure ? failure.message : '新建目录失败，请检查权限后重试',
          ),
        ),
      );
    }
  }

  void openFolder(SyncFolder folder) {
    stack.add(folder);
    load();
  }

  Widget folderList() {
    final shortcuts = shortcutFolders;
    final shortcutIds = shortcuts.map((folder) => folder.id).toSet();
    final remaining = folders
        .where((folder) => !shortcutIds.contains(folder.id))
        .toList();
    if (!showShortcuts && remaining.isEmpty) {
      return const Center(child: Text('此目录下没有文件夹'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (showShortcuts) ...[
          SettingsGroupCard(
            children: [
              if (shortcuts.isEmpty)
                SettingsRow(
                  title: '创建并使用目录【$defaultSyncFolderName】',
                  icon: LucideIcons.folder_plus,
                  onTap: () =>
                      createFolder(defaultSyncFolderName, useImmediately: true),
                ),
              for (final folder in shortcuts)
                SettingsRow(
                  title: folder.name,
                  subtitle: folder.name == defaultSyncFolderName
                      ? '默认同步目录'
                      : '上次使用的同步目录',
                  icon: LucideIcons.folder,
                  onTap: () => openFolder(folder),
                  trailing: TextButton(
                    onPressed: () => Navigator.pop(context, folder),
                    child: const Text('使用'),
                  ),
                ),
            ],
          ),
          if (remaining.isNotEmpty) const SizedBox(height: 16),
        ],
        if (remaining.isNotEmpty)
          SettingsGroupCard(
            children: [
              for (final folder in remaining)
                SettingsRow(
                  title: folder.name,
                  icon: LucideIcons.folder,
                  onTap: () => openFolder(folder),
                ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '选择同步目录',
    actions: [
      IconButton(
        tooltip: '新建目录',
        onPressed: loading || error != null ? null : create,
        icon: const Icon(LucideIcons.folder_plus),
      ),
    ],
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SettingsGroupCard(
              children: [
                if (stack.length > 1)
                  SettingsRow(
                    title: '上一级',
                    icon: LucideIcons.arrow_up,
                    onTap: loading
                        ? null
                        : () {
                            stack.removeLast();
                            load();
                          },
                  ),
                SettingsRow(
                  title: current.name,
                  subtitle: current.path,
                  icon: LucideIcons.folder,
                ),
              ],
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(error!, textAlign: TextAlign.center),
                        ),
                        TextButton(onPressed: load, child: const Text('重试')),
                      ],
                    ),
                  )
                : folderList(),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canSelect
                    ? () => Navigator.pop(context, current)
                    : null,
                child: const Text('使用此目录'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog({required this.initialName});
  final String initialName;
  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  late final controller = TextEditingController(text: widget.initialName);
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    try {
      validateSyncFolderName(controller.text.trim());
      Navigator.pop(context, controller.text.trim());
    } on SyncFailure catch (failure) {
      setState(() => error = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建目录'),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: InputDecoration(labelText: '目录名称', errorText: error),
      onSubmitted: (_) => submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('创建')),
    ],
  );
}
