import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/theme_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
  });
  tearDown(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  test('both styles carry tokens through normal, OLED and e-ink themes', () {
    for (final style in AppThemeStyle.values) {
      for (final brightness in Brightness.values) {
        final theme = AppTheme.createTheme(brightness, style: style);
        expect(theme.extension<AppStyleTokens>()?.style, style);
        final ported = WenkuTheme.create(brightness, style: style);
        expect(ported.extension<AppStyleTokens>()?.style, style);
        expect(ported.extension<WenkuAppearance>(), isNotNull);
        expect(ported.extension<WenkuTonalColors>(), isNotNull);
      }
      final oled = WenkuTheme.create(Brightness.dark, oled: true, style: style);
      expect(oled.scaffoldBackgroundColor, Colors.black);
      expect(oled.colorScheme.surface, isNot(Colors.black));
      final eink = WenkuTheme.create(
        Brightness.dark,
        eink: true,
        oled: true,
        style: style,
      );
      expect(eink.brightness, Brightness.light);
      expect(eink.scaffoldBackgroundColor, Colors.white);
      expect(eink.colorScheme.onSurface, Colors.black);
      expect(eink.extension<AppStyleTokens>()?.style, style);
    }
  });

  test('reader paper colours survive app style changes', () {
    for (final preset in ReaderThemePreset.values) {
      final archive = preset.theme(AppTheme.createTheme(Brightness.light));
      final classic = preset.theme(
        AppTheme.createTheme(Brightness.light, style: AppThemeStyle.classic),
      );
      expect(classic.scaffoldBackgroundColor, archive.scaffoldBackgroundColor);
      expect(classic.colorScheme.onSurface, archive.colorScheme.onSurface);
      expect(preset.backgroundColor, classic.scaffoldBackgroundColor);
      expect(classic.extension<AppStyleTokens>()?.style, AppThemeStyle.classic);
    }
  });

  // Bug: 软件深色 + 阅读浅色时，笔记筛选 / 简介分类的 Material Chip 会漏出
  // 深色 chipTheme 底 + 深色字，糊成黑块（白色软件 + 深色阅读同理）。reader 主
  // 题必须自己接管 chipTheme，不能依赖软件基主题的 chip 配色。
  test('reader chip colours follow the preset, not the app theme', () {
    final darkBase = AppTheme.createTheme(Brightness.dark);
    final lightBase = AppTheme.createTheme(Brightness.light);
    for (final preset in ReaderThemePreset.values) {
      // 浅色阅读预设叠在深色软件主题上，chip 配色必须来自阅读预设本身。
      final onDarkApp = preset.theme(darkBase);
      // 反向：深色阅读预设叠在浅色软件主题上。
      final onLightApp = preset.theme(lightBase);
      for (final theme in [onDarkApp, onLightApp]) {
        expect(theme.canvasColor, preset.backgroundColor);
        expect(theme.chipTheme.backgroundColor, preset.fieldColor);
        expect(
          theme.chipTheme.selectedColor,
          preset.accentColor.withValues(alpha: 0.12),
        );
        // ChoiceChip 选中背景读的是 secondarySelectedColor（不是
        // selectedColor），必须单独断言，否则会漏回深色。
        expect(
          theme.chipTheme.secondarySelectedColor,
          preset.accentColor.withValues(alpha: 0.12),
        );
        expect(theme.chipTheme.labelStyle?.color, preset.textColor);
        // 同一类泄漏的其余子主题：对话框 / 卡片 / 菜单 / 分隔线都必须
        // 跟随阅读预设，不能落在软件基色的深色上。
        expect(theme.dialogTheme.backgroundColor, preset.sheetColor);
        expect(theme.dialogTheme.titleTextStyle?.color, preset.textColor);
        expect(
          theme.dialogTheme.contentTextStyle?.color,
          preset.mutedTextColor,
        );
        expect(theme.cardTheme.color, preset.panelColor);
        expect(theme.popupMenuTheme.color, preset.panelColor);
        expect(theme.dividerTheme.color, preset.borderColor);
      }
      // 与软件主题无关：两种基底下派生出的 chip 配色完全一致。
      expect(onDarkApp.chipTheme.backgroundColor, preset.fieldColor);
      expect(onLightApp.chipTheme.backgroundColor, preset.fieldColor);
    }
  });

  // 字段设了不等于渲染对了：选中 Chip 的半透明 Ink 还会叠在 Material 底色上。
  // 这里在阅读预设子树里实渲染 Card / Dialog / 选中 ChoiceChip，直读绘制出来的
  // Material / Ink 颜色；Divider / PopupMenu 目前
  // 阅读无消费方（均显式传色或走自绘控件），改在真实 widget 的 element
  // context 上解析子主题，锁定「经嵌套 Theme 传到渲染 context」这一契约。
  testWidgets('reader subthemes reach the rendered widgets', (tester) async {
    final darkBase = AppTheme.createTheme(Brightness.dark);
    for (final preset in [ReaderThemePreset.light, ReaderThemePreset.dark]) {
      Color? dividerColor;
      Color? popupColor;
      await tester.pumpWidget(
        MaterialApp(
          theme: darkBase,
          home: Theme(
            data: preset.theme(darkBase),
            child: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Card(
                      key: ValueKey('probe-card'),
                      child: SizedBox(height: 24),
                    ),
                    const Dialog(
                      key: ValueKey('probe-dialog'),
                      child: SizedBox(height: 24),
                    ),
                    const Divider(key: ValueKey('probe-divider')),
                    const ChoiceChip(
                      key: ValueKey('probe-chip'),
                      label: Text('选中'),
                      selected: true,
                    ),
                    Builder(
                      builder: (context) {
                        dividerColor = DividerTheme.of(context).color;
                        popupColor = PopupMenuTheme.of(context).color;
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Material painted(String key) => tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Material),
            )
            .first,
      );
      // 卡片 / 对话框：实渲染 Material 的底色必须来自阅读预设。
      expect(painted('probe-card').color, preset.panelColor);
      expect(painted('probe-dialog').color, preset.sheetColor);
      // 选中 chip 真正画在 Ink 上的底色（本轮 bug 的载体），不能退回纯黑。
      final chipInk = tester.widget<Ink>(
        find
            .descendant(
              of: find.byKey(const ValueKey('probe-chip')),
              matching: find.byType(Ink),
            )
            .first,
      );
      expect(
        (chipInk.decoration! as ShapeDecoration).color,
        preset.accentColor.withValues(alpha: 0.12),
      );
      expect(
        (chipInk.decoration! as ShapeDecoration).color,
        isNot(Colors.black),
      );
      // Ink 正确仍可能叠在软件深色画布上，必须同时检查实际 Material 底层。
      final chipSurface = tester.widget<PhysicalShape>(
        find.descendant(
          of: find.byKey(const ValueKey('probe-chip')),
          matching: find.byType(PhysicalShape),
        ),
      );
      expect(chipSurface.color, preset.backgroundColor);
      // 分隔线 / 弹出菜单：在当前渲染 context 解析到的子主题即预设色。
      expect(dividerColor, preset.borderColor);
      expect(popupColor, preset.panelColor);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  // W3: 阅读 SnackBar 有意保持跟随软件主题（深色吐司叠在白底阅读上才看得
  // 见），preset.theme 不接管 snackBarTheme。把该设计约束钉死：一旦有人给
  // theme() 补上 snackBarTheme 覆盖，本测试立即红。
  test('reader leaves the snackbar theme to the app', () {
    for (final base in [
      AppTheme.createTheme(Brightness.dark),
      AppTheme.createTheme(Brightness.light),
    ]) {
      for (final preset in ReaderThemePreset.values) {
        // copyWith 没动 snackBarTheme，派生主题的该子主题应与软件基底同一实例。
        expect(preset.theme(base).snackBarTheme, same(base.snackBarTheme));
      }
    }
  });

  testWidgets(
    'shared headers and panels restyle without replacing child state',
    (tester) async {
      final style = ValueNotifier(AppThemeStyle.archive);
      addTearDown(style.dispose);
      await tester.pumpWidget(
        _app(
          style,
          const WenkuScope(
            entrance: false,
            child: Scaffold(
              body: Column(
                children: [
                  ArchiveMasthead(title: '设置', code: '04 / SYSTEM PROFILE'),
                  ContentPanel(child: _RetainedCounter()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('计数 0'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(_RetainedCounter));
      expect(find.text('04 / SYSTEM PROFILE'), findsOneWidget);
      RoundedRectangleBorder shape() =>
          tester
                  .widget<Material>(
                    find
                        .descendant(
                          of: find.byType(ContentPanel),
                          matching: find.byType(Material),
                        )
                        .first,
                  )
                  .shape!
              as RoundedRectangleBorder;
      expect(shape().borderRadius, BorderRadius.circular(4));
      style.value = AppThemeStyle.classic;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_RetainedCounter)), same(state));
      expect(find.text('计数 1'), findsOneWidget);
      expect(find.text('04 / SYSTEM PROFILE'), findsNothing);
      expect(shape().borderRadius, BorderRadius.circular(16));
      expect(
        AppStyleTokens.of(tester.element(find.byType(ContentPanel))).style,
        AppThemeStyle.classic,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings exposes a direct theme route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-entry-主题')));
    await tester.pumpAndSettle();
    expect(find.byType(ThemePage), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-choice-classic')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-choice-archive')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both theme cards sit side by side and fit a phone screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: ThemePage(store: store),
      ),
    );
    await tester.pumpAndSettle();
    final classic = tester.getRect(
      find.byKey(const ValueKey('theme-choice-classic')),
    );
    final archive = tester.getRect(
      find.byKey(const ValueKey('theme-choice-archive')),
    );
    // Comparing the two styles must not require scrolling past one of them.
    expect(classic.top, archive.top);
    expect(classic.right, lessThan(archive.left));
    expect(archive.bottom, lessThan(640));
    expect(
      find.byKey(const ValueKey('theme-selected-archive-true')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('theme-selected-classic-false')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing a theme preserves pushed route and saves selection', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final navigator = GlobalKey<NavigatorState>();
    final editor = TextEditingController(text: '保留输入');
    addTearDown(editor.dispose);
    var initializations = 0;
    await tester.pumpWidget(
      ValueListenableBuilder<AppThemeStyle>(
        valueListenable: store,
        builder: (context, style, _) => MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.createTheme(Brightness.light, style: style),
          home: _RetainedCounter(onInit: () => initializations++),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: TextField(controller: editor)),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => ThemePage(store: store)),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ThemePage));
    await tester.tap(find.byKey(const ValueKey('theme-choice-classic')));
    await tester.pumpAndSettle();
    expect(store.value, AppThemeStyle.classic);
    expect(tester.state(find.byType(ThemePage)), same(state));
    expect(
      find.byKey(const ValueKey('theme-selected-classic-true')),
      findsOneWidget,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        AppThemeStyleStore.storageKey,
      ),
      'classic',
    );
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('保留输入'), findsOneWidget);
    expect(initializations, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(320, 560), const Size(800, 360)]) {
    testWidgets('theme previews fit $size with large text', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: ThemePage(store: store),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('theme-choice-archive')).hitTestable(),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _app(ValueNotifier<AppThemeStyle> style, Widget child) =>
    ValueListenableBuilder<AppThemeStyle>(
      valueListenable: style,
      child: child,
      builder: (context, value, child) => MaterialApp(
        theme: AppTheme.createTheme(Brightness.light, style: value),
        home: child,
      ),
    );

class _RetainedCounter extends StatefulWidget {
  const _RetainedCounter({this.onInit});
  final VoidCallback? onInit;

  @override
  State<_RetainedCounter> createState() => _RetainedCounterState();
}

class _RetainedCounterState extends State<_RetainedCounter> {
  int count = 0;

  @override
  void initState() {
    super.initState();
    widget.onInit?.call();
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('计数 $count'),
  );
}
