import 'package:flutter/material.dart';

import '../localization/app_strings.dart';
import '../services/feedback_service.dart';
import '../services/walk_info.dart';

/// T198: "보행 정보" 칸(T206부터 [DestinationScreen] 안) — 켜기/끄기, 목적지 경로 안내.
/// T205: 목적지는 검색 결과 여러 곳(이름 + 거리)을 보여 주고 읽어서 고르게 한다.
///
/// 기본 꺼짐(위치·네트워크를 쓰므로 사용자가 켤 때만). 앱을 다시 켜면 꺼진다
/// (설정 화면의 다른 값처럼 저장하지 않음).
class WalkInfoSection extends StatefulWidget {
  const WalkInfoSection(
      {super.key, required this.feedback, required this.language});
  final FeedbackService feedback;
  final AppLanguage language;

  @override
  State<WalkInfoSection> createState() => _WalkInfoSectionState();
}

class _WalkInfoSectionState extends State<WalkInfoSection> {
  final _dest = TextEditingController();
  String? _status;
  bool _busy = false;
  final _flight = SingleFlight();
  List<Place> _places = const [];

  WalkInfoService get _svc => WalkInfoService.instance;
  bool get _ko => widget.language == AppLanguage.ko;

  String _reason(String why) => switch (why) {
        'no_key' => _ko ? '이 빌드에는 API 키가 없습니다' : 'No API key in this build',
        'location_off' => _ko ? '휴대폰 위치가 꺼져 있습니다' : 'Location is off',
        'permission' => _ko ? '위치 권한이 없습니다' : 'Location permission denied',
        'no_position' => _ko ? '아직 위치를 받지 못했습니다' : 'No position yet',
        'no_place' => _ko ? '목적지를 찾지 못했습니다' : 'Destination not found',
        'not_running' => _ko ? '보행 정보를 먼저 켜세요' : 'Turn on walk info first',
        _ => _ko ? '연결에 실패했습니다' : 'Network error',
      };

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    String? why;
    if (on) {
      why = await _svc.start(widget.feedback);
    } else {
      await _svc.stop();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = why == null ? null : _reason(why);
    });
    if (why != null) await widget.feedback.announceError(_status!);
  }

  /// T205: 검색 -> 목록 표시 + 읽기. 키보드 '이동'과 버튼이 겹쳐도 [_flight]로 한 번만.
  Future<void> _search() async {
    final text = _dest.text.trim();
    if (text.isEmpty) return;
    await _flight.run(() async {
      setState(() => _places = const []);
      final r = await _svc.searchPlaces(text);
      if (!mounted) return;
      final msg = r.why != null
          ? _reason(r.why!)
          : placesSpeech(r.places, widget.language);
      setState(() {
        _places = r.places;
        _status = r.why == null ? null : msg;
      });
      // T207 ①: 사용자가 요청한 목록 낭독 — 무음 예산 밖.
      await widget.feedback.announceRoute(msg, userRequested: true);
    });
    if (mounted) setState(() {});
  }

  Future<void> _choose(Place p) async {
    await _flight.run(() async {
      setState(() {});
      final why = await _svc.startRouteTo(p);
      if (!mounted) return;
      final geo = _svc.nav?.geo;
      final m = geo == null ? 0 : (geo.length / 10).round() * 10;
      final msg = why != null
          ? _reason(why)
          : _ko
              ? '${_svc.destName}까지 $m미터 안내합니다'
              : 'Guiding to ${_svc.destName}, $m meters';
      setState(() {
        if (why == null) _places = const [];
        _status = msg;
      });
      await widget.feedback.announceRoute(msg);
    });
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _dest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const note = TextStyle(color: Colors.white70, fontSize: 16);
    final on = _svc.running;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            value: on,
            onChanged: _busy ? null : _toggle,
            contentPadding: EdgeInsets.zero,
            title: Text(_ko ? '보행 정보 (위치 사용)' : 'Walk info (uses location)',
                style: const TextStyle(color: Colors.white)),
            subtitle: Text(
                _ko
                    ? '앞에 횡단보도가 보이면 신호등·음향신호기 정보를 말합니다. 공공데이터가 있는 지역에서만 됩니다.'
                    : 'Says signal info when a crosswalk is ahead, where public data exists.',
                style: note),
          ),
          if (on) ...[
            TextField(
              controller: _dest,
              enabled: !_busy,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: _ko ? '목적지' : 'Destination',
                labelStyle: const TextStyle(color: Colors.white70),
              ),
            ),
            // T209: 두 버튼 사이 8dp, 각 48dp 이상. 글자가 커지면 다음 줄로.
            Wrap(spacing: 8, runSpacing: 8, children: [
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy || _flight.busy ? null : _search,
                child: Text(_ko ? '목적지 찾기' : 'Find destination'),
              ),
              if (_svc.nav != null)
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => setState(_svc.stopRoute),
                  child: Text(_ko ? '경로 안내 끝' : 'Stop route'),
                ),
            ]),
            PlaceList(
                places: _places,
                language: widget.language,
                enabled: !_flight.busy,
                onTap: _choose),
          ],
          if (_status != null)
            Text(_status!,
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
        ],
      ),
    );
  }
}

/// T205: 목적지 검색 결과 목록 — "1. 이름 … 350미터". 20km 넘는 곳은 거리를 흐리게.
class PlaceList extends StatelessWidget {
  const PlaceList(
      {super.key,
      required this.places,
      required this.language,
      required this.enabled,
      required this.onTap});
  final List<Place> places;
  final AppLanguage language;
  final bool enabled;
  final ValueChanged<Place> onTap;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (var i = 0; i < places.length; i++)
        // T206: 화면 읽기로 "1번, 이름, 거리" 한 덩어리 + 버튼으로 읽힌다
        // (TalkBack이 "두 번 탭하여 활성화"를 붙인다).
        Semantics(
          button: true,
          enabled: enabled,
          label: language == AppLanguage.ko
              ? '${i + 1}번, ${places[i].name}, ${placeDistance(places[i].distM, language)}'
              : '${i + 1}, ${places[i].name}, ${placeDistance(places[i].distM, language)}',
          excludeSemantics: true,
          onTap: enabled ? () => onTap(places[i]) : null,
          // T209: 줄 사이 8dp, 줄 높이 48dp 이상(dense 해제).
          child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ListTile(
          minTileHeight: 48,
          contentPadding: EdgeInsets.zero,
          enabled: enabled,
          onTap: () => onTap(places[i]),
          title: Text('${i + 1}. ${places[i].name}',
              style: const TextStyle(color: Colors.white, fontSize: 18)),
          // T209: 먼 곳(20km 넘음)은 white70, 가까운 곳은 흰색 — 둘 다 7:1 이상.
          trailing: Text(placeDistance(places[i].distM, language),
              style: TextStyle(
                  fontSize: 16,
                  color: places[i].distM > kPlaceFarM
                      ? Colors.white70
                      : Colors.white)),
        ))),
    ]);
  }
}

/// T206: 카메라 화면의 목적지 버튼으로 여는 화면 — 보행 정보 켜기·목적지 검색·안내 끝.
/// 설정 화면과 달리 인식을 멈추지 않는다(T190의 멈춤은 설정 화면에만).
class DestinationScreen extends StatelessWidget {
  const DestinationScreen(
      {super.key, required this.feedback, required this.language});
  final FeedbackService feedback;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(language == AppLanguage.ko ? '목적지 안내' : 'Destination'),
      ),
      body: ListView(children: [
        WalkInfoSection(feedback: feedback, language: language),
      ]),
    );
  }
}
