import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';

/// Carga asíncrona con estados de espera/error y recarga manual.
class AsyncSection<T> extends StatefulWidget {
  const AsyncSection({super.key, required this.load, required this.builder, this.title, this.actions});
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, VoidCallback reload) builder;
  final String? title;
  final List<Widget> Function(VoidCallback reload)? actions;

  @override
  State<AsyncSection<T>> createState() => _AsyncSectionState<T>();
}

class _AsyncSectionState<T> extends State<AsyncSection<T>> {
  late Future<T> _future = widget.load();

  void _reload() => setState(() => _future = widget.load());

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              Expanded(child: Text(widget.title!, style: Theme.of(context).textTheme.titleLarge)),
              ...?widget.actions?.call(_reload),
              IconButton(tooltip: 'Recargar', icon: const Icon(Icons.refresh), onPressed: _reload),
            ]),
          ),
        Expanded(
          child: FutureBuilder<T>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                final e = snap.error;
                return Center(child: Text(e is ApiException ? e.userMessage : 'Error: $e',
                    style: const TextStyle(color: LexairColors.danger)));
              }
              return widget.builder(context, snap.data as T, _reload);
            },
          ),
        ),
      ],
    );
  }
}

/// Tabla clave/valor para objetos JSON del servidor (anidados con sangría).
class KeyValueTable extends StatelessWidget {
  const KeyValueTable({super.key, required this.data, this.labels = const {}});
  final Map<String, dynamic> data;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void walk(Map<String, dynamic> m, int depth) {
      for (final e in m.entries) {
        final v = e.value;
        final label = labels[e.key] ?? e.key;
        if (v is Map<String, dynamic>) {
          rows.add(_row(label, '', depth, bold: true));
          walk(v, depth + 1);
        } else {
          rows.add(_row(label, v is List ? v.join(', ') : '${v ?? '—'}', depth));
        }
      }
    }
    walk(data, 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _row(String k, String v, int depth, {bool bold = false}) => Padding(
    padding: EdgeInsets.fromLTRB(16.0 * depth, 3, 0, 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 240,
        child: Text(k, style: TextStyle(color: LexairColors.muted, fontWeight: bold ? FontWeight.w600 : null)),
      ),
      Expanded(child: SelectableText(v)),
    ]),
  );
}

/// Muestra el resultado de una acción con un SnackBar; devuelve si tuvo éxito.
Future<bool> runAction(BuildContext context, Future<void> Function() f, String ok) async {
  final m = ScaffoldMessenger.of(context);
  try {
    await f();
    m.showSnackBar(SnackBar(content: Text(ok)));
    return true;
  } on ApiException catch (e) {
    m.showSnackBar(SnackBar(content: Text(e.userMessage), backgroundColor: LexairColors.danger));
    return false;
  }
}

/// Diálogo para mostrar UNA vez una contraseña temporal generada.
Future<void> showTemporaryPassword(BuildContext context, String username, String password) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Contraseña temporal'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Entregue esta contraseña a «$username» por un canal seguro. '
              'No se volverá a mostrar y deberá cambiarse en el primer acceso.'),
          const SizedBox(height: 12),
          SelectableText(password, style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 18)),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Entendido'))],
      ),
    );

/// Formato de fecha ISO del servidor a hora local legible.
String fmtDate(Object? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse('$iso')?.toLocal();
  if (d == null) return '$iso';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

void unawaitedFuture(Future<void> f) => unawaited(f);
