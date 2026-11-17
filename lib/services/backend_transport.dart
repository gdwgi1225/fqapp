import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../src/rust/api.dart' as rust;
import '../src/rust/frb_generated.dart';
import 'app_log.dart';
import 'rust_bootstrap.dart';
import 'secure_key_provider.dart';

/// One backend response.
///
/// The transport keeps the HTTP shape (status + bytes) because the whole
/// business contract - including "HTTP 200 with a business error code" - is
/// expressed that way by the Rust core.
class BackendResponse {
  const BackendResponse(this.statusCode, this.body, this.contentType);

  final int statusCode;
  final Uint8List body;
  final String contentType;
}

/// Raised when a call was cancelled, or exceeded its deadline.
///
/// Cancelling drops the in-flight Rust dispatch future, which tears down the
/// awaiting upstream request, any retry backoff and any not-yet-submitted
/// write - so a late result is never published. A filesystem write the OS has
/// already accepted is not rolled back: Tokio file I/O is not a transaction.
class BackendRequestAborted implements Exception {
  BackendRequestAborted(
    this.message, {
    this.timedOut = false,
    this.fatal = false,
  });

  final String message;

  /// The request hit its deadline instead of the caller cancelling. A shared
  /// caller may retry only when it has its own explicitly remaining budget.
  final bool timedOut;

  /// The failure is final: retrying the same request cannot change it.
  ///
  /// The local core refusing to start is the case that matters - retrying
  /// only replays the same startup failure, so the request gate must not
  /// treat it as retryable (#318).
  final bool fatal;

  @override
  String toString() => message;
}

/// Cancellation handle for one logical unit of work.
///
/// A page (or a feed loader) creates one, asks [ApiClient.withCancellation] to
/// bind its requests to it, and cancels it when the page goes away or a newer
/// request supersedes it. Cancelling is idempotent and always safe.
class BackendRequest {
  final List<void Function()> _cancellers = [];
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelled;

  /// Completes when [cancel] is called. A request that is already cancelled
  /// resolves immediately.
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
    for (final cancel in List<void Function()>.of(_cancellers)) {
      cancel();
    }
    _cancellers.clear();
  }

  /// Registers [cancel]. Returns false - after cancelling immediately - when
  /// this request was already cancelled, which is how a caller that lost a race
  /// learns it must not start the work at all.
  bool register(void Function() cancel) {
    if (_cancelled) {
      cancel();
      return false;
    }
    _cancellers.add(cancel);
    return true;
  }

  void unregister(void Function() cancel) {
    _cancellers.remove(cancel);
  }
}

/// [baseUrl] with [capability] woven into the path, ending in `/`.
///
/// Resource URLs must use this: backend-relative paths are root-relative
/// (`/src/...`) and `Uri.resolve` would otherwise replace the whole base path,
/// dropping the capability. `resolveBackendResource` re-anchors them.
///
/// A free function rather than an interface member, so that every
/// `implements BackendTransport` (test doubles included) stays untouched.
String backendResourceBase(String baseUrl, String capability) =>
    capability.isEmpty ? '$baseUrl/' : '$baseUrl/_session/$capability/';

/// A backend call surface. Two implementations share the same Rust core:
/// [RustBackendTransport] calls it over flutter_rust_bridge, and
/// [HttpBackendTransport] talks to the loopback HTTP adapter (tests, desktop,
/// Web).
abstract class BackendTransport {
  /// Base URL used to resolve backend-relative resources such as `/src/...`.
  String get baseUrl;

  /// Per-launch capability the loopback adapter requires; empty when unknown.
  ///
  /// Only callers that cross the socket must present it - FFI calls stay in
  /// process and are never gated.
  String get capability => '';

  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  });

  Future<void> close() async {}
}

