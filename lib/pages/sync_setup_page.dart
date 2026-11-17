import 'package:flutter/services.dart' show Clipboard;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/platform_channel.dart';
import '../services/sync/multi_device_sync_service.dart';
import '../services/sync/sync_folder_name.dart';
import '../services/sync/sync_settings_store.dart';
import '../services/sync/sync_setup_session.dart';
import '../services/sync/sync_transport.dart';
import '../widgets/settings/settings_widgets.dart';
import 'sync_folder_picker.dart';

typedef CloudSyncLogin = Future<String?> Function(String provider);
Future<String?> loginCloudSync(String provider) => const AppMethodChannel(
  'fqapp/cloud_login',
).invokeMethod<String>('login', {'provider': provider});

class SyncSetupPage extends StatefulWidget {
  const SyncSetupPage({
    super.key,
    required this.provider,
    required this.store,
    required this.openSession,
    required this.login,
  });
  final String provider;
  final SyncSettingsStore store;
  final SyncSetupFactory openSession;
  final CloudSyncLogin login;
  @override
  State<SyncSetupPage> createState() => _SyncSetupPageState();
}

class _SyncSetupPageState extends State<SyncSetupPage> {
  static const _weiyunAuthorizationUrl = 'https://www.weiyun.com/authorize';

  final address = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController(),
      domain = TextEditingController(),
      weiyunToken = TextEditingController(),
      folderName = TextEditingController(text: defaultSyncFolderName);
  SyncSetupSession? session;
  Map<String, String>? selection;
  WebDavSyncPreview? preview;
  bool busy = false, implicit = false, manual = false;
  bool weiyunTokenEntry = false;
  int step = 0;
  String? error;
  String get provider => widget.provider;
  bool get cloud => !{'webdav', 'ftp', 'ftps', 'smb'}.contains(provider);
  String get title => SyncProvider.byId(provider).title;
  WebDavSyncSettings? get webDavSettings => switch (widget.store) {
    final WebDavSyncSettings settings when provider == 'webdav' => settings,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    final saved = widget.store.configFor(provider);
    _loadFields(saved);
  }

  void _loadFields(Map<String, String> saved) {
    address.text = saved['endpoint'] ?? '';
    username.text = saved['username'] ?? '';
    password.text = saved['password'] ?? '';
    domain.text = saved['domain'] ?? '';
    implicit = saved['implicit'] == 'true';
  }

  @override
  void dispose() {
    for (final controller in [
      address,
      username,
      password,
      domain,
      weiyunToken,
      folderName,
    ]) {
      controller.dispose();
    }
    session?.close();
    super.dispose();
  }

  Map<String, String> form({String? token}) => {
    'provider': provider,
    'endpoint': address.text.trim(),
    'username': username.text.trim(),
    'password': token ?? password.text,
    'domain': domain.text.trim(),
    'implicit': '$implicit',
    'enabled': 'false',
    if ((token ?? password.text) == _savedForFormat['password'] &&
        _savedForFormat['profile'] != null)
      'profile': _savedForFormat['profile']!,
  };

  Map<String, String> get _savedForFormat => widget.store.configFor(provider);

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is SyncFailure
              ? failure.message
              : '操作未完成，请检查连接或重新登录',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> login() => run(() async {
    final token = await widget.login(provider);
    if (!mounted || token == null || token.isEmpty) return;
    password.text = token;
    await connect();
  });

  Future<void> openWeiyunAuthorization() async {
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '在微云官网申请 API Key',
      message:
          '打开官网后，先点右上角的「登录」。\n\n'
          '受微信扫码登录限制，建议用电脑或另一台手机打开下面的网址，再用微信扫码登录。\n\n'
          '$_weiyunAuthorizationUrl',
      confirmLabel: '继续打开官网',
    );
    if (!mounted || !confirmed) return;
    await run(() async {
      final opened = await launchUrl(
        Uri.parse(_weiyunAuthorizationUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const SyncFailure('无法打开微云官网，请在浏览器访问 $_weiyunAuthorizationUrl');
      }
    });
  }

