import 'package:flutter/material.dart';

import '../localization/app_strings.dart';
import '../services/feedback_service.dart';
import '../services/walk_info.dart';

/// T198: 설정 화면의 "보행 정보" 칸 — 켜기/끄기, 목적지 경로 안내.
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

  Future<void> _startRoute() async {
    final text = _dest.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    final why = await _svc.startRoute(text);
    if (!mounted) return;
    final geo = _svc.nav?.geo;
    final m = geo == null ? 0 : (geo.length / 10).round() * 10;
    final msg = why != null
        ? _reason(why)
        : _ko
            ? '${_svc.destName}까지 $m미터 안내합니다'
            : 'Guiding to ${_svc.destName}, $m meters';
    setState(() {
      _busy = false;
      _status = msg;
    });
    await widget.feedback.announceRoute(msg);
  }

  @override
  void dispose() {
    _dest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const note = TextStyle(color: Colors.white38, fontSize: 12);
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
              onSubmitted: (_) => _startRoute(),
              decoration: InputDecoration(
                labelText: _ko ? '목적지' : 'Destination',
                labelStyle: const TextStyle(color: Colors.white70),
              ),
            ),
            Row(children: [
              TextButton(
                onPressed: _busy ? null : _startRoute,
                child: Text(_ko ? '경로 안내 시작' : 'Start route'),
              ),
              if (_svc.nav != null)
                TextButton(
                  onPressed: () => setState(_svc.stopRoute),
                  child: Text(_ko ? '경로 안내 끝' : 'Stop route'),
                ),
            ]),
          ],
          if (_status != null)
            Text(_status!, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}
