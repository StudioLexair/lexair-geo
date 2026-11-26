import 'dart:typed_data';

import '../../core/net/api_client.dart';

/// Caché en memoria de las fotografías de las personas. Una sola petición
/// por persona y sesión; se invalida al cambiar la foto.
class PhotoCache {
  PhotoCache._();
  static final PhotoCache I = PhotoCache._();

  ApiClient? _api;
  final Map<String, Uint8List?> _map = {};
  final Map<String, Future<Uint8List?>> _inflight = {};

  void bind(ApiClient api) {
    if (_api != api) {
      _api = api;
      _map.clear();
    }
  }

  bool hasPhoto(String id) => (_map[id] ?? const []).isNotEmpty;

  Future<Uint8List?> get(String id) {
    if (_map.containsKey(id)) return Future.value(_map[id]);
    final fut = _inflight.putIfAbsent(id, () async {
      Uint8List? bytes;
      try {
        bytes = await _api!.getBytes('/persons/$id/photo');
      } catch (_) {
        bytes = null; // sin foto o sin permiso: iniciales.
      }
      _map[id] = bytes;
      _quitarEnMarcha(id);
      return bytes;
    });
    return fut;
  }

  void _quitarEnMarcha(String id) {
    _inflight.remove(id);
  }

  void invalidate(String id, Uint8List? bytes) {
    _map[id] = bytes;
  }
}