  Future<void> pasteWeiyunAuthorization() => run(() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      throw const SyncFailure('请先从微云官网复制 API Key');
    }
    weiyunToken.text = text;
  });

  Future<void> connectWeiyunToken() => run(() async {
    final token = weiyunToken.text.trim();
    if (token.isEmpty) throw const SyncFailure('请先粘贴微云 API Key');
    await connect(token: token);
  });

  Future<void> connect({String? token}) async {
    final opened = await widget.openSession(form(token: token));
    if (!mounted) {
      opened.close();
      return;
    }
    session?.close();
    session = opened;
    await opened.folders(opened.root);
    if (!mounted) return;
    setState(() => step = 1);
    await chooseFolder();
  }

  Future<void> chooseFolder() async {
    final saved = widget.store.configFor(provider);
    final previousFolderName = (saved['endpoint'] ?? '')
        .split('/')
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    final selected = await Navigator.of(context).push<SyncFolder>(
      MaterialPageRoute(
        builder: (_) => SyncFolderPicker(
          session: session!,
          previousFolderId: saved['folderId'],
          previousFolderName: previousFolderName,
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      selection = session!.select(selected);
      preview = null;
      step = manual ? 3 : 2;
    });
  }

  Future<void> finishToken() => run(() async {
    if (password.text.trim().isEmpty) throw const SyncFailure('请填写 Token');
    final opened = await widget.openSession(form());
    if (!mounted) {
      opened.close();
      return;
    }
    session?.close();
    session = opened;
    final folders = await opened.folders(opened.root);
    final matches = folders
        .where((folder) => folder.name == folderName.text.trim())
        .toList();
    SyncFolder selected;
    if (matches.length > 1) throw const SyncFailure('存在重名目录，请返回修改目录名');
    if (matches.isNotEmpty) {
      selected = matches.single;
    } else {
      if (!mounted) return;
      final confirmed = await showSettingsConfirmDialog(
        context: context,
        title: '新建同步目录',
        message: '没有找到“${folderName.text.trim()}”，是否新建此目录？',
        confirmLabel: '新建',
      );
      if (!confirmed) return;
      selected = await opened.createFolder(opened.root, folderName.text.trim());
    }
    if (mounted) {
      setState(() {
        selection = opened.select(selected);
        step = 3;
      });
    }
  });

  Future<void> save() => run(() async {
    await widget.store.configure({
      ...selection!,
      'enabled': 'true',
      if (preview != null) 'webdavPreview': preview!.revision,
    });
    if (mounted) Navigator.pop(context, true);
  });

  Future<void> previewTarget() => run(() async {
    setState(() => preview = null);
    final result = await webDavSettings!.previewWebDav(selection!);
    if (mounted) setState(() => preview = result);
  });

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: ValueKey('sync-field-$label'),
      controller: controller,
      enabled: !busy,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final review = step == (manual ? 3 : 2);
    final heading = review
        ? '确认同步设置'
        : step == 0
        ? (weiyunTokenEntry ? '填写微云 API Key' : '登录$title')
        : step == 1
        ? '选择同步目录'
        : '填写 Token';
    return SettingsScaffold(
      title: heading,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (step != 0 || provider != 'weiyun') ...[
                  Text(
                    manual ? '登录 → 目录 → Token → 保存' : '登录 → 选择目录 → 保存',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                ],
                if (step == 0) ...[
                  if (!cloud) ...[
                    field(
                      address,
                      '服务器地址',
                      hint: provider == 'webdav'
                          ? 'https://example.com/dav/'
                          : provider == 'smb'
                          ? 'smb://NAS/共享名/'
                          : '$provider://host/',
                    ),
                    field(username, '账号'),
                    field(password, '密码', secret: true),
                    if (provider == 'smb') field(domain, '域（可留空）'),
                    if (provider == 'ftps')
                      SettingsGroupCard(
                        children: [
                          SettingsRow(
                            title: '隐式 FTPS',
                            trailing: SettingsSwitch(
                              value: implicit,
                              onChanged: busy
                                  ? null
                                  : (value) => setState(() => implicit = value),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: busy ? null : () => run(connect),
                      child: const Text('登录并继续'),
                    ),
                  ] else if (provider == 'weiyun') ...[
                    if (weiyunTokenEntry) ...[
                      const Text('在微云官网申请 API Key，复制后回到什锦铺粘贴。'),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: busy ? null : openWeiyunAuthorization,
                        child: const Text('打开微云官网申请'),
                      ),
                      const SizedBox(height: 16),
                      field(weiyunToken, 'API Key', secret: true),
                      OutlinedButton(
                        onPressed: busy ? null : pasteWeiyunAuthorization,
                        child: const Text('从剪贴板粘贴'),
                      ),
                      FilledButton(
                        onPressed: busy ? null : connectWeiyunToken,
                        child: const Text('验证并继续'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                weiyunToken.clear();
                                weiyunTokenEntry = false;
                                error = null;
                              }),
                        child: const Text('返回登录方式'),
                      ),
                    ] else ...[
                      SettingsGroupCard(
                        children: [
                          SettingsRow(
                            title: '申请并粘贴 API Key',
                            subtitle: '从微云官网获取 API Key',
                            onTap: busy
                                ? null
                                : () => setState(() {
                                    weiyunTokenEntry = true;
                                    error = null;
                                  }),
                          ),
                          SettingsRow(
                            title: '密码或扫码登录',
                            subtitle: '在内置浏览器打开微云官方登录页',
                            onTap: busy ? null : login,
                          ),
                        ],
                      ),
                      if (password.text.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: busy ? null : () => run(connect),
                          child: const Text('使用已有登录继续'),
                        ),
                      ],
                    ],
                  ] else ...[
                    SettingsGroupCard(
                      children: [
                        SettingsRow(
                          title: title,
                          subtitle: password.text.isEmpty
                              ? '请先登录你的网盘账号'
                              : '已有登录信息，可以继续选择目录',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: busy ? null : login,
                      child: Text(
                        password.text.isEmpty ? '登录$title' : '重新登录$title',
                      ),
                    ),
                    if (password.text.isNotEmpty)
                      OutlinedButton(
                        onPressed: busy ? null : () => run(connect),
                        child: const Text('使用已有登录继续'),
                      ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              manual = true;
                              step = 1;
                              error = null;
                            }),
                      child: const Text('使用已有 Token'),
                    ),
                  ],
                ] else if (step == 1) ...[
                  if (manual && session == null) ...[
                    field(folderName, '同步目录名称'),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () {
                              try {
                                validateSyncFolderName(folderName.text.trim());
                                setState(() {
                                  step = 2;
                                  error = null;
                                });
                              } on SyncFailure catch (failure) {
                                setState(() => error = failure.message);
                              }
                            },
                      child: const Text('下一步'),
                    ),
                  ] else ...[
                    SettingsGroupCard(
                      children: [
                        SettingsRow(
                          title: '同步目录',
                          subtitle: '选择已有目录或新建目录',
                          onTap: chooseFolder,
                        ),
                      ],
                    ),
                  ],
                ] else if (!review) ...[
                  field(password, 'Token', secret: true),
                  FilledButton(
                    onPressed: busy ? null : finishToken,
                    child: const Text('验证并继续'),
                  ),
                ] else ...[
                  SettingsGroupCard(
                    children: [
                      SettingsRow(title: '存储服务', value: title),
                      SettingsRow(
                        title: '同步目录',
                        subtitle: selection!['endpoint'],
                        onTap: busy ? null : () => run(chooseFolder),
                      ),
                      const SettingsRow(title: '登录状态', value: '已登录'),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('将同步书架、阅读与播放进度、已看剧集；不上传正文、视频和登录凭据。'),
                  const SizedBox(height: 20),
                  if (preview case final summary?) ...[
                    Text(
                      '本机：书架 ${summary.localShelf} 项、历史 ${summary.localHistory} 条、已看 ${summary.localEpisodes} 集\n'
                      '云端：书架 ${summary.cloudShelf} 项、历史 ${summary.cloudHistory} 条、已看 ${summary.cloudEpisodes} 集\n'
                      '预计合并：书架 ${summary.mergedShelf} 项、历史 ${summary.mergedHistory} 条、已看 ${summary.mergedEpisodes} 集\n'
                      '预计从本机移除 ${summary.localRemovals} 条记录',
                    ),
                    if (provider == 'webdav')
                      const Text('合并数量仅统计双向同步记录，云端原有的书旗、分组和 AI 数据会保留。'),
                    const SizedBox(height: 12),
                  ],
                  if (webDavSettings != null)
                    OutlinedButton(
                      onPressed: busy ? null : previewTarget,
                      child: Text(preview == null ? '预览同步结果' : '重新预览'),
                    ),
                  FilledButton(
                    onPressed:
                        busy || (webDavSettings != null && preview == null)
                        ? null
                        : save,
                    child: const Text('保存并启用'),
                  ),
                ],
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
