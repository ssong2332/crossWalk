/// T129: 시안 D "촉각 악보"의 자료. 화면 녹화만 보고도 "지금 무엇을 말하는
/// 중이고, 무엇이 대기 중이며, 무엇이 만료됐고, 언제 떨렸는지"가 읽히게 한다.
///
/// 판정·오디오·진동 정책은 바꾸지 않는다. [EventLog]에 남는 것과 **같은 사건**
/// (`EventLog.tap`)만 받아 시간축 자료로 모은다. 사건 이름·필드는 `docs/EventLog.md`.
///
/// | 사건 | 이 자료에서 |
/// |---|---|
/// | `say` act=play | 발화 막대 시작 (대기 목록에 같은 문장이 있으면 꺼냄) |
/// | `say` act=queue | 대기 목록에 넣음 |
/// | `say` act=drop | '버림' 표시 |
/// | `say.defer` | 대기 목록에 넣음(보류) |
/// | `say.end` | 같은 문장의 열린 발화 막대를 닫음(결과 res) |
/// | `say.ttl` | 대기 목록에서 빼고 '만료' 표시 |
/// | `say.cancel` | 대기 목록에서 빼고 '취소' 표시 |
/// | `vib` ok=true | 패턴의 켜짐 구간마다 진동 막대 |
/// | `state` | 상태 경계 표시 |
/// | `pos` | 위치(smooth, -2~+2) 점 |
library;

class ScoreSpeech {
  ScoreSpeech(this.text, this.start, {this.rate});

  final String text;
  final DateTime start;
  final double? rate;
  DateTime? end;

  /// `say.end`의 res(done·cut·superseded·timeout·error). 열려 있으면 null.
  /// T132: cut = 더 새 발화에 끊김.
  String? result;

  bool get open => end == null;
}

class ScorePending {
  ScorePending(this.text, this.since, {required this.deferred});

  final String text;
  final DateTime since;

  /// `say.defer`(멈춤 블록 보류)에서 왔는가.
  final bool deferred;
}

enum ScoreMarkKind { ttl, cancel, drop, state }

class ScoreMark {
  const ScoreMark(this.kind, this.text, this.at);

  final ScoreMarkKind kind;
  final String text;
  final DateTime at;
}

class ScoreBuzz {
  const ScoreBuzz(this.start, this.end);

  final DateTime start;
  final DateTime end;
}

class ScorePos {
  const ScorePos(this.at, this.value);

  final DateTime at;
  final double value;
}

class ScoreTimeline {
  ScoreTimeline({this.keep = const Duration(seconds: 20)});

  /// 이보다 오래된 막대·표시는 버린다(화면에 그리는 창보다 넉넉히).
  final Duration keep;

  /// 대기 목록은 정책이 만료를 알려 주지만, 기록이 꺼졌다 켜지는 등으로 끝을
  /// 못 받으면 영원히 남는다 — 그래서 이 시간이 지나면 버린다.
  static const pendingLimit = Duration(seconds: 30);

  final List<ScoreSpeech> speech = [];
  final List<ScorePending> pending = [];
  final List<ScoreMark> marks = [];
  final List<ScoreBuzz> buzzes = [];
  final List<ScorePos> positions = [];

  /// 바뀔 때마다 1 오른다(그리기 판단용).
  int revision = 0;

  /// 지금 말하는 중인 문장(가장 최근에 시작해 아직 끝나지 않은 발화).
  ScoreSpeech? get speaking {
    for (var i = speech.length - 1; i >= 0; i--) {
      if (speech[i].open) return speech[i];
    }
    return null;
  }

  void clear() {
    speech.clear();
    pending.clear();
    marks.clear();
    buzzes.clear();
    positions.clear();
    revision++;
  }

  void add(String event, Map<String, Object?> data, DateTime at) {
    final text = data['text'] is String ? data['text'] as String : '';
    switch (event) {
      case 'say':
        switch (data['act']) {
          case 'play':
            _takePending(text);
            final rate = data['rate'];
            speech.add(ScoreSpeech(text, at,
                rate: rate is num ? rate.toDouble() : null));
          case 'queue':
            _takePending(text);
            pending.add(ScorePending(text, at, deferred: false));
          case 'drop':
            marks.add(ScoreMark(ScoreMarkKind.drop, text, at));
          default:
            return;
        }
      case 'say.defer':
        _takePending(text);
        pending.add(ScorePending(text, at, deferred: true));
      case 'say.end':
        for (var i = speech.length - 1; i >= 0; i--) {
          final s = speech[i];
          if (s.open && s.text == text) {
            s.end = at;
            final res = data['res'];
            s.result = res is String ? res : null;
            break;
          }
        }
      case 'say.ttl':
        _takePending(text);
        marks.add(ScoreMark(ScoreMarkKind.ttl, text, at));
      case 'say.cancel':
        _takePending(text);
        marks.add(ScoreMark(ScoreMarkKind.cancel, text, at));
      case 'vib':
        if (data['ok'] != true) return;
        final pat = data['pat'];
        if (pat is! List) return;
        var t = 0;
        for (var i = 0; i < pat.length; i++) {
          final d = pat[i];
          if (d is! num) return;
          final ms = d.toInt();
          if (i.isOdd && ms > 0) {
            buzzes.add(ScoreBuzz(at.add(Duration(milliseconds: t)),
                at.add(Duration(milliseconds: t + ms))));
          }
          t += ms;
        }
      case 'state':
        final to = data['to'];
        marks.add(ScoreMark(ScoreMarkKind.state, to is String ? to : '', at));
      case 'pos':
        final v = data['smooth'];
        if (v is num) positions.add(ScorePos(at, v.toDouble()));
      default:
        return;
    }
    _prune(at);
    revision++;
  }

  void _takePending(String text) =>
      pending.removeWhere((p) => p.text == text);

  void _prune(DateTime now) {
    final cut = now.subtract(keep);
    // 열린 발화는 남긴다 — 아직 말하는 중이다.
    speech.removeWhere((s) => !s.open && s.end!.isBefore(cut));
    marks.removeWhere((m) => m.at.isBefore(cut));
    buzzes.removeWhere((b) => b.end.isBefore(cut));
    positions.removeWhere((p) => p.at.isBefore(cut));
    final stale = now.subtract(pendingLimit);
    pending.removeWhere((p) => p.since.isBefore(stale));
    // 끝(say.end)을 못 받은 발화도 같은 이유로 버린다.
    speech.removeWhere((s) => s.open && s.start.isBefore(stale));
  }
}
