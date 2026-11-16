// #318：冷启动的两层全屏等待提示被弱化。
//
// 成功路径上，AppBootstrap（本地数据）与 RootShell（本地服务）都不再整屏
// 遮罩：界面先出来，初始化在后台静默完成，等待反馈交给页面内的骨架。
// 失败路径必须原样保留：原因、重试，以及服务面板/离线阅读入口。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/cached_books_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/widgets/home/home_skeleton.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 推进到 [finder] 命中为止。
  //
  // 单次 `pump()` 不够：本地数据就绪的回调是微任务，而 `pump()` 只在有帧被
  // 调度时才重建界面——启动骨架的脉动被 TickerMode 关掉时没有帧被调度，那
  // 一次 pump 只会把微任务跑掉、把重建排到下一帧。
  //
  // 这里用「还找不到就再 pump 一次」的有界循环：与骨架是否在动无关，也不会
  // 像 `pumpAndSettle()` 那样被无限循环的动画卡到超时。
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 10 && finder.evaluate().isEmpty; i++) {
      await tester.pump();
    }
  }

  testWidgets('本地数据就绪前只有骨架，没有整屏等待提示', (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppBootstrap(
          initializer: () => pending.future,
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pump();

    // 等待文案与转圈都消失了，只剩骨架占住版式。
    expect(find.text('正在读取本地数据…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(HomeSkeleton), findsOneWidget);
    expect(find.text('ready'), findsNothing);

    pending.complete();
    await pumpUntilFound(tester, find.text('ready'));
    expect(find.text('ready'), findsOneWidget);
    expect(find.byType(HomeSkeleton), findsNothing);
  });

  testWidgets('本地服务还没起来时界面先出来，不再整屏遮罩', (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(backendStarter: () => pending.future),
        ),
      ),
    );
    await tester.pump();

    // 首页已经挂上来，等待反馈由页面内的骨架承担。
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.text('正在启动本地服务...'), findsNothing);
    expect(find.text('启动失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地服务启动失败仍保留错误页与重试、服务面板入口', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(
            backendStarter: () async {
              throw StateError('核心起不来');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('启动失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('服务面板'), findsOneWidget);
    expect(find.text('离线阅读'), findsOneWidget);
    // 失败页整屏接管，首页不再挂在下面。
    expect(find.byType(HomePage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('启动骨架带无障碍标签：读屏用户仍知道在读本地数据', (tester) async {
    final handle = tester.ensureSemantics();
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppBootstrap(
          initializer: () => pending.future,
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('正在读取本地数据…'), findsOneWidget);

    pending.complete();
    await pumpUntilFound(tester, find.text('ready'));
    handle.dispose();
  });

  testWidgets('失败页把后端错误原因写出来', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(
            backendStarter: () async {
              throw StateError('核心起不来：端口被占');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('端口被占'), findsOneWidget);
  });

  testWidgets('失败页的「服务面板」入口能打开服务面板', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(
            backendStarter: () async {
              throw StateError('核心起不来');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('服务面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ApiServicePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('失败页的「离线阅读」入口能打开离线书库', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(
            backendStarter: () async {
              throw StateError('核心起不来');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('离线阅读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CachedBooksPage), findsOneWidget);
    // 离线书库页会去开加密 Hive 箱，密钥读取在测试环境里没有平台实现，
    // SecureKeyProvider 的 10s 超时定时器会一直挂着（flutter_test 会因此报
    // 「还有定时器没收」）。把假时钟推过这个超时，失败照常被页面兜住。
    await tester.pump(const Duration(seconds: 11));
    expect(tester.takeException(), isNull);
  });

  testWidgets('重试成功后失败页消失、首页回来', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RootShell(
            backendStarter: () async {
              attempts++;
              if (attempts == 1) throw StateError('核心起不来');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('启动失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('启动失败'), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
}
