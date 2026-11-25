import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_controller.dart';
import '../admin_repository.dart';
import '../admin_widgets.dart';

/// 4. Roles y permisos: matriz editable solo por el superadministrador.
/// Guardar invalida todas las sesiones en el servidor.
class RolesSection extends StatefulWidget {
  const RolesSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  State<RolesSection> createState() => _RolesSectionState();
}

class _RolesSectionState extends State<RolesSection> {
  final Map<String, Set<String>> _edits = {};

  @override
  Widget build(BuildContext context) {
    final isSuper = context.read<AuthController>().user?.role == 'superadmin';
    return AsyncSection<Json>(
      title: 'Roles y permisos',
      load: widget.repo.roles,
      builder: (context, data, reload) {
        final roles = itemsOf(data, 'roles');
        final perms = itemsOf(data, 'permissions');
        Set<String> current(Json r) =>
            _edits[r['code']] ?? ((r['permissions'] as List<dynamic>).cast<String>().toSet());
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isSuper
                ? 'Marque los permisos y pulse Guardar en la columna del rol. Las sesiones activas se cerrarán.'
                : 'Solo el superadministrador puede modificar los permisos.'),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  const DataColumn(label: Text('Permiso')),
                  for (final r in roles)
                    DataColumn(label: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text('${r['name']}'),
                      if (isSuper && r['code'] != 'superadmin' && _edits.containsKey(r['code']))
                        TextButton(
                          onPressed: () async {
                            final code = r['code'] as String;
                            if (await runAction(context,
                                () => widget.repo.setRolePermissions(code, current(r).toList()..sort()),
                                'Permisos guardados; sesiones invalidadas')) {
                              _edits.remove(code);
                              reload();
                            }
                          },
                          child: const Text('Guardar'),
                        ),
                    ])),
                ],
                rows: [
                  for (final p in perms)
                    DataRow(cells: [
                      DataCell(Tooltip(message: '${p['code']}', child: Text('${p['description']}'))),
                      for (final r in roles)
                        DataCell(Checkbox(
                          value: current(r).contains(p['code']),
                          onChanged: !isSuper || r['code'] == 'superadmin'
                              ? null
                              : (v) => setState(() {
                                  final s = {...current(r)};
                                  v == true ? s.add(p['code'] as String) : s.remove(p['code']);
                                  _edits[r['code'] as String] = s;
                                }),
                        )),
                    ]),
                ],
              ),
            ),
          ]),
        );
      },
    );
  }
}