/// flutter_rust_bridge transport. The Rust core owns the HTTP client, the
/// device pool and the signing keys; Dart only passes method/path/query/body.
class RustBackendTransport implements BackendTransport {
  RustBackendTransport({
    this.port = defaultPort,
    this.mockUpstreamOrigin = '',
    http.Client? fallbackClient,
  }) : _baseUrl = 'http://127.0.0.1:$port',
       // Created eagerly so it captures the ambient `http.Client` of the Zone
       // that built this transport. That is what keeps `ApiClient` injectable:
       // a Dart test that replaces `http.Client` through `http.runWithClient`
       // still drives the same request surface before the core is up.
       //
       // [fallbackClient] lets a test observe the fallback path (how many
       // requests actually went out over HTTP) instead of guessing from the
       // result alone.
       _httpFallback = HttpBackendTransport(
         baseUrl: 'http://127.0.0.1:$port',
         client: fallbackClient,
       );

  /// Listener port used when the caller does not supply one.
  ///
  /// `assets/config/config.json` is the single source of truth: the shipping
  /// app reads it after deploying and passes the value to [start]. This
  /// constant only covers callers that construct the transport directly (the
  /// host integration test, ad-hoc tooling) and must match that file.
  static const defaultPort = 18921;

  final int port;

  /// Empty in the shipping app. The host integration test sets it to a local
  /// mock server so the real FFI path can be verified offline.
  final String mockUpstreamOrigin;

  /// Process-wide flutter_rust_bridge runtime handle.
  ///
  /// The bridge refuses a second `RustLib.init()`, and the flag has to be
  /// static: a second transport instance in the same process (a restarted
  /// service, a test) must reuse the runtime instead of initializing it again.
  static Future<void>? _runtimeReady;

  String _baseUrl;
  String _capability = '';

  /// 当前这一轮核心启动。
  ///
  /// 它覆盖「核心还没被 [start]」（启动链的文件准备阶段）到「核心就绪」的
  /// 整个窗口。冷启动时请求可能早于核心到达——首页现在不等后端就绪——这时
  /// 必须挂起，而不是打到一个还没监听的端口上（#318）。
  ///
  /// null 表示「没有启动在进行」：此时请求维持既有回落，不挂起。
  _CoreRound? _coreRound;

  static Future<void> _nativeTail = Future<void>.value();
  static _CoreSession? _session;
  _CoreAttempt? _attempt;
  _CoreSession? _retiringSession;

