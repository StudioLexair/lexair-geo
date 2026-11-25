import 'package:flutter/foundation.dart';

import '../../core/net/api_client.dart';
import '../../core/net/api_exception.dart';
import 'user_profile.dart';

enum AuthStatus { signedOut, signingIn, mustChangePassword, signedIn }

/// Sesión del usuario. El token vive solo en memoria: cerrar la aplicación
/// equivale a cerrar sesión (equipos compartidos en la red interna).
class AuthController extends ChangeNotifier {
  AuthController(this._api, {required this.clientKind}) {
    _api.onUnauthorized = _onUnauthorized;
  }

  final ApiClient _api;
  final String clientKind;
  AuthStatus status = AuthStatus.signedOut;
  UserProfile? user;
  String? error;

  Future<bool> login(String username, String password) async {
    status = AuthStatus.signingIn;
    error = null;
    notifyListeners();
    try {
      final res = await _api.postJson('/auth/login', {
        'username': username.trim().toLowerCase(),
        'password': password,
        'clientKind': clientKind,
      });
      _api.token = res['token'] as String;
      await refreshProfile();
      return true;
    } on ApiException catch (e) {
      _api.token = null;
      status = AuthStatus.signedOut;
      error = e.isOffline ? e.message : e.userMessage;
      notifyListeners();
      return false;
    }
  }

  Future<void> refreshProfile() async {
    final me = UserProfile.fromJson(await _api.getJson('/auth/me'));
    user = me;
    status = me.mustChangePassword ? AuthStatus.mustChangePassword : AuthStatus.signedIn;
    notifyListeners();
  }

  /// Devuelve null si todo fue bien o el mensaje de error.
  Future<String?> changePassword(String current, String next) async {
    try {
      await _api.postJson('/auth/change-password', {
        'currentPassword': current,
        'newPassword': next,
      });
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.userMessage;
    }
  }

  Future<void> logout() async {
    try {
      await _api.postJson('/auth/logout');
    } on ApiException {
      // Si el servidor no responde, la sesión se descarta igualmente en local.
    }
    _clear();
  }

  void _onUnauthorized() {
    if (status == AuthStatus.signedIn || status == AuthStatus.mustChangePassword) {
      _clear(message: 'La sesión caducó o fue revocada. Inicie sesión de nuevo.');
    }
  }

  void _clear({String? message}) {
    _api.token = null;
    user = null;
    status = AuthStatus.signedOut;
    error = message;
    notifyListeners();
  }
}
