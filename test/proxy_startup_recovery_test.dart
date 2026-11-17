import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/main.dart';
import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/services/network_proxy_preferences.dart';
import 'package:fqapp/widgets/settings/core_proxy_settings_panel.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets(
      '$platform cold start with corrupt proxy can explicitly reset routing and retry',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        SharedPreferences.setMockInitialValues({
          NetworkProxyPreferences.key: jsonEncode({
            'enabled': true,
            'url': 'broken',
          }),
        });
        final pending = Completer<void>();
        var starts = 0;
        await tester.pumpWidget(
          // RootShell 立刻渲染真实首页（#318），HomePage 需要 ProviderScope。
          ProviderScope(
            child: MaterialApp(
              home: RootShell(
                backendStarter: () async {
                  starts++;
                  await NetworkProxyPreferences.instance.load();
                  await pending.future;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('启动失败'), findsOneWidget);
        await tester.tap(
          find.text(
            platform == TargetPlatform.linux ? '重置代理为默认连接并重试' : '重置代理为直连并重试',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          (await NetworkProxyPreferences.instance.load()).enabled,
          isFalse,
        );
        expect(starts, 2);
        // 成功路径不再有整屏等待提示：本地服务在后台重启，界面已经出来
        // （#318），所以既没有「正在启动本地服务...」，也没有失败页。
        expect(find.text('正在启动本地服务...'), findsNothing);
        expect(find.text('启动失败'), findsNothing);
        expect(find.byType(HomePage), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        pending.complete();
        await tester.pump();
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      'proxy settings are available on supported desktops: $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(const MaterialApp(home: ApiServicePage()));
        await tester.pumpAndSettle();
        expect(
          find.byType(CoreProxySettingsPanel),
          platform == TargetPlatform.windows || platform == TargetPlatform.linux
              ? findsOneWidget
              : findsNothing,
        );
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
