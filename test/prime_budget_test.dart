import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/appearance_prewarm.dart';

/// `primeWithBudget` 的契约：平台通道挂起时必须有上限，超时按默认值放行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    themeModeNotifier.value = ThemeMode.system;
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
  });

  test('样式读取挂起时，等待预算到点就返回，不阻塞 runApp', () async {
    final hang = Completer<SharedPreferences>();
    final store = AppThemeStyleStore(preferences: () => hang.future);

    final clock = Stopwatch()..start();
    await primeWithBudget(const Duration(milliseconds: 30), styleStore: store);
    clock.stop();

    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: '超时后必须立刻放行',
    );
    // 超时前什么都没读到：沿用初值。
    expect(themeModeNotifier.value, ThemeMode.system);
    expect(einkModeNotifier.value, isFalse);
    expect(oledModeNotifier.value, isFalse);
  });

  test('正常路径下预算不改变结果：偏好照常写入', () async {
    SharedPreferences.setMockInitialValues({
      themeModeKey: 'dark',
      einkModeKey: true,
      oledModeKey: false,
    });

    await primeWithBudget(const Duration(seconds: 2));

    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(einkModeNotifier.value, isTrue);
    expect(oledModeNotifier.value, isFalse);
  });
}
