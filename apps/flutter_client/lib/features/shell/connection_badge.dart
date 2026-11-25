import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/state/connection_monitor.dart';
import '../../core/theme/app_theme.dart';

/// Indicador del estado del servidor. Nunca muestra «conectado» sin una
/// respuesta real de `/health`.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key, this.compact = true});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<ConnectionMonitor>();
    final (color, label) = switch (m.server) {
      ServiceState.ok => (LexairColors.ok, 'Servidor conectado'),
      ServiceState.degraded => (LexairColors.warn, 'Servidor con servicios degradados'),
      ServiceState.down => (LexairColors.danger, 'Servidor desconectado'),
      ServiceState.unknown => (LexairColors.muted, 'Comprobando servidor…'),
    };
    final tooltip = [
      label,
      'Base de datos: ${_name(m.database)}',
      'Mapas: ${_name(m.tiles)}',
      'Búsqueda: ${_name(m.search)}',
      if (m.lastError != null) 'Error: ${m.lastError}',
    ].join('\n');
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: color, semanticLabel: label),
          const SizedBox(width: 6),
          Text(compact ? (m.isOnline ? 'En línea' : 'Sin conexión') : label,
              key: const Key('connection-label'),
              style: TextStyle(fontSize: 12, color: compact ? Colors.white70 : LexairColors.ink)),
        ],
      ),
    );
  }

  static String _name(ServiceState s) => switch (s) {
    ServiceState.ok => 'disponible',
    ServiceState.degraded => 'degradado',
    ServiceState.down => 'no disponible',
    ServiceState.unknown => 'desconocido',
  };
}
