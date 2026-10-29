import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'vib_module.dart';

/// T153: `universal_ble`로 만든 [VibModuleTransport]. 플러그인을 직접 부르므로
/// 단위 테스트에서는 쓰지 않는다(규약·연결 관리는 `vib_module.dart`에서 시험).
class UniversalBleVibTransport implements VibModuleTransport {
  /// 광고를 찾는 최대 시간(추정 값).
  static const scanTimeout = Duration(seconds: 10);
  static const connectTimeout = Duration(seconds: 10);

  String? _deviceId;
  StreamSubscription<bool>? _connSub;
  StreamSubscription<Uint8List>? _valueSub;
  final _notifications = StreamController<Uint8List>.broadcast();
  final _connection = StreamController<bool>.broadcast();

  @override
  Stream<Uint8List> get notifications => _notifications.stream;

  @override
  Stream<bool> get connection => _connection.stream;

  @override
  Future<void> connect() async {
    try {
      // Android 12 이상: BLUETOOTH_SCAN·BLUETOOTH_CONNECT. 위치 권한은 묻지 않는다
      // (매니페스트의 BLUETOOTH_SCAN = neverForLocation).
      await UniversalBle.requestPermissions(withAndroidFineLocation: false);
    } catch (e) {
      throw VibPermissionDenied(e.toString());
    }
    final deviceId = await _scan();
    await UniversalBle.connect(deviceId, timeout: connectTimeout);
    _deviceId = deviceId;
    await _connSub?.cancel();
    _connSub = UniversalBle.connectionStream(deviceId).listen(_connection.add);
    await UniversalBle.discoverServices(deviceId);
    await _valueSub?.cancel();
    _valueSub = UniversalBle.characteristicValueStream(
            deviceId, VibModuleProtocol.statusUuid)
        .listen(_notifications.add);
    await UniversalBle.subscribeNotifications(
        deviceId, VibModuleProtocol.serviceUuid, VibModuleProtocol.statusUuid);
  }

  Future<String> _scan() async {
    final found = Completer<String>();
    final sub = UniversalBle.scanStream.listen((d) {
      if (!found.isCompleted) found.complete(d.deviceId);
    });
    try {
      await UniversalBle.startScan(
        scanFilter:
            ScanFilter(withServices: [VibModuleProtocol.serviceUuid]),
        platformConfig: PlatformConfig(
          android: AndroidOptions(
            scanMode: AndroidScanMode.lowLatency,
            requestLocationPermission: false,
          ),
        ),
      );
      return await found.future.timeout(scanTimeout);
    } finally {
      await sub.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    final id = _deviceId;
    if (id == null) throw StateError('not connected');
    await UniversalBle.write(
        id, VibModuleProtocol.serviceUuid, VibModuleProtocol.cmdUuid, data,
        withoutResponse: true);
  }

  @override
  Future<void> disconnect() async {
    final id = _deviceId;
    _deviceId = null;
    await _valueSub?.cancel();
    _valueSub = null;
    await _connSub?.cancel();
    _connSub = null;
    if (id != null) await UniversalBle.disconnect(id);
  }
}
