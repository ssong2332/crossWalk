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
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakelockToggleChannel.name, null);
  });

  Finder errorOverlayFinder() => find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox &&
            // ignore: deprecated_member_use
            widget.color == Colors.red.withOpacity(0.25),
      );

  group('CameraScreen — _hasError overlay + retry (ordinary denial)', () {
    testWidgets(
      'shows red overlay, 카메라 권한 필요, and a 다시 시도 retry button',
      (tester) async {
        mockPermissionHandler(deniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();

        expect(find.text('카메라 권한 필요'), findsOneWidget);
        expect(errorOverlayFinder(), findsOneWidget);
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
        expect(errorOverlayFinder(), findsOneWidget);
      },
    );
  });

  group('CameraScreen — _hasError overlay + retry (permanent denial)', () {
    testWidgets(
      'shows red overlay, 카메라 권한 필요 (설정 이동), and a 설정 열기 button',
      (tester) async {
        mockPermissionHandler(permanentlyDeniedStatusValue);

        await tester.pumpWidget(const MaterialApp(home: CameraScreen()));
        await tester.pumpAndSettle();

        expect(find.text('카메라 권한 필요 (설정 이동)'), findsOneWidget);
        expect(errorOverlayFinder(), findsOneWidget);
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
}
