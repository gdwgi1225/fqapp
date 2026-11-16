import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'app_theme_style.dart';

/// 首帧之前的外观预热：只读主题 / 墨水屏 / OLED 三个键，写进全局 notifier。
///
/// 首帧主题：本地数据还没读完就画骨架，会让「系统浅色 + 应用内强制深色 /
/// 墨水屏」的用户先闪一整屏浅色。外观偏好只有几个键，读它比整包本地数据
/// 快得多，所以先单独预热一次，再进 runApp。
///
/// 失败不阻塞启动：整包本地数据后面还会再读一次并覆盖。样式键的 `load()`
/// 自带去重与错误吞掉，这里提前调用只是把样式键也带进首帧。
///
/// [styleStore] 只给测试用：`AppThemeStyleStore.instance` 是单例，第一次
/// `load()` 之后就不再读盘，测试没法用它验证样式键这一段。
Future<void> primeAppearance({AppThemeStyleStore? styleStore}) async {
  try {
    await (styleStore ?? AppThemeStyleStore.instance).load();
    final sp = await SharedPreferences.getInstance();
    // 与整包本地数据同形：`getString` 在键值被历史写成非 String 时会抛
    // TypeError，一旦抛出会把同一 try 里的墨水屏/OLED 一起吞掉——那正是用户
    // 首帧要闪浅色的场景。这里按值判类型，脏数据退化成默认主题。
    final savedTheme = sp.get(themeModeKey);
    themeModeNotifier.value = themeModeFromName(
      savedTheme is String ? savedTheme : null,
    );
    einkModeNotifier.value = sp.getBool(einkModeKey) ?? false;
    oledModeNotifier.value = sp.getBool(oledModeKey) ?? false;
  } catch (_) {
    // 读不到就沿用初值，行为与预热前一致。
  }
}

/// 带等待上限的预热：`runApp` 不能为了等偏好而被平台通道无限期挡住。
///
/// 超时就按默认值启动；预热本身继续在后台跑完（幂等，读到的值与整包本地
/// 数据一致，晚到也不会打架）。抽成独立函数是为了能单测这条超时路径。
Future<void> primeWithBudget(
  Duration budget, {
  AppThemeStyleStore? styleStore,
}) async {
  await primeAppearance(
    styleStore: styleStore,
  ).timeout(budget, onTimeout: () {});
}