  static Future<T> _serialize<T>(Future<T> Function() operation) {
    final pending = _nativeTail.then((_) => operation());
    _nativeTail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  static Future<void> _retire(_CoreSession session) async {
    if (!identical(_session, session)) return;
    session.retiring = true;
    // Keep the failed retirement as the singleton owner until shutdown succeeds.
    await rust.shutdown();
    if (identical(_session, session)) _session = null;
  }

  bool get _coreRunning {
    final attempt = _attempt;
    final session = attempt?.session;
    return attempt != null &&
        !attempt.retired &&
        session != null &&
        session.ready &&
        !session.retiring &&
        identical(_session, session);
  }

  /// Loads the bridge runtime once per process.
  ///
  /// A failed load is not cached: caching the rejected future would rethrow the
  /// same error on every later [start], so one bad native init would leave the
  /// app unable to reach the core for the rest of the process. Only this
  /// attempt's own handle is cleared on failure, so a concurrent retry that
  /// already installed a new future is never dropped.
  ///
  /// `RustLib.init` is not atomic: it installs FRB's process-wide state before
  /// running the Rust initializers, so a failure in that second half leaves a
  /// half-initialized bridge behind. A blind retry would then throw
  /// `Should not initialize flutter_rust_bridge twice` from FRB itself, so the
  /// half state is reset through FRB's own [RustLib.dispose] before the next
  /// attempt. A runtime that is already up is reused instead of re-initialized.
  static Future<void> ensureRuntime() {
    final cached = _runtimeReady;
    if (cached != null) return cached;
    if (runtimeInitialized()) return _runtimeReady = Future<void>.value();
    late final Future<void> attempt;
    attempt = Future<void>.sync(runtimeInitializer).catchError((
      Object error,
      StackTrace stack,
    ) {
      if (identical(_runtimeReady, attempt)) _runtimeReady = null;
      if (runtimeInitialized()) {
        try {
          disposeRuntime();
        } catch (resetError, resetStack) {
          // FRB could not release the half-initialized state. There is no
          // other reset entry point, so the process cannot retry cleanly;
          // make that actionable instead of looping on the same StateError.
          AppLog.e(
            'backend',
            'Flutter Rust Bridge 运行时复位失败，需要重启应用',
            error: resetError,
            stack: resetStack,
          );
        }
      }
      AppLog.e(
        'backend',
        'Flutter Rust Bridge 运行时初始化失败，下次启动重试',
        error: error,
        stack: stack,
      );
      Error.throwWithStackTrace(error, stack);
    });
    _runtimeReady = attempt;
    return attempt;
  }

  /// The loader [ensureRuntime] runs on first use; production always uses
  /// [RustLib.init]. A seam rather than a direct call, so the retry behavior
  /// can be tested without loading the shared library.
  @visibleForTesting
  static Future<void> Function() runtimeInitializer = initRustRuntime;

  /// Whether FRB already installed its process-wide state.
  ///
  /// Read before initializing (a runtime loaded by the host is reused) and
  /// after a failure (only a half-initialized bridge needs [disposeRuntime]).
  @visibleForTesting
  static bool Function() runtimeInitialized = () =>
      RustLib.instance.initialized;

  /// FRB's own reset entry point (`disposeImpl` clears the singleton state).
  @visibleForTesting
  static void Function() disposeRuntime = RustLib.dispose;

  /// Forgets the process-wide runtime handle. Only for tests.
  @visibleForTesting
  static void resetRuntimeForTest() {
    _runtimeReady = null;
    runtimeInitializer = initRustRuntime;
    runtimeInitialized = () => RustLib.instance.initialized;
    disposeRuntime = RustLib.dispose;
  }

  /// Records that the runtime is already initialized, for hosts that load the
  /// shared library themselves (the host integration test opens an explicit
  /// path).
  static void markRuntimeReady() {
    _runtimeReady ??= Future<void>.value();
  }

  final HttpBackendTransport _httpFallback;

  @override
  String get baseUrl => _baseUrl;

  @override
  String get capability => _capability;

  /// Process-wide monotonic id source.
  ///
  /// Request ids are registered in one global table inside the Rust core, so
  /// they must be unique across transport instances too - an instance-local
  /// counter would let two transports (a restarted service, a test) collide and
  /// cancel each other's calls.
  static int _requestIdCounter = 0;

  /// Allocates the next request id. Exposed so the uniqueness invariant can be
  /// tested without loading the shared library.
  static String nextRequestId() => 'fq-${_requestIdCounter++}';

  /// Initializes the Rust runtime and the backend core. Idempotent: concurrent
  /// and repeated calls converge on the same core.
  ///
  /// [listenPort] overrides [port] so the caller can drive the listener from
  /// `config.json` (the single source of truth) instead of the constructor.
  /// [lanShare] widens the listener from loopback to every interface.
  Future<String> start({
    required String configPath,
    required String poolPath,
    required String filterPath,
    required String runtimeDir,
    int? listenPort,
    bool lanShare = false,
  }) {
    final current = _attempt;
    if (current != null && !current.retired) return current.future;
    final attempt = _CoreAttempt();
    _attempt = attempt;
    // 直接调用 [start] 的路径（不经 [BackendService]）也要先宣布：
    // 这段时间请求可能已经到了。
    announceStart();
    attempt.future =
        _serialize(() async {
              void checkCurrent() {
                if (attempt.retired || !identical(_attempt, attempt)) {
                  throw StateError('backend start retired');
                }
              }

              checkCurrent();
              await ensureRuntime();
              checkCurrent();
              final previous = _session;
              if (previous != null && previous.retiring) {
                await _retire(previous);
                checkCurrent();
              }
              final shared = _session;
              if (shared != null) {
                shared.participants.add(attempt);
                attempt.session = shared;
                _publish(shared);
                return 'running';
              }
              // P1-2: provision the device-pool encryption key before init, so the
              // Rust core reads an encrypted pool file on its first load. A null
              // key (secure storage unavailable) keeps the old plaintext behavior;
              // a provisioning failure never blocks startup.
              final poolKey = await SecureKeyProvider().devicePoolKey();
              checkCurrent();
              if (poolKey == null &&
                  defaultTargetPlatform == TargetPlatform.linux) {
                throw StateError('Linux 设备池密钥不可用');
              }
              if (poolKey != null) {
                try {
                  await rust.setDevicePoolKey(key: poolKey);
                } catch (_) {
                  if (defaultTargetPlatform == TargetPlatform.linux) rethrow;
                  // Keep starting: the pool falls back to plaintext + a warning.
                }
                checkCurrent();
              }
              final session = _CoreSession()..participants.add(attempt);
              attempt.session = session;
              _session = session;
              try {
                final result = await rust.init(
                  configPath: configPath,
                  poolPath: poolPath,
                  filterPath: filterPath,
                  runtimeDir: runtimeDir,
                  port: listenPort ?? port,
                  lanShare: lanShare,
                  mockUpstreamOrigin: mockUpstreamOrigin,
                );
                checkCurrent();
                if (result != 'running') {
                  throw StateError('Rust core failed: $result');
                }
                session.baseUrl = await rust.baseUrl();
                checkCurrent();
                session.capability = await rust.sessionCapability();
                checkCurrent();
                _publish(session);
                return result;
              } catch (_) {
                attempt.retired = true;
                session.participants.remove(attempt);
                // This cleanup remains inside the operation that allocated the core.
                await _retire(session);
                rethrow;
              }
            })
            .catchError((Object error) {
              // 启动失败也要唤醒等待「核心就绪」的请求：否则它们会一直等到
              // 自己的超时，冷启动的首页就会一直转圈而不是立刻报失败。
              settleCore(failure: error);
              throw error;
            })
            .whenComplete(() {
              if (identical(_attempt, attempt) && !_coreRunning) {
                attempt.retired = true;
              }
            });
    return attempt.future;
  }

  /// 宣布核心即将启动（幂等）。
  ///
  /// [BackendService.start] 在任何 await 之前打这个招呼：启动链上还有一段文件
  /// 准备（目录、配置、部署），那段时间核心还没被 [start]、`_attempt` 还不
  /// 存在，但首页已经可能发请求了——挂起它们，而不是打到一个还没监听的端口
  /// 上（#318）。
  void announceStart() {
    final round = _coreRound;
    // 这一轮还在进行中：不重建，等待方读的还是同一个对象。
    if (round != null && !round.done.isCompleted) return;
    _coreRound = _CoreRound();
  }

  /// 核心就绪，或核心没起来（[failure] 非空）：唤醒挂起的请求。
  ///
  /// 成功与失败都只完成一次：等待方据 [failure] 判断该放行还是该失败。
  void settleCore({Object? failure}) {
    final round = _coreRound;
    if (round == null) return;
    // 已经出结果的一轮不再被改写：后来的一次停机不能把已经成功的那一轮
    // 改成失败。
    if (round.done.isCompleted) return;
    round.failure = failure;
    round.done.complete();
  }

  void _publish(_CoreSession session) {
    session.ready = true;
    _baseUrl = session.baseUrl;
    _capability = session.capability;
    _httpFallback.capability = session.capability;
    settleCore();
  }

  Future<String> status() async {
    if (!_coreRunning) return 'starting';
    final attempt = _attempt;
    final result = await _serialize(rust.status);
    return identical(attempt, _attempt) && _coreRunning ? result : 'starting';
  }

  Future<void> stop() {
    final attempt = _attempt;
    _attempt = null;
    _baseUrl = 'http://127.0.0.1:$port';
    _capability = '';
    _httpFallback.capability = '';
    attempt?.retired = true;
    // 停掉时也要唤醒等待「核心就绪」的请求：让它们立刻拿到失败，而不是
    // 各自等到超时。
    settleCore(failure: StateError('backend stopped'));
    final session = attempt?.session ?? _retiringSession;
    if (attempt == null && session == null) return Future<void>.value();
    if (session != null) {
      if (attempt != null) session.participants.remove(attempt);
      if (session.participants.isNotEmpty) return Future<void>.value();
      session.retiring = true;
      _retiringSession = session;
    }
    return _serialize(() async {
      if (session != null) {
        await _retire(session);
        if (identical(_retiringSession, session)) _retiringSession = null;
      }
    });
  }

  @override
  Future<void> close() async {
    await Future.wait<void>([stop(), _httpFallback.close()]);
  }

  /// 等核心就绪，并把剩余预算交回给本次请求。
  ///
  /// 返回 `null` 表示调用方原本就没有 deadline（Rust 侧 `timeout_ms <= 0`），
  /// 等待不能替它加上限时；返回非空表示「扣掉等待后的剩余预算」。
  ///
  /// 抽成静态方法是为了能脱离 FRB 桥单测：等待期间必须响应
  /// [BackendRequest.whenCancelled]，核心启动失败/停止要立刻失败。
  @visibleForTesting
  static Future<Duration?> awaitCoreReady({
    required Future<void> ready,
    required BackendRequest? request,
    required Duration? budget,
    required Object? Function() failureOf,
    Stopwatch? clock,
  }) async {
    final callerBudget = budget;
    final waitBudget = callerBudget ?? const Duration(seconds: 20);
    // 契约：调用方可以传自己的 Stopwatch（跨「排队/等待」连续计时），
    // 没 start 的也由这里补上，避免 elapsed 恒为 0 而漏扣等待时间。
    final stopwatch = clock ?? Stopwatch();
    if (!stopwatch.isRunning) stopwatch.start();
    final wait = request == null
        ? ready
        : Future.any<void>([ready, request.whenCancelled]);
    await wait.timeout(
      waitBudget,
      onTimeout: () => throw BackendRequestAborted('本地服务启动超时', timedOut: true),
    );
    // 取消优先于启动失败：两个 future 同帧完成时，调用方要的是「被取消」。
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    final failure = failureOf();
    if (failure != null) {
      // 核心没起来是终局失败：重试同一个请求只会把同一个失败再跑一遍。
      throw BackendRequestAborted('本地服务启动失败：$failure', fatal: true);
    }
    if (callerBudget == null) return null;
    final remaining = callerBudget - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      throw BackendRequestAborted('请求超时', timedOut: true);
    }
    return remaining;
  }

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    if (!_coreRunning) {
      // 核心没在运行。若它正在启动（冷启动），请求挂到核心就绪为止：首个请求
      // 不该撞上一个还没监听的端口（那会让首页首帧直接失败，而不是随核心
      // 就绪自动落位）。等待预算算进本次请求的超时里——核心一直起不来时按
      // 超时失败（#318）。
      final round = _coreRound;
      if (round == null || round.done.isCompleted) {
        // 没有启动在进行（或这一轮已经结束）：维持既有回落。
        //
        // 「这一轮已经结束」必须和「正在启动」分开：失败原因写在轮次上，
        // 等待方读到的永远是自己那一轮的结果。核心被停掉之后再来的请求，
        // 不该继承上一轮的「backend stopped」——那是上一轮的结果。
        return _httpFallback.send(
          method,
          url,
          body: body,
          timeout: timeout,
          request: request,
        );
      }
      // 调用方没给 timeout 表示「不设 deadline」（Rust 侧 `timeout_ms <= 0`）。
      // 这里的预算只用于**等核心就绪**：等到了就把剩余时间交回给请求，
      // 但绝不能因为等待而给一个原本无 deadline 的请求凭空加上限时。
      final clock = Stopwatch()..start();
      final remaining = await awaitCoreReady(
        ready: round.done.future,
        request: request,
        budget: timeout,
        // 只读自己这一轮的失败原因：后来的轮次不会改写它。
        failureOf: () => round.failure,
        clock: clock,
      );
      if (remaining != null) timeout = remaining;
      if (!_coreRunning) {
        // 核心没能起来：保持既有回落，交给上层走错误态。
        return _httpFallback.send(
          method,
          url,
          body: body,
          timeout: timeout,
          request: request,
        );
      }
    }

