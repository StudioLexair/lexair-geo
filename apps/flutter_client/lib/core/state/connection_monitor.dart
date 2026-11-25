import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/api_client.dart';
import '../net/api_exception.dart';

enum ServiceState { unknown, ok, degraded, down }

/// Sondea `/health` periódicamente. Alimenta el indicador de conexión y
/// los mensajes de «servidor desconectado».
class ConnectionMonitor extends ChangeNotifier {
  ConnectionMonitor(this._api, {Duration interval = const Duration(seconds: 15)})
    : _interval = interval; // ignore: prefer_initializing_formals

  final ApiClient _api;
  final Duration _interval;
  Timer? _timer;

  ServiceState server = ServiceState.unknown;
  ServiceState database = ServiceState.unknown;
  ServiceState tiles = ServiceState.unknown;
  ServiceState search = ServiceState.unknown;
  String? serverVersion;
  String? mapDataVersion;
  String? mapSourceTimestamp;
  bool mapIsSynthetic = false;
  DateTime? lastCheck;
  String? lastError;

  bool get isOnline => server == ServiceState.ok || server == ServiceState.degraded;

  void start() {
    _timer?.cancel();
    unawaited(check());
    _timer = Timer.periodic(_interval, (_) => unawaited(check()));
  }

  ServiceState _parse(Object? v) => v == 'ok' ? ServiceState.ok : ServiceState.down;

  Future<void> check() async {
    try {
      final h = await _api.getJson('/health');
      server = h['status'] == 'ok' ? ServiceState.ok : ServiceState.degraded;
      final s = (h['services'] as Map<String, dynamic>?) ?? const {};
      database = _parse(s['database']);
      tiles = _parse(s['tiles']);
      search = _parse(s['search']);
      serverVersion = h['version'] as String?;
      final m = h['mapData'] as Map<String, dynamic>?;
      mapDataVersion = m?['version'] as String?;
      mapSourceTimestamp = m?['sourceTimestamp'] as String?;
      mapIsSynthetic = m?['isSynthetic'] == true;
      lastError = null;
    } on ApiException catch (e) {
      // 503 = API vivo pero base de datos caída.
      server = e.statusCode == 503 ? ServiceState.degraded : ServiceState.down;
      database = ServiceState.down;
      search = ServiceState.down;
      if (e.isOffline) tiles = ServiceState.down;
      lastError = e.message;
    }
    lastCheck = DateTime.now();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
