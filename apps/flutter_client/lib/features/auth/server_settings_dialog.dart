import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/config/config_store.dart';

/// Cambia la dirección del servidor sin recompilar; se aplica al guardar.
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
    final esLocal = _url.text.contains('127.0.0.1') || _url.text.contains('localhost');
    return AlertDialog(
      title: const Text('Servidor'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Valor actual: ${widget.config.serverUrl} (${widget.config.source})',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, icon: Icon(Icons.computer, size: 16), label: Text('Modo de prueba')),
                ButtonSegment(value: false, icon: Icon(Icons.lan, size: 16), label: Text('Modo de red')),
              ],
              selected: {esLocal},
              onSelectionChanged: (sel) {
                setState(() => _url.text = sel.first ? 'http://127.0.0.1:3000' : 'https://geo.internal');
                _error = null;
              },
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('server-url-field'),
              controller: _url,
              decoration: InputDecoration(labelText: 'Dirección del servidor', errorText: _error),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('local-mode-button'),
                icon: const Icon(Icons.computer, size: 16),
                label: const Text('Usar modo local (http://localhost:3000)'),
                onPressed: () {
                  setState(() => _url.text = 'http://localhost:3000');
                },
              ),
            ),
            const SizedBox(height: 8),
            Text('El cambio se aplica al guardar.',
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