    final attempt = _attempt;
    final requestId = nextRequestId();
    void cancelInRust() {
      unawaited(rust.cancel(requestId: requestId));
    }

    if (request != null && !request.register(cancelInRust)) {
      throw BackendRequestAborted('请求已取消');
    }

    final pending = rust.request(
      requestId: requestId,
      method: method,
      path: url.path,
      query: url.query,
      body: body ?? Uint8List(0),
      timeoutMs: timeout?.inMilliseconds ?? 0,
    );

    try {
      final response = request == null
          ? await pending
          : await Future.any<rust.BridgeResponse?>([
              pending,
              request.whenCancelled.then((_) => null),
            ]);
      if (response == null || !identical(attempt, _attempt) || !_coreRunning) {
        cancelInRust();
        throw BackendRequestAborted('请求已取消');
      }
      if (response.status == 499) {
        throw BackendRequestAborted('请求已取消');
      }
      if (response.status == 504) {
        throw BackendRequestAborted('请求超时', timedOut: true);
      }
      return BackendResponse(
        response.status,
        response.body,
        response.contentType,
      );
    } finally {
      request?.unregister(cancelInRust);
    }
  }
}

/// 一轮核心启动的状态。
///
/// 完成信号与失败原因绑在同一个对象上：等待方只读自己那一轮的结果，不会被
/// 后来的轮次污染（#318）。
class _CoreRound {
  /// 这一轮结束（成功或失败）时完成。
  final Completer<void> done = Completer<void>();

