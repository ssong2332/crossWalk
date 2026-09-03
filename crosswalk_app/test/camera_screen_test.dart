// Widget tests for CameraScreen's error/retry states (T11).
//
// _initCamera() awaits FeedbackService.init() (flutter_tts) then
// Permission.camera.request() (permission_handler) FIRST. If the camera
// permission is not granted, both denial branches `return` immediately —
// Classifier.init() and availableCameras() (the `camera` plugin) are never
// reached. That means both `_hasError` paths exercised below only require
// mocking permission_handler + flutter_tts (+ wakelock_plus, used in
// initState/dispose) — no need to mock the `camera` plugin's channel at all.
//
// Platform channel names below were verified by reading the actual package
// source under the pub cache (see each mock's comment for the exact file),
// not guessed — matching this repo's established verification discipline
// (see docs/Tasks.md T24/T25 notes).
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/messages.g.dart';
import 'package:crosswalk_app/screens/camera_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // permission_handler 11.4.0 -> permission_handler_platform_interface
  // 4.3.0's MethodChannelPermissionHandler
  // (lib/src/method_channel/method_channel_permission_handler.dart:9-10):
  // const MethodChannel _methodChannel =
  //     MethodChannel('flutter.baseflow.com/permissions/methods');
  const permissionChannel =
      MethodChannel('flutter.baseflow.com/permissions/methods');

  // flutter_tts 4.2.5 (lib/flutter_tts.dart:330):
  // static const MethodChannel _channel = MethodChannel('flutter_tts');
  const ttsChannel = MethodChannel('flutter_tts');

  // wakelock_plus_platform_interface 1.3.0 (lib/messages.g.dart) is a
  // Pigeon-generated API, not a plain MethodChannel: WakelockPlus.enable()/
  // disable() call WakelockPlusApi.toggle(), which sends on a
  // BasicMessageChannel named
  // 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle'
  // using WakelockPlusApi.pigeonChannelCodec (messages.g.dart:167,172-192).
  final wakelockToggleChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    WakelockPlusApi.pigeonChannelCodec,
  );

  // permission_handler_platform_interface 4.3.0's PermissionStatusValue
  // int encoding (lib/src/permission_status.dart:49-64): denied=0,
  // granted=1, permanentlyDenied=4. Permission.camera.value == 1
  // (permissions.dart:39: `static const camera = Permission._(1);`).
  const cameraPermissionValue = 1;
  const deniedStatusValue = 0;
  const permanentlyDeniedStatusValue = 4;

  late int requestPermissionsCallCount;
  late bool openAppSettingsCalled;

  void mockPermissionHandler(int statusValueToReturn) {
    requestPermissionsCallCount = 0;
    openAppSettingsCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
      switch (call.method) {
        case 'requestPermissions':
          requestPermissionsCallCount++;
          // requestPermissions expects a Map<int, int> keyed by
          // Permission.value with PermissionStatus.value as the value
          // (see decodePermissionRequestResult in
          // method_channel_permission_handler's utils/codec.dart:15-19).
          return <int, int>{cameraPermissionValue: statusValueToReturn};
        case 'openAppSettings':
          openAppSettingsCalled = true;
          return true;
        default:
          return null;
      }
    });
  }

  void mockFlutterTts() {
    // FeedbackService.init()/announceError() call setLanguage/
    // setSpeechRate/setVolume/stop/speak; none of the call sites inspect
    // the return value beyond awaiting it, so any non-throwing response
    // is sufficient.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
  }

  void mockWakelockPlus() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockToggleChannel.name, (message) async {
      // WakelockPlusApi.toggle() only throws if the reply list has more
      // than 1 element (an error) or is null (channel unreachable); a
      // single-element `[null]` list is treated as a successful void
      // response (messages.g.dart:179-191).
      return wakelockToggleChannel.codec.encodeMessage(<Object?>[null]);
    });
  }

  setUp(() {
    mockFlutterTts();
    mockWakelockPlus();
    // T34: CameraScreen now derives its display/TTS language from
    // WidgetsBinding.instance.platformDispatcher.locale. That value
    // otherwise reflects whatever locale the host machine/CI runner
    // happens to report (not necessarily the same between this dev
    // machine and CI), which would make the Korean text assertions below
    // non-deterministic. Pin it explicitly so this test's language is
    // fixed regardless of environment.
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('ko', 'KR');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockToggleChannel.name, null);
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearLocaleTestValue();
  });

  // Claude Design import: the red-tint overlay + bottom-tray retry button
  // were replaced by a dedicated full-screen error card (scrim +
  // icon-in-circle + title + single CTA) — see _buildErrorCard() in
  // camera_screen.dart. This finder locates that card's icon circle.
  Finder errorCardFinder() => find.byIcon(Icons.priority_high);

  group('CameraScreen — _hasError card + retry (ordinary denial)', () {
    testWidgets(
      'shows the full-screen error card, 카메라 권한 필요, and a 다시 시도 retry button',
      (tester) async {
        mockPermissionHandler(deniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();

        expect(find.text('카메라 권한 필요'), findsOneWidget);
        expect(errorCardFinder(), findsOneWidget);
        expect(find.text('다시 시도'), findsOneWidget);
        expect(find.text('설정 열기'), findsNothing);
        expect(find.byIcon(Icons.refresh), findsOneWidget);
        expect(find.byIcon(Icons.settings), findsNothing);
        // Loading spinner must not show once _hasError is true.
        expect(find.byType(CircularProgressIndicator), findsNothing);

        expect(requestPermissionsCallCount, 1);
      },
    );

    testWidgets(
      'tapping 다시 시도 re-invokes _initCamera (re-requests permission)',
      (tester) async {
        mockPermissionHandler(deniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();
        expect(requestPermissionsCallCount, 1);

        await tester.tap(find.text('다시 시도'));
        await tester.pumpAndSettle();

        expect(requestPermissionsCallCount, 2);
        // Still denied (mock keeps returning `denied`) -> still in the
        // same ordinary-denial error state.
        expect(find.text('카메라 권한 필요'), findsOneWidget);
        expect(errorCardFinder(), findsOneWidget);
      },
    );
  });

  group('CameraScreen — _hasError card + retry (permanent denial)', () {
    testWidgets(
      'shows the full-screen error card, 카메라 권한 필요 (설정 이동), and a 설정 열기 button',
      (tester) async {
        mockPermissionHandler(permanentlyDeniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();

        expect(find.text('카메라 권한 필요 (설정 이동)'), findsOneWidget);
        expect(errorCardFinder(), findsOneWidget);
        expect(find.text('설정 열기'), findsOneWidget);
        expect(find.text('다시 시도'), findsNothing);
        expect(find.byIcon(Icons.settings), findsOneWidget);
        expect(find.byIcon(Icons.refresh), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets(
      'tapping 설정 열기 invokes openAppSettings()',
      (tester) async {
        mockPermissionHandler(permanentlyDeniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();
        expect(openAppSettingsCalled, isFalse);

        await tester.tap(find.text('설정 열기'));
        await tester.pumpAndSettle();

        expect(openAppSettingsCalled, isTrue);
      },
    );
  });

  // Claude Design 1a: 카메라 프리뷰와 유리(BackdropFilter) HUD, 그리고 코리도
  // 오버레이가 전부 제거됐다. 화면은 이제 단색 배경 위의 계기판이고, 상태는
  // `StateFieldPainter`가 **형태와 위치**로 그린다.
  //
  // 이 위젯 테스트들에서 `Classifier.processFrame()`은 절대 실행되지 않으므로
  // (카메라 이미지 스트림을 넣지 않는다) 상태 전환 자체는 아래 순수 Dart
  // 페인터 테스트로 덮는다. 위젯 수준에서 검증 가능한 것은 오류 상태에서
  // 계기판이 사라지고 전용 오류 카드가 나온다는 것이다.
  group('CameraScreen — 상태 필드 / 프리뷰 제거', () {
    Finder stateFieldFinder() => find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is StateFieldPainter,
        );

    testWidgets(
      '오류 상태에서는 상태 필드 대신 오류 카드를 보여준다',
      (tester) async {
        mockPermissionHandler(deniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();

        expect(stateFieldFinder(), findsNothing);
        expect(errorCardFinder(), findsOneWidget);
      },
    );

    testWidgets(
      '유리(BackdropFilter) HUD는 어느 상태에서도 더 이상 존재하지 않는다',
      (tester) async {
        // 권한 응답을 설정하지 않으면 CameraScreen이 초기 로딩 상태
        // (_isLoading == true, _hasError == false)에 머문다.
        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pump();

        expect(find.byType(BackdropFilter), findsNothing);
      },
    );

    testWidgets(
      '카메라 프리뷰를 렌더링하지 않는다 — 배경이 매 프레임 바뀌면 대비를 '
      '보장할 수 없기 때문',
      (tester) async {
        mockPermissionHandler(deniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();

        expect(find.byType(CameraPreview), findsNothing);
      },
    );
  });

  // T72(2026-09-04, 사용자 지시): 화살표는 상태와 무관하게 **항상 화면
  // 중앙**에 그리고 방향(회전)만 바꾼다. 이전에는 left를 0.30, right를 0.70
  // 위치로 옮겼다. 위치는 캔버스에 그려진 픽셀이라 위젯 테스트로는 잡히지
  // 않으므로, `Canvas.translate` 호출을 기록하는 대역 캔버스로 직접 확인한다.
  group('StateFieldPainter — 화살표는 세 상태 모두 중앙에 그린다 (T72)', () {
    const size = Size(300, 200);
    const center = Offset(150, 100);

    Offset arrowOriginFor(String state, {double? angle}) {
      final canvas = _TranslateRecordingCanvas();
      StateFieldPainter(
        state: state,
        color: const Color(0xFFF2B14A),
        stripeAngleDegrees: angle,
      ).paint(canvas, size);
      expect(canvas.translations, hasLength(1),
          reason: '$state는 화살표를 정확히 한 번 그려야 한다');
      return canvas.translations.single;
    }

    for (final state in ['front', 'left', 'right']) {
      test('$state — 각도를 모를 때도 중앙', () {
        expect(arrowOriginFor(state), equals(center));
      });

      test('$state — 각도를 알 때도 중앙 (회전만 바뀐다)', () {
        expect(arrowOriginFor(state, angle: 40), equals(center));
      });
    }
  });

  // StateFieldPainter는 위젯 트리에 의존하지 않는 순수 CustomPainter이므로
  // 다시 그릴 조건을 직접 검증할 수 있다.
  group('StateFieldPainter — shouldRepaint', () {
    test('상태가 바뀌면 다시 그린다 (front -> left)', () {
      const oldPainter =
          StateFieldPainter(state: 'front', color: Color(0xFFA8CDE8));
      const newPainter =
          StateFieldPainter(state: 'left', color: Color(0xFFF2B14A));

      expect(newPainter.shouldRepaint(oldPainter), isTrue);
    });

    test('색만 바뀌어도 다시 그린다', () {
      const oldPainter =
          StateFieldPainter(state: 'front', color: Color(0xFFA8CDE8));
      const newPainter =
          StateFieldPainter(state: 'front', color: Color(0xFFF2B14A));

      expect(newPainter.shouldRepaint(oldPainter), isTrue);
    });

    test('상태와 색이 모두 같으면 다시 그리지 않는다', () {
      const oldPainter =
          StateFieldPainter(state: 'right', color: Color(0xFFF2B14A));
      const newPainter =
          StateFieldPainter(state: 'right', color: Color(0xFFF2B14A));

      expect(newPainter.shouldRepaint(oldPainter), isFalse);
    });

    test(
      'left와 right는 같은 색을 쓴다 — 방향은 색이 아니라 화살표 회전으로 '
      '전달되므로 색각이상에서도 구분된다',
      () {
        const left = StateFieldPainter(state: 'left', color: Color(0xFFF2B14A));
        const right =
            StateFieldPainter(state: 'right', color: Color(0xFFF2B14A));

        expect(left.color, equals(right.color));
        // 같은 색이지만 상태가 다르므로 다시 그려야 한다 (회전각이 다름).
        // T72 이후 위치는 세 상태 모두 중앙으로 같다.
        expect(right.shouldRepaint(left), isTrue);
      },
    );

    // T63: 강도(severe)만 바뀌어도 다시 그려야 한다 — 굵은 화살표로
    // 전환되는 시각적 변화를 놓치면 안 된다.
    test('강도만 바뀌어도 다시 그린다', () {
      const mildPainter = StateFieldPainter(
        state: 'left',
        color: Color(0xFFF2B14A),
      );
      const severePainter = StateFieldPainter(
        state: 'left',
        color: Color(0xFFFF5A5F),
        severe: true,
      );

      expect(severePainter.shouldRepaint(mildPainter), isTrue);
    });

    test('severe 기본값은 false다', () {
      const painter =
          StateFieldPainter(state: 'left', color: Color(0xFFF2B14A));
      expect(painter.severe, isFalse);
    });

    // T67: 줄무늬 각도가 바뀌면 화살표 회전이 달라지므로 반드시 다시 그려야
    // 한다 — 빠뜨리면 화살표가 첫 각도에 멈춰 있게 된다.
    test('줄무늬 각도만 바뀌어도 다시 그린다', () {
      const a = StateFieldPainter(
        state: 'left',
        color: Color(0xFFF2B14A),
        stripeAngleDegrees: 10,
      );
      const b = StateFieldPainter(
        state: 'left',
        color: Color(0xFFF2B14A),
        stripeAngleDegrees: 25,
      );
      expect(b.shouldRepaint(a), isTrue);
    });

    test('각도가 있다가 무판정(null)이 되어도 다시 그린다', () {
      const withAngle = StateFieldPainter(
        state: 'right',
        color: Color(0xFFF2B14A),
        stripeAngleDegrees: 10,
      );
      const withoutAngle =
          StateFieldPainter(state: 'right', color: Color(0xFFF2B14A));
      expect(withoutAngle.shouldRepaint(withAngle), isTrue);
    });

    test('줄무늬 각도 기본값은 null이다 (모르면 회전하지 않는다)', () {
      const painter =
          StateFieldPainter(state: 'front', color: Color(0xFFA8CDE8));
      expect(painter.stripeAngleDegrees, isNull);
    });
  });

  // T67: 화살표가 감지된 횡단보도 방향을 따라가는 조건.
  group('StateFieldPainter — 줄무늬 각도 추적 조건', () {
    test('각도를 알면 front/left/right에서 화살표가 회전한다', () {
      for (final state in ['front', 'left', 'right']) {
        final painter = StateFieldPainter(
          state: state,
          color: const Color(0xFFF2B14A),
          stripeAngleDegrees: 20,
        );
        expect(painter.tracksStripeForTest, isTrue, reason: 'state=$state');
      }
    });

    test('각도를 모르면 어떤 상태에서도 회전하지 않는다', () {
      for (final state in ['front', 'left', 'right']) {
        final painter = StateFieldPainter(
          state: state,
          color: const Color(0xFFF2B14A),
        );
        expect(painter.tracksStripeForTest, isFalse, reason: 'state=$state');
      }
    });

    test('화살표가 아닌 상태(approach/none/nocall)는 각도가 있어도 회전하지 않는다', () {
      for (final state in ['approach', 'none', 'nocall']) {
        final painter = StateFieldPainter(
          state: state,
          color: const Color(0xFFCBD1D6),
          stripeAngleDegrees: 20,
        );
        expect(painter.tracksStripeForTest, isFalse, reason: 'state=$state');
      }
    });

    // 기하 검증: 줄무늬는 진행 방향과 수직이므로 회전각 = θ − π/2.
    // θ=0(줄무늬가 화면에서 수평)이면 위쪽(−π/2)을 가리켜야 하고, 이는
    // 각도를 모를 때의 'front' 화살표 방향과 정확히 일치해야 한다.
    test('각도 0도는 위쪽(-π/2)을 가리킨다 — 기존 front 화살표와 일치', () {
      const painter = StateFieldPainter(
        state: 'front',
        color: Color(0xFFA8CDE8),
        stripeAngleDegrees: 0,
      );
      expect(painter.stripeRotationForTest, closeTo(-math.pi / 2, 1e-9));
    });

    test('양수 각도는 시계방향으로, 음수 각도는 반시계방향으로 돈다', () {
      const right = StateFieldPainter(
        state: 'front',
        color: Color(0xFFA8CDE8),
        stripeAngleDegrees: 30,
      );
      const left = StateFieldPainter(
        state: 'front',
        color: Color(0xFFA8CDE8),
        stripeAngleDegrees: -30,
      );
      expect(right.stripeRotationForTest, greaterThan(-math.pi / 2));
      expect(left.stripeRotationForTest, lessThan(-math.pi / 2));
      // 30도 회전은 정확히 π/6 라디안만큼 벌어져야 한다.
      expect(
        right.stripeRotationForTest - (-math.pi / 2),
        closeTo(math.pi / 6, 1e-9),
      );
    });
  });
}

/// `Canvas.translate` 호출만 기록하는 대역 캔버스.
///
/// `StateFieldPainter._arrow`는 `save -> translate(중심) -> rotate -> drawLine
/// x3 -> restore` 순서로 그린다. 화살표의 **위치**는 이 translate 인자에
/// 그대로 담기므로, 픽셀을 렌더링하지 않고도 중앙 고정을 검증할 수 있다.
/// 나머지 Canvas 멤버는 noSuchMethod로 조용히 무시한다 — 이 테스트가 보는
/// 것은 위치뿐이다.
class _TranslateRecordingCanvas implements Canvas {
  final List<Offset> translations = <Offset>[];

  @override
  void translate(double dx, double dy) => translations.add(Offset(dx, dy));

  @override
  void save() {}

  @override
  void restore() {}

  @override
  void rotate(double radians) {}

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
