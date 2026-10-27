package io.github.ssong2332.walkguide

import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // T139: 이탈에서 직진으로 돌아올 때의 '딩'(feedback_service.dart playRecoverChime).
    // 새 패키지·음원 없이 안드로이드 기본 신호음을 쓴다. 처음 쓸 때 만들고 재사용한다.
    private var toneGenerator: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHIME_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "play") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val tg = toneGenerator
                        ?: ToneGenerator(AudioManager.STREAM_MUSIC, CHIME_VOLUME)
                            .also { toneGenerator = it }
                    if (tg.startTone(ToneGenerator.TONE_PROP_ACK, CHIME_MS)) {
                        result.success(null)
                    } else {
                        result.error("start_failed", "startTone returned false", null)
                    }
                } catch (e: RuntimeException) {
                    // ToneGenerator를 만들 수 없음(오디오 자원 부족 등) — 소리 없이 넘어간다.
                    toneGenerator?.release()
                    toneGenerator = null
                    result.error("tone_unavailable", e.message, null)
                }
            }
    }

    override fun onDestroy() {
        toneGenerator?.release()
        toneGenerator = null
        super.onDestroy()
    }

    companion object {
        private const val CHIME_CHANNEL = "io.github.ssong2332.walkguide/chime"

        // TTS(flutter_tts 기본)와 같은 미디어 스트림 — 음성 안내와 같은 볼륨으로 들리고,
        // 벨소리 무음·진동 모드에는 꺼지지 않는다(미디어 볼륨 0이면 안 들림).
        private const val CHIME_VOLUME = 100

        // TONE_PROP_ACK = 높은 음 짧게 2번('확인' 신호음). 300ms면 두 번 다 울린다(추정).
        private const val CHIME_MS = 300
    }
}
