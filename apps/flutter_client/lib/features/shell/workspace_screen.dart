import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../geocoding/address_search_panel.dart';
import '../map/map_view.dart';
import '../map/workspace_controller.dart';
import '../persons/person_search_panel.dart';

/// Espacio de trabajo GIS: panel de herramientas a la izquierda y mapa.
class WorkspaceScreen extends StatelessWidget {
  const WorkspaceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final user = context.watch<AuthController>().user;
    final wide = MediaQuery.sizeOf(context).width > 1100;
    return Row(children: [
      Container(
        width: wide ? 380 : 320,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(right: BorderSide(color: LexairColors.border)),
        ),
        child: Column(children: [
          SegmentedButton<ToolTab>(
            segments: const [
              ButtonSegment(value: ToolTab.persons, icon: Icon(Icons.people_outline), label: Text('Personas')),
              ButtonSegment(value: ToolTab.addresses, icon: Icon(Icons.signpost_outlined), label: Text('Direcciones')),
            ],
            selected: {ws.tab},
            onSelectionChanged: (s) => ws.setTab(s.first),
            showSelectedIcon: false,
          ),
          const Divider(height: 1),
          Expanded(
            child: (user?.can('persons.read') ?? false)
                ? IndexedStack(
                    index: ws.tab.index,
                    children: const [PersonSearchPanel(), AddressSearchPanel()],
                  )
                : const Center(child: Text('Su rol no permite consultar personas.')),
          ),
        ]),
      ),
      const Expanded(child: MapView()),
    ]);
  }
}
