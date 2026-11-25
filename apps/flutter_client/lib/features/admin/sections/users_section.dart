import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_controller.dart';
import '../admin_repository.dart';
import '../admin_widgets.dart';

/// 3. Usuarios: alta (contraseña temporal generada por el servidor),
/// cambio de rol, activación y restablecimiento de contraseña.
class UsersSection extends StatelessWidget {
  const UsersSection({super.key, required this.repo});
  final AdminRepository repo;

  static const roles = {
    'admin': 'Administrador', 'operator': 'Operador', 'consultant': 'Consultor', 'readonly': 'Solo lectura',
    'superadmin': 'Superadministrador',
  };

  @override
  Widget build(BuildContext context) {
    final me = context.read<AuthController>().user;
    return AsyncSection<List<Json>>(
      title: 'Usuarios',
      load: repo.users,
      actions: (reload) => [
        FilledButton.icon(
          key: const Key('user-new'),
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: const Text('Nuevo usuario'),
          onPressed: () async {
            if (await _createUser(context)) reload();
          },
        ),
      ],
      builder: (context, users, reload) => SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Usuario')), DataColumn(label: Text('Nombre')),
            DataColumn(label: Text('Rol')), DataColumn(label: Text('Estado')),
            DataColumn(label: Text('Último acceso')), DataColumn(label: Text('')),
          ],
          rows: [
            for (final u in users)
              DataRow(cells: [
                DataCell(Text('${u['username']}')),
                DataCell(Text('${u['displayName']}')),
                DataCell(u['id'] == me?.id
                    ? Text('${u['roleName']}')
                    : DropdownButton<String>(
                        value: u['role'] as String,
                        underline: const SizedBox.shrink(),
                        items: [for (final r in roles.entries) DropdownMenuItem(value: r.key, child: Text(r.value))],
                        onChanged: (v) async {
                          if (v != null && await runAction(context,
                              () => repo.updateUser(u['id'] as String, {'role': v}), 'Rol actualizado')) {
                            reload();
                          }
                        },
                      )),
                DataCell(Text([
                  u['isActive'] == true ? 'Activo' : 'Inactivo',
                  if (u['locked'] == true) 'bloqueado',
                  if (u['mustChangePassword'] == true) 'debe cambiar contraseña',
                ].join(' · '))),
                DataCell(Text(fmtDate(u['lastLoginAt']))),
                DataCell(u['id'] == me?.id
                    ? const Text('(usted)')
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: u['isActive'] == true ? 'Desactivar' : 'Activar',
                          icon: Icon(u['isActive'] == true ? Icons.block : Icons.check_circle_outline),
                          onPressed: () async {
                            if (await runAction(context, () => repo.updateUser(u['id'] as String,
                                {'isActive': u['isActive'] != true}), 'Usuario actualizado')) {
                              reload();
                            }
                          },
                        ),
                        IconButton(
                          tooltip: 'Restablecer contraseña',
                          icon: const Icon(Icons.key_outlined),
                          onPressed: () async {
                            Json? r;
                            final ok = await runAction(context, () async {
                              r = await repo.resetPassword(u['id'] as String);
                            }, 'Contraseña restablecida');
                            if (ok && context.mounted) {
                              await showTemporaryPassword(context, '${u['username']}', '${r!['temporaryPassword']}');
                            }
                            reload();
                          },
                        ),
                      ])),
              ]),
          ],
        ),
      ),
    );
  }

  Future<bool> _createUser(BuildContext context) async {
    final username = TextEditingController();
    final name = TextEditingController();
    var role = 'consultant';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Nuevo usuario'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: username, decoration: const InputDecoration(labelText: 'Usuario (a-z, 0-9, . _ -)')),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre visible')),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: [
                  for (final r in roles.entries.where((e) => e.key != 'superadmin'))
                    DropdownMenuItem(value: r.key, child: Text(r.value)),
                ],
                onChanged: (v) => setState(() => role = v ?? role),
              ),
              const SizedBox(height: 8),
              const Text('El servidor genera una contraseña temporal aleatoria.', style: TextStyle(fontSize: 12)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Crear')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return false;
    Json? created;
    final success = await runAction(context, () async {
      created = await repo.createUser({'username': username.text.trim(), 'displayName': name.text.trim(), 'role': role});
    }, 'Usuario creado');
    if (success && context.mounted && created?['temporaryPassword'] != null) {
      await showTemporaryPassword(context, username.text.trim(), '${created!['temporaryPassword']}');
    }
    username.dispose();
    name.dispose();
    return success;
  }
}
