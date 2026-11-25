import 'dart:convert';

import 'package:flutter/material.dart';

import '../admin_repository.dart';
import '../admin_widgets.dart';

/// 15. Auditoría (solo lectura, paginada y filtrable).
class AuditSection extends StatefulWidget {
  const AuditSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  State<AuditSection> createState() => _AuditSectionState();
}

class _AuditSectionState extends State<AuditSection> {
  final _action = TextEditingController();
  final _actor = TextEditingController();
  int _page = 1;
  int _gen = 0;

  @override
  void dispose() {
    _action.dispose();
    _actor.dispose();
    super.dispose();
  }

  void _apply([int page = 1]) => setState(() {
    _page = page;
    _gen++;
  });

  @override
  Widget build(BuildContext context) {
    String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
        child: Row(children: [
          Text('Auditoría', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 24),
          SizedBox(width: 180, child: TextField(controller: _action, onSubmitted: (_) => _apply(),
              decoration: const InputDecoration(isDense: true, labelText: 'Acción (prefijo)'))),
          const SizedBox(width: 12),
          SizedBox(width: 160, child: TextField(controller: _actor, onSubmitted: (_) => _apply(),
              decoration: const InputDecoration(isDense: true, labelText: 'Usuario'))),
          IconButton(icon: const Icon(Icons.filter_alt_outlined), tooltip: 'Filtrar', onPressed: _apply),
        ]),
      ),
      Expanded(
        child: AsyncSection<Json>(
          key: ValueKey(_gen),
          load: () => widget.repo.audit({'action': opt(_action), 'actor': opt(_actor), 'page': _page, 'pageSize': 50}),
          builder: (context, d, _) {
            final items = itemsOf(d);
            final total = (d['total'] as num?)?.toInt() ?? 0;
            return Column(children: [
              Expanded(
                child: ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final a = items[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(a['success'] == false ? Icons.error_outline : Icons.check_circle_outline,
                          color: a['success'] == false ? Colors.red : Colors.green, size: 18),
                      title: Text('${a['action']}  ·  ${a['actor'] ?? 'sistema'}'),
                      subtitle: Text([
                        fmtDate(a['occurredAt']),
                        if (a['entityType'] != null) '${a['entityType']} ${a['entityId'] ?? ''}',
                        if (a['ip'] != null) 'IP ${a['ip']}',
                        if (a['details'] != null) jsonEncode(a['details']),
                      ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                    );
                  },
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: _page > 1 ? () => _apply(_page - 1) : null),
                Text('Página $_page · $total registro(s)${d['totalIsCapped'] == true ? '+' : ''}'),
                IconButton(icon: const Icon(Icons.chevron_right),
                    onPressed: _page * 50 < total ? () => _apply(_page + 1) : null),
              ]),
            ]);
          },
        ),
      ),
    ]);
  }
}
