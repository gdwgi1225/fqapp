import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/backend_transport.dart';

/// `RustBackendTransport.awaitCoreReady` 的行为契约。
///
/// 这条分支在真机上只在冷启动的头几百毫秒出现，用集成测试很难覆盖，所以把
/// 等待逻辑抽成静态方法单测：预算继承、启动失败、超时、等待中取消、以及
/// 「调用方本来就没有 deadline」这五种语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> completeLater(Duration delay) => Future<void>.delayed(delay);

  test('就绪后返回扣除等待时间的剩余预算', () async {
    final remaining = await RustBackendTransport.awaitCoreReady(
      ready: completeLater(const Duration(milliseconds: 30)),
      request: null,
      budget: const Duration(seconds: 2),
      failureOf: () => null,
    );

    expect(remaining, isNotNull);
    expect(remaining, lessThan(const Duration(seconds: 2)));
    expect(remaining, greaterThan(Duration.zero));
  });

  test('核心启动失败立刻抛出「本地服务启动失败」', () async {
    await expectLater(
      RustBackendTransport.awaitCoreReady(
        ready: Future<void>.value(),
        request: null,
        budget: const Duration(seconds: 2),
        failureOf: () => StateError('listen busy'),
      ),
      throwsA(
        isA<BackendRequestAborted>()
            .having((e) => e.message, 'message', contains('本地服务启动失败'))
            .having((e) => e.message, 'message', contains('listen busy')),
      ),
    );
  });

  test('stop() 以同一路径唤醒排队请求（不等到各自超时）', () async {
    // stop() 的等价形态：ready 完成 + failure 已设置。
    final stopped = Completer<void>();
    final pending = RustBackendTransport.awaitCoreReady(
      ready: stopped.future,
      request: null,
      budget: const Duration(seconds: 30),
      failureOf: () => StateError('backend stopped'),
    );

    stopped.complete();
    await expectLater(
      pending,
      throwsA(
        isA<BackendRequestAborted>().having(
          (e) => e.message,
          'message',
          contains('backend stopped'),
        ),
      ),
    );
  });

  test('等待预算耗尽按超时失败并标记 timedOut', () async {
    await expectLater(
      RustBackendTransport.awaitCoreReady(
        ready: Completer<void>().future,
        request: null,
        budget: const Duration(milliseconds: 20),
        failureOf: () => null,
      ),
      throwsA(
        isA<BackendRequestAborted>()
            .having((e) => e.timedOut, 'timedOut', isTrue)
            .having((e) => e.message, 'message', contains('本地服务启动超时')),
      ),
    );
  });

  test('budget 为 null 时仍然受 20s 等待上限保护', () {
    fakeAsync((async) {
      Object? error;
      unawaited(
        RustBackendTransport.awaitCoreReady(
          ready: Completer<void>().future,
          request: null,
          budget: null,
          failureOf: () => null,
        ).catchError((Object e) {
          error = e;
          return null;
        }),
      );

      async.elapse(const Duration(seconds: 19));
      expect(error, isNull, reason: '19s 时仍在等待');
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();

      expect(
        error,
        isA<BackendRequestAborted>()
            .having((e) => e.timedOut, 'timedOut', isTrue)
            .having((e) => e.message, 'message', contains('本地服务启动超时')),
      );
    });
  });

  test('等待期间取消立即生效，不挂到就绪为止', () async {
    final ready = Completer<void>();
    final request = BackendRequest();
    final pending = RustBackendTransport.awaitCoreReady(
      ready: ready.future,
      request: request,
      budget: const Duration(seconds: 30),
      failureOf: () => null,
    );

    request.cancel();
    await expectLater(
      pending,
      throwsA(
        isA<BackendRequestAborted>().having(
          (e) => e.message,
          'message',
          contains('请求已取消'),
        ),
      ),
    );
    // 就绪晚到也不能再复活这个请求。
    if (!ready.isCompleted) ready.complete();
  });

  test('调用方没有 deadline 时，等待后仍然返回 null（不擅自加限时）', () async {
    final remaining = await RustBackendTransport.awaitCoreReady(
      ready: completeLater(const Duration(milliseconds: 20)),
      request: null,
      budget: null,
      failureOf: () => null,
    );

    expect(remaining, isNull);
  });
}
