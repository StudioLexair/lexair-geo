import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/labels.dart';
import '../auth/auth_controller.dart';
import '../map/workspace_controller.dart';
import '../../core/config/terminologia.dart';
import 'person.dart';
import 'person_detail_panel.dart';
import 'person_form_dialog.dart';

/// Búsqueda paginada de personas (nombre, apellidos, código, teléfono) con
/// filtro de grupo. Al elegir un resultado se abre el detalle.
class PersonSearchPanel extends StatefulWidget {
  const PersonSearchPanel({super.key});

  @override
  State<PersonSearchPanel> createState() => _PersonSearchPanelState();
}

class _PersonSearchPanelState extends State<PersonSearchPanel> {
  final _q = TextEditingController();
  Timer? _debounce;
  PageResult<Person>? _result;
  String? _error;
  bool _loading = false;
  String _status = 'active';
  String? _onPass; // null: todos · 'true': en pase · 'false': sin pase

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _run({int page = 1}) async {
    final ws = context.read<WorkspaceController>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ws.persons.search(
        q: _q.text.trim().isEmpty ? null : _q.text.trim(),
        groups: ws.groupFilter == 'all' ? null : ws.groupFilter,
        status: _status,
        onPass: _onPass,
        page: page,
      );
      if (mounted) setState(() => _result = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _run);
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final user = context.watch<AuthController>().user;
    if (ws.selected != null) return const PersonDetailPanel();
    final r = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            key: const Key('person-search'),
            controller: _q,
            onChanged: _onChanged,
            onSubmitted: (_) => _run(),
            decoration: const InputDecoration(
              hintText: 'Nombre, apellidos, código o teléfono',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            DropdownButton<String>(
              value: _status,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'active', child: Text('Activas')),
                DropdownMenuItem(value: 'inactive', child: Text('Inactivas')),
                DropdownMenuItem(value: 'all', child: Text('Todas')),
              ],
              onChanged: (v) {
                setState(() => _status = v ?? 'active');
                unawaited(_run());
              },
            ),
            DropdownButton<String>(
              value: _onPass,
              underline: const SizedBox.shrink(),
              hint: Text(T.paseSingular),
              items: [
                const DropdownMenuItem(value: null, child: Text('Todos')),
                DropdownMenuItem(value: 'true', child: Text('En ${T.paseSingular.toLowerCase()}')),
                DropdownMenuItem(value: 'false', child: Text('Sin ${T.paseSingular.toLowerCase()}')),
              ],
              onChanged: (v) {
                setState(() => _onPass = v);
                unawaited(_run());
              },
            ),
            const Spacer(),
            if (user?.can('persons.write') ?? false)
              TextButton.icon(
                key: const Key('person-new'),
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Nueva'),
                onPressed: () async {
                  final p = await showPersonFormDialog(context, null);
                  if (p != null && context.mounted) await context.read<WorkspaceController>().select(p);
                },
              ),
          ]),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        if (r != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text('${r.totalIsCapped ? 'Más de ' : ''}${r.total} resultado(s)',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        Expanded(
          child: r == null || r.items.isEmpty
              ? Center(child: Text(_loading ? '' : 'Sin resultados', style: Theme.of(context).textTheme.bodySmall))
              : ListView.separated(
                  itemCount: r.items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _PersonTile(person: r.items[i]),
                ),
        ),
        if (r != null && (r.page > 1 || r.hasMore))
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
              tooltip: 'Anterior',
              icon: const Icon(Icons.chevron_left),
              onPressed: r.page > 1 ? () => _run(page: r.page - 1) : null,
            ),
            Text('Página ${r.page}'),
            IconButton(
              tooltip: 'Siguiente',
              icon: const Icon(Icons.chevron_right),
              onPressed: r.hasMore ? () => _run(page: r.page + 1) : null,
            ),
          ]),
      ],
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person});
  final Person person;

  @override
  Widget build(BuildContext context) {
    final loc = person.location;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: Labels.groupColor(person.groups),
        child: Text(person.groups.join(), style: const TextStyle(color: Colors.white, fontSize: 11)),
      ),
      title: Text(person.fullName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [person.code, loc?.municipality ?? (loc == null ? 'Sin ubicación' : null),
         if (!person.isActive) 'inactiva'].whereType<String>().join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: loc == null
          ? null
          : Icon(Icons.place, size: 16, color: Labels.precisionColor(loc.precisionLevel)),
      onTap: () => context.read<WorkspaceController>().select(person),
    );
  }
}
