import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/backend_transport.dart';

/// 冷启动「核心即将启动」闸门的契约。
///
/// 启动链在走到核心之前还有一段文件准备（目录、配置、部署），那段时间请求
/// 可能已经到了——首页现在不再等后端就绪。传输层必须把它们挂起，而不是打到
/// 一个还没监听的端口上：否则冷启动的首页首帧会直接报错，用户还得手动刷新
/// （#318）。
///
/// 回落路径用注入的 [MockClient] 观察：挂起期间一个 HTTP 请求都不能发出去，
/// 放行之后才发——这正是「被闸门放行」与「自己跑出去」的区别。
///
/// 单元测试里没有原生核心，所以放行之后的请求按既有回落走到 HTTP 适配层；
/// 「放行到核心」这条真路径由 test/rust_host_integration_test.dart 的真核心
/// 覆盖。这里能证明的是闸门本身：请求确实被挂起、确实被放行、而且读到的
/// 失败只属于自己那一轮。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const home = 'http://127.0.0.1:18921/api/v1/home';

  RustBackendTransport transportWithRecorder(List<http.Request> sent) =>
      RustBackendTransport(
        fallbackClient: MockClient((request) async {
          sent.add(request);
          return http.Response('', 400);
        }),
      );

  test('宣布启动后，先到的请求挂起而不是立刻打空端口', () async {
    final sent = <http.Request>[];
    final transport = transportWithRecorder(sent);
    transport.announceStart();

    final request = transport.send(
      'GET',
      Uri.parse(home),
      timeout: const Duration(seconds: 5),
    );
    var settled = false;
    unawaited(
      request.then<void>(
        (_) => settled = true,
        onError: (Object _) => settled = true,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(settled, isFalse, reason: '核心还在启动，请求应当挂起');
    expect(sent, isEmpty, reason: '挂起期间不能真的发出 HTTP 请求：那就是打空端口');

    transport.settleCore(failure: StateError('core down'));
    await expectLater(
      request,
      throwsA(
        isA<BackendRequestAborted>()
            .having((e) => e.message, 'message', contains('本地服务启动失败'))
            // 核心没起来是终局失败：重试同一个请求只会把同一个失败再跑一遍。
            .having((e) => e.fatal, 'fatal', isTrue),
      ),
    );
  });

  test('核心就绪后挂起的请求被放行：先离开闸门，才落到回落', () async {
    final sent = <http.Request>[];
    final transport = transportWithRecorder(sent);
    transport.announceStart();

    final request = transport.send(
      'GET',
      Uri.parse(home),
      timeout: const Duration(seconds: 5),
    );
    var settled = false;
    unawaited(
      request.then<void>(
        (_) => settled = true,
        onError: (Object _) => settled = true,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settled, isFalse, reason: '核心就绪前请求应当挂起');
    expect(sent, isEmpty, reason: '放行之前不能发出 HTTP 请求');

    transport.settleCore();
    final response = await request.timeout(const Duration(seconds: 5));
    expect(settled, isTrue);
    // 放行之后请求才发出去：这就是「被闸门放行」的证据——不是它自己跑出去的。
    expect(sent, hasLength(1));
    expect(sent.single.url, Uri.parse(home));
    // 没有原生核心时，它按既有回落拿到适配层的响应。
    expect(response.statusCode, 400);
  });

  test('没有宣布启动时不挂起：维持既有回落', () async {
    final sent = <http.Request>[];
    final transport = transportWithRecorder(sent);

    final response = await transport
        .send('GET', Uri.parse(home), timeout: const Duration(seconds: 2))
        .timeout(const Duration(seconds: 5));
    expect(response.statusCode, 400);
    expect(sent, hasLength(1));
  });

  test('核心被停掉后：新请求不继承上一轮的失败', () async {
    final sent = <http.Request>[];
    final transport = transportWithRecorder(sent);
    transport.announceStart();

    final pending = transport.send(
      'GET',
      Uri.parse(home),
      timeout: const Duration(seconds: 5),
    );
    // 先挂上期望，再停核心：错误到达时必须已经有人接住。
    final expectation = expectLater(
      pending,
      throwsA(
        isA<BackendRequestAborted>().having(
          (e) => e.message,
          'message',
          contains('本地服务启动失败'),
        ),
      ),
    );
    // 停掉核心：挂着的请求立刻拿到失败，而不是各自等到超时。
    await transport.stop();
    await expectation;

    // 停掉之后再来一个请求：它属于新一轮，不该继续抛「backend stopped」。
    final response = await transport
        .send('GET', Uri.parse(home), timeout: const Duration(seconds: 5))
        .timeout(const Duration(seconds: 5));
    expect(response.statusCode, 400);
    expect(sent, hasLength(1));
  });

  test('一轮成功后再停机：不会把这一轮的结果改成失败', () async {
    final sent = <http.Request>[];
    final transport = transportWithRecorder(sent);
    transport.announceStart();

    final pending = transport.send(
      'GET',
      Uri.parse(home),
      timeout: const Duration(seconds: 5),
    );

    transport.settleCore();
    // 核心随后被停掉：这一轮已经出了结果，不能被后来的失败改写。
    final stopped = transport.stop();

    final response = await pending.timeout(const Duration(seconds: 5));
    await stopped;
    expect(response.statusCode, 400);
    expect(sent, hasLength(1));
  });
}