  /// 这一轮失败的原因；成功时为 null。
  ///
  /// 只在 [done] 完成前写入：已经出结果的一轮不再被后来的失败改写。
  Object? failure;
}

class _CoreAttempt {
  late Future<String> future;
  bool retired = false;
  _CoreSession? session;
}

class _CoreSession {
  final Set<_CoreAttempt> participants = {};
  bool retiring = false;
  bool ready = false;
  String baseUrl = '';
  String capability = '';
}

/// HTTP transport for the loopback adapter, Dart tests and the Web build.
class HttpBackendTransport implements BackendTransport {
  HttpBackendTransport({
    http.Client? client,
    required this.baseUrl,
    this.capability = '',
  }) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  final String baseUrl;

  /// Loopback capability presented as a bearer token; empty when the caller
  /// talks to a server that does not ask for one.
  ///
  /// Mutable because the FFI transport only learns it once the core is up.
  @override
  String capability;

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    final abort = Completer<void>();
    void abortNow() {
      if (!abort.isCompleted) abort.complete();
    }

    if (request != null && !request.register(abortNow)) {
      throw BackendRequestAborted('请求已取消');
    }

    final httpRequest = http.AbortableRequest(
      method,
      url,
      abortTrigger: abort.future,
    );
    if (body != null) httpRequest.bodyBytes = body;
    if (capability.isNotEmpty) {
      // This is the only HTTP path that never sees the cookie the entry URL
      // sets, so it has to present the capability as a bearer token.
      httpRequest.headers['authorization'] = 'Bearer $capability';
    }
    try {
      // The deadline must cover reading the body too: a server that sends
      // headers and then stalls would otherwise hold the connection forever.
      final response = await _client
          .send(httpRequest)
          .then(http.Response.fromStream)
          .timeout(timeout ?? const Duration(seconds: 20));
      return BackendResponse(
        response.statusCode,
        response.bodyBytes,
        response.headers['content-type'] ?? '',
      );
    } catch (error) {
      // A timed-out or cancelled exchange must not keep occupying a connection.
      abortNow();
      if (request != null &&
          request.isCancelled &&
          error is! BackendRequestAborted) {
        throw BackendRequestAborted('请求已取消');
      }
      rethrow;
    } finally {
      request?.unregister(abortNow);
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}
