import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/appearance_prewarm.dart';

/// 外观预热的契约：在 `runApp` 之前把外观偏好写进 notifier，让首帧骨架与
/// 真实主题一致。
///
/// 预热入口住在 `lib/services/appearance_prewarm.dart`，是一个正常的公开
/// 函数，不是 `main.dart` 里的 `@visibleForTesting` 钩子——同包内的
/// `@visibleForTesting` 对可见性没有任何约束，等于给 `main.dart` 加了个
/// 公开符号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    themeModeNotifier.value = ThemeMode.system;
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
  });

  test('预热把主题 / 墨水屏 / OLED / 页面样式写进 notifier', () async {
    SharedPreferences.setMockInitialValues({
      themeModeKey: 'dark',
      // 两个 bool 都置 true：墨水屏与 OLED 在设置页互斥，但这里要证明的是
      // 两个键各自被读到——任一为 false 都与默认值相同，断言不出区别。
      einkModeKey: true,
      oledModeKey: true,
      AppThemeStyleStore.storageKey: AppThemeStyle.classic.name,
    });
    // 样式键走单独的 store：单例读过一次就不再读盘，测不出这一段。
    final store = AppThemeStyleStore(missingStyle: AppThemeStyle.archive);

    await primeAppearance(styleStore: store);

    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(einkModeNotifier.value, isTrue);
    expect(oledModeNotifier.value, isTrue);
    expect(store.value, AppThemeStyle.classic);
  });

  test('偏好缺失时四个键各自回落到默认值', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AppThemeStyleStore(missingStyle: AppThemeStyle.archive);

    await primeAppearance(styleStore: store);

    // 主题键缺失 -> system；两个 bool 键缺失 -> getBool ?? false；
    // 样式键缺失 -> store 的缺省值。
    expect(themeModeNotifier.value, ThemeMode.system);
    expect(einkModeNotifier.value, isFalse);
    expect(oledModeNotifier.value, isFalse);
    expect(store.value, AppThemeStyle.archive);
  });
}
