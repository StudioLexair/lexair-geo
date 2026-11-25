import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/config/config_store.dart';

/// Cambia la dirección del servidor sin recompilar. Requiere reiniciar la
/// aplicación para recrear el cliente HTTP con la nueva dirección.
class ServerSettingsDialog extends StatefulWidget {
  const ServerSettingsDialog({super.key, required this.config, required this.store});
  final AppConfig config;
  final ConfigStore store;

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late final TextEditingController _url = TextEditingController(text: widget.config.serverUrl);
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save({bool reset = false}) async {
    if (!reset && !AppConfig.isValidServerUrl(_url.text)) {
      setState(() => _error = 'Use una URL como https://geo.internal o https://192.168.10.10');
      return;
    }
    await widget.store.saveOverride(reset ? null : _url.text);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Servidor LEXAIR GEO'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Valor actual: ${widget.config.serverUrl} (${widget.config.source})',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              key: const Key('server-url-field'),
              controller: _url,
              decoration: InputDecoration(labelText: 'Dirección del servidor', errorText: _error),
            ),
            const SizedBox(height: 8),
            Text('El cambio se aplica al reiniciar la aplicación.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => _save(reset: true), child: const Text('Restablecer')),
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: _save, child: const Text('Guardar')),
      ],
    );
  }
}
