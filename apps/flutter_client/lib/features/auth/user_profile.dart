class GroupInfo {
  const GroupInfo({required this.code, required this.name, required this.colorHex});
  final String code;
  final String name;
  final String colorHex;

  factory GroupInfo.fromJson(Map<String, dynamic> j) => GroupInfo(
    code: j['code'] as String,
    name: j['name'] as String,
    colorHex: (j['colorHex'] as String?) ?? '#1565C0',
  );
}

/// Perfil devuelto por `/auth/me`. Los permisos determinan qué controles
/// se muestran: no se ofrecen acciones que el servidor rechazaría.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.permissions,
    required this.groups,
    required this.mustChangePassword,
  });

  final String id;
  final String username;
  final String displayName;
  final String role;
  final Set<String> permissions;
  final List<GroupInfo> groups;
  final bool mustChangePassword;

  bool can(String permission) => permissions.contains(permission);

  bool get isAdminArea =>
      can('users.manage') || can('audit.read') || can('imports.run') ||
      can('settings.manage') || can('system.status');

  String get roleLabel => const {
    'superadmin': 'Superadministrador',
    'admin': 'Administrador',
    'operator': 'Operador',
    'consultant': 'Consultor',
    'readonly': 'Solo lectura',
  }[role] ?? role;

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
    id: j['id'] as String,
    username: j['username'] as String,
    displayName: j['displayName'] as String,
    role: j['role'] as String,
    permissions: ((j['permissions'] as List<dynamic>?) ?? const []).cast<String>().toSet(),
    groups: ((j['groups'] as List<dynamic>?) ?? const [])
        .map((g) => GroupInfo.fromJson(g as Map<String, dynamic>))
        .toList(),
    mustChangePassword: j['mustChangePassword'] == true,
  );
}
