import 'package:flutter_test/flutter_test.dart';
import 'package:lexair_geo/core/config/app_config.dart';
import 'package:lexair_geo/features/admin/admin_screen.dart';
import 'package:lexair_geo/features/auth/change_password_screen.dart';
import 'package:lexair_geo/features/auth/user_profile.dart';
import 'package:lexair_geo/features/geocoding/geocoding_repository.dart';
import 'package:lexair_geo/features/persons/person.dart';

import 'fakes.dart';

void main() {
  group('AppConfig', () {
    test('valida URLs de servidor y construye rutas', () {
      expect(AppConfig.isValidServerUrl('https://geo.internal'), isTrue);
      expect(AppConfig.isValidServerUrl('https://192.168.10.10:8443'), isTrue);
      expect(AppConfig.isValidServerUrl('ftp://geo.internal'), isFalse);
      expect(AppConfig.isValidServerUrl('geo.internal'), isFalse);
      final c = AppConfig.fromJson({'serverUrl': 'https://geo.internal/'});
      expect(c.apiBase, 'https://geo.internal/api/v1');
      expect(c.tilesBase, 'https://geo.internal/tiles');
    });

    test('rechaza config.json sin serverUrl válido', () {
      expect(() => AppConfig.fromJson({'serverUrl': 'nada'}), throwsFormatException);
    });
  });

  group('Person', () {
    test('sin permiso exacto no hay punto en el mapa', () {
      final p = Person.fromJson({
        'id': 'x', 'code': 'SYN-1', 'givenNames': 'Ana', 'familyNames': 'Ficticia', 'groups': ['A', 'B'],
        'location': {'precisionLevel': 'approximate', 'exact': false, 'lat': null, 'lon': null},
      });
      expect(p.location!.point, isNull);
      expect(p.groups, ['A', 'B']);
      expect(p.fullName, 'Ana Ficticia');
    });

    test('con permiso exacto expone coordenadas', () {
      final p = Person.fromJson({
        'id': 'x', 'code': 'SYN-1', 'givenNames': 'A', 'familyNames': 'B',
        'location': {'precisionLevel': 'high', 'exact': true, 'lat': 22.4, 'lon': -79.96},
      });
      expect(p.location!.point!.latitude, 22.4);
    });

    test('paginación', () {
      final r = PageResult.fromJson({'items': [], 'total': 120, 'page': 2, 'pageSize': 50},
          Person.fromJson);
      expect(r.hasMore, isTrue);
      final last = PageResult.fromJson({'items': [], 'total': 100, 'page': 2, 'pageSize': 50},
          Person.fromJson);
      expect(last.hasMore, isFalse);
    });
  });

  test('GeocodeResult conserva granularidad y nota de calle', () {
    final g = GeocodeResult.fromJson({
      'kind': 'street', 'label': 'Calle Ficticia', 'lat': 22.4, 'lon': -79.9, 'granularity': 'street',
      'suggestedPrecision': 'approximate', 'confidence': 0.6, 'source': 'x', 'isSynthetic': true,
      'note': 'La posición representa un tramo de calle',
    });
    expect(g.granularity, 'street');
    expect(g.note, contains('tramo'));
  });

  group('Panel de administración', () {
    test('tiene 22 secciones y un superadmin las ve todas', () {
      expect(adminSections.length, 22);
      final all = UserProfile.fromJson(meJson(role: 'superadmin', permissions: [
        'persons.read', 'users.manage', 'audit.read', 'imports.run', 'exports.run', 'settings.manage',
        'system.status', 'geocoding.manage', 'zones.write', 'passes.write', 'personnel.write',
      ]));
      expect(visibleSections(all).length, 22);
    });

    test('un consultor solo ve las secciones permitidas', () {
      final c = UserProfile.fromJson(meJson(role: 'consultant', permissions: ['persons.read', 'system.status']));
      final ids = visibleSections(c).map((s) => s.id).toSet();
      expect(ids, containsAll(['dashboard', 'status', 'groups', 'about']));
      expect(ids.intersection({'users', 'roles', 'audit', 'settings', 'import', 'export'}), isEmpty);
    });
  });

  test('política de contraseñas del cliente', () {
    expect(passwordPolicyError('corta'), isNotNull);
    expect(passwordPolicyError('solominusculaslarga'), isNotNull);
    expect(passwordPolicyError('Ficticia-Clave-2026'), isNull);
  });
}
