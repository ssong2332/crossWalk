// T209: 저시력 UI — 사용자가 볼 수 있는 화면마다 글자 배율 1.0·2.0에서
// 오버플로(RenderFlex overflowed 등) 오류가 없는지, 그리고 슬라이더·연결 상태의
// 화면 읽기 연결을 확인한다.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crosswalk_app/localization/app_strings.dart';
import 'package:crosswalk_app/main.dart' show lowVisionTheme;
import 'package:crosswalk_app/screens/camera_screen.dart';
import 'package:crosswalk_app/screens/onboarding_screen.dart';
import 'package:crosswalk_app/screens/settings_screen.dart';
import 'package:crosswalk_app/screens/share_picker_screen.dart';
import 'package:crosswalk_app/services/event_log.dart';
import 'package:crosswalk_app/services/feedback_service.dart';
import 'package:crosswalk_app/services/route_nav.dart';
import 'package:crosswalk_app/services/score_timeline.dart';
import 'package:crosswalk_app/services/share_picker.dart';
import 'package:crosswalk_app/services/vib_module.dart';
import 'package:crosswalk_app/services/walk_info.dart';
import 'package:crosswalk_app/widgets/haptic_score.dart';
import 'package:crosswalk_app/widgets/route_overlay.dart';
import 'package:crosswalk_app/widgets/walk_info_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/messages.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const permissionChannel =
      MethodChannel('flutter.baseflow.com/permissions/methods');
  const ttsChannel = MethodChannel('flutter_tts');
  final wakelockToggleChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    WakelockPlusApi.pigeonChannelCodec,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void permissionAnswer(Future<Map<int, int>> Function() answer) {
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'requestPermissions') return answer();
      return null;
    });
  }

  setUp(() {
    messenger.setMockMethodCallHandler(ttsChannel, (call) async => 1);
    messenger.setMockMessageHandler(wakelockToggleChannel.name,
        (m) async => wakelockToggleChannel.codec.encodeMessage(<Object?>[null]));
    permissionAnswer(() async => <int, int>{1: 0}); // 카메라 권한 거부
    TestWidgetsFlutterBinding.instance.platformDispatcher.localeTestValue =
        const Locale('ko', 'KR');
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(permissionChannel, null);
    messenger.setMockMethodCallHandler(ttsChannel, null);
    messenger.setMockMessageHandler(wakelockToggleChannel.name, null);
    final d = TestWidgetsFlutterBinding.instance.platformDispatcher;
    d.clearLocaleTestValue();
    d.clearTextScaleFactorTestValue();
    WalkInfoService.instance.view.value = null;
  });

  /// 360x780dp 폰 화면, 글자 배율 [scale]로 [screen]을 그린다.
  Future<void> pumpAt(WidgetTester t, double scale, Widget screen) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    t.platformDispatcher.textScaleFactorTestValue = scale;
    await t.pumpWidget(MaterialApp(theme: lowVisionTheme(), home: screen));
    await t.pump(const Duration(milliseconds: 500));
    expect(MediaQuery.textScalerOf(t.element(find.byType(Scaffold).first)).scale(16),
        16 * scale);
  }

  /// 목록 화면은 끝까지 내리며 그려지는 줄마다 오버플로를 확인한다.
  Future<void> scrollToEnd(WidgetTester t) async {
    final list = find.byType(Scrollable).first;
    for (var i = 0; i < 30; i++) {
      await t.drag(list, const Offset(0, -300));
      await t.pump(const Duration(milliseconds: 200));
    }
  }

  for (final scale in [1.0, 2.0]) {
    group('글자 배율 $scale — 오버플로 없음', () {
      testWidgets('카메라 화면: 권한 오류 카드', (t) async {
        await pumpAt(t, scale, const CameraScreen());
        await t.pumpAndSettle();
        expect(find.text('카메라 권한 필요'), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('카메라 화면: 준비 중(메인 배치·상단 버튼·하단 안내)', (t) async {
        final answer = Completer<Map<int, int>>();
        permissionAnswer(() => answer.future);
        await pumpAt(t, scale, const CameraScreen());
        expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        answer.complete(<int, int>{1: 0});
        await t.pump();
      });

      testWidgets('카메라 화면: 준비 중 + 경로 안내 중(미니맵·목적지 글자)', (t) async {
        final answer = Completer<Map<int, int>>();
        permissionAnswer(() => answer.future);
        WalkInfoService.instance.view.value = RouteView(_geo(),
            const math.Point(0, 70), 70, null, '30m 왼쪽', '서울특별시청 시민청 서울도서관');
        await pumpAt(t, scale, const CameraScreen());
        expect(find.textContaining('까지'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        answer.complete(<int, int>{1: 0});
        await t.pump();
      });

      testWidgets('온보딩 화면', (t) async {
        await pumpAt(t, scale, const OnboardingScreen());
        await scrollToEnd(t);
        expect(t.takeException(), isNull);
      });

      testWidgets('설정 화면(모든 구역·진동 모듈 켬)', (t) async {
        await pumpAt(
            t,
            scale,
            SettingsScreen(
              feedback: FeedbackService(),
              language: AppLanguage.ko,
              onLanguageChanged: (_) {},
              torchEnabled: false,
              onTorchChanged: (_) async {},
              powerSaveMode: true,
              onPowerSaveModeChanged: (_) {},
              onSurfaceGuidanceChanged: (_) {},
              onCautionGuidanceChanged: (_) {},
              onCrosswalkGateChanged: (_) {},
              onEventLogChanged: (_) {},
              onShareEventLog: () async => null,
              onScoreChanged: (_) {},
              onUltraWideChanged: (_) {},
              onCameraMountChanged: (_) {},
              onFrameSaveChanged: (_) {},
              onShareFrames: () async => null,
              vibModuleEnabled: true,
              onVibModuleChanged: (_) {},
              vibModuleState: ValueNotifier(VibLinkState.searching),
              onVibModuleWithPhoneChanged: (_) {},
              onVibModuleStrengthChanged: (_) {},
              onVibModuleTest: (_) {},
            ));
        await scrollToEnd(t);
        expect(t.takeException(), isNull);
      });

      testWidgets('공유 고르기 화면', (t) async {
        final items = [
          for (var i = 0; i < 6; i++)
            ShareItem(
                path: 'p$i',
                files: [File('f$i')],
                bytes: 2048 * (i + 1),
                start: DateTime(2026, 11, 25, 12, i),
                build: '0bdc62b0000',
                sent: i.isEven,
                current: i == 0),
        ];
        await pumpAt(
            t,
            scale,
            SharePickerScreen(
                strings: AppStrings.of(AppLanguage.ko),
                title: '기록 보내기',
                items: items));
        await scrollToEnd(t);
        expect(t.takeException(), isNull);
      });

      testWidgets('목적지 안내 화면 + 검색 목록', (t) async {
        await pumpAt(
            t,
            scale,
            DestinationScreen(
                feedback: FeedbackService(), language: AppLanguage.ko));
        expect(t.takeException(), isNull);
        await pumpAt(
            t,
            scale,
            Scaffold(
              body: ListView(children: [
                PlaceList(
                  places: const [
                    Place('서울특별시청 시민청 지하 1층 서울도서관 앞', 37, 127, 346),
                    Place('시청', 35, 129, 250000),
                  ],
                  language: AppLanguage.ko,
                  enabled: true,
                  onTap: (_) {},
                ),
              ]),
            ));
        expect(t.takeException(), isNull);
      });

      testWidgets('미니맵 + 목적지 글자', (t) async {
        await pumpAt(
            t,
            scale,
            Scaffold(body: RouteOverlay(onSpeak: (_) {})));
        WalkInfoService.instance.view.value = RouteView(_geo(), const math.Point(0, 70),
            70, null, '30m 왼쪽', '서울특별시청 시민청 서울도서관');
        await t.pump();
        expect(find.textContaining('까지'), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('촉각 악보', (t) async {
        final tl = ScoreTimeline();
        final now = DateTime(2026, 11, 25, 12);
        tl.add('say', {'text': '왼쪽으로 가세요', 'act': 'play'}, now);
        await pumpAt(
            t,
            scale,
            Scaffold(
                body: SizedBox(
                    width: 360,
                    child: HapticScoreView(
                        timeline: tl,
                        reducedMotion: true,
                        clock: () => now))));
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      });
    });
  }

  group('T209 디버그 상자', () {
    tearDown(EventLog.instance.clearForTest);

    for (final on in [false, true]) {
      testWidgets('개발용 기록 ${on ? '켜짐 -> 상자 있음' : '꺼짐 -> 상자 없음'}',
          (t) async {
        EventLog.instance.setEnabled(on);
        final answer = Completer<Map<int, int>>();
        permissionAnswer(() => answer.future); // 준비 중 화면에 머문다
        await pumpAt(t, 1.0, const CameraScreen());
        expect(find.textContaining('보정 모델 준비 중'),
            on ? findsOneWidget : findsNothing);
        expect(find.textContaining('빌드 '), on ? findsOneWidget : findsNothing);
        await t.pumpWidget(const SizedBox());
        answer.complete(<int, int>{1: 0});
        await t.pump();
      });
    }
  });

  group('T209 대비 보강', () {
    test('정상 화살표는 검정 외곽선을 먼저 그린다(평면·지면 모두)', () {
      for (final angle in [null, 0.0]) {
        final c = _ColorCanvas();
        StateFieldPainter(
                state: 'front',
                color: const Color(0xFFA8CDE8),
                stripeAngleDegrees: angle)
            .paint(c, const Size(360, 600));
        expect(c.colors, isNotEmpty);
        expect(c.colors.first, Colors.black, reason: 'angle=$angle');
        expect(c.colors, contains(isNot(Colors.black)));
        // 지면 화살표: 외곽선 1 + 몸통 14조각 + 머리 1. 평면: 외곽선 3 + 선 3.
        expect(c.colors.length, angle == null ? 6 : 16);
      }
    });

    test('꺼진 스위치 손잡이·테두리는 white70, 켜짐·비활성은 기본값', () {
      final sw = lowVisionTheme().switchTheme;
      expect(sw.thumbColor!.resolve({}), Colors.white70);
      expect(sw.trackOutlineColor!.resolve({}), Colors.white70);
      expect(sw.thumbColor!.resolve({WidgetState.selected}), isNull);
      expect(sw.thumbColor!.resolve({WidgetState.disabled}), isNull);
    });
  });

  group('T209 화면 읽기', () {
    testWidgets('설정 슬라이더는 기능명과 값을 함께 읽는다', (t) async {
      final h = t.ensureSemantics();
      await pumpAt(
          t,
          1.0,
          SettingsScreen(
            feedback: FeedbackService(),
            language: AppLanguage.ko,
            onLanguageChanged: (_) {},
            torchEnabled: false,
            onTorchChanged: (_) async {},
            powerSaveMode: true,
            onPowerSaveModeChanged: (_) {},
          ));
      final rate = t.getSemantics(find.byType(Slider).at(0)).getSemanticsData();
      expect(rate.label, contains('TTS 속도'));
      expect(rate.value, '0.5');
      final vib = t.getSemantics(find.byType(Slider).at(1)).getSemanticsData();
      expect(vib.label, contains('진동 세기'));
      expect(vib.value, '500밀리초');
      h.dispose();
    });

    testWidgets('진동 모듈 연결 상태는 liveRegion으로 알린다', (t) async {
      final h = t.ensureSemantics();
      final state = ValueNotifier(VibLinkState.searching);
      await pumpAt(
          t,
          1.0,
          SettingsScreen(
            feedback: FeedbackService(),
            language: AppLanguage.ko,
            onLanguageChanged: (_) {},
            torchEnabled: false,
            onTorchChanged: (_) async {},
            powerSaveMode: true,
            onPowerSaveModeChanged: (_) {},
            vibModuleEnabled: true,
            onVibModuleChanged: (_) {},
            vibModuleState: state,
          ));
      final ko = AppStrings.of(AppLanguage.ko);
      await t.scrollUntilVisible(find.text(ko.vibModuleStateSearching), 300,
          scrollable: find.byType(Scrollable).first);
      state.value = VibLinkState.connected;
      await t.pump();
      final node = t.getSemantics(find.text(ko.vibModuleStateConnected));
      expect(node.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
      h.dispose();
    });
  });
}

RouteGeometry _geo() {
  const lat0 = 37.0, lon0 = 127.0;
  final dLat = 100 / 110540;
  final dLon = 50 / (111320 * math.cos(lat0 * math.pi / 180));
  return RouteGeometry.fromTmap({
    'features': [
      {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [lon0, lat0],
            [lon0, lat0 + dLat],
            [lon0 - dLon, lat0 + dLat],
          ]
        },
        'properties': {},
      },
    ]
  });
}

class _ColorCanvas implements Canvas {
  final colors = <Color>[];
  @override
  void drawPath(Path path, Paint paint) => colors.add(paint.color);
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => colors.add(paint.color);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
