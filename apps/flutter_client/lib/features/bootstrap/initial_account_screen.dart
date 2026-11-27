import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../auth/change_password_screen.dart' show passwordPolicyError;

/// Solicita una sola respuesta cada vez. La clave nunca se añade al chat ni
/// se guarda en el equipo; se entrega solo al proceso de creación de cuenta.
class InitialAccountScreen extends StatefulWidget {
  const InitialAccountScreen({super.key, required this.onComplete});
  final void Function(String usuario, String clave) onComplete;

  @override
  State<InitialAccountScreen> createState() => _InitialAccountScreenState();
}

class _InitialAccountScreenState extends State<InitialAccountScreen> {
  final _input = TextEditingController();
  int _paso = 0;
  String _usuario = '';
  String _clave = '';
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    _clave = '';
    super.dispose();
  }

  void _siguiente() {
    final valor = _input.text;
    if (_paso == 0) {
      final usuario = valor.trim().toLowerCase();
      if (!RegExp(r'^[a-z0-9._-]{3,40}$').hasMatch(usuario)) {
        setState(() => _error = 'Use entre 3 y 40 letras, números, puntos, guiones o guiones bajos.');
        return;
      }
      _usuario = usuario;
    } else if (_paso == 1) {
      final error = passwordPolicyError(valor);
      if (error != null || valor.length > 128 || valor.toLowerCase().contains(_usuario)) {
        setState(() => _error = error ?? 'La contraseña debe tener como máximo 128 caracteres y no contener el usuario.');
        return;
      }
      _clave = valor;
    } else {
      if (valor != _clave) {
        setState(() => _error = 'Las contraseñas no coinciden.');
        return;
      }
      final clave = _clave;
      _clave = '';
      _input.clear();
      widget.onComplete(_usuario, clave);
      return;
    }
    _input.clear();
    setState(() { _paso++; _error = null; });
  }

  @override
  Widget build(BuildContext context) {
    final pregunta = switch (_paso) {
      0 => '¿Qué nombre tendrá la primera cuenta?',
      1 => 'Elige una contraseña para esa cuenta.',
      _ => 'Repite la contraseña para confirmarla.',
    };
    return Scaffold(
      backgroundColor: LexairColors.sidebar,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Primera cuenta', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(pregunta),
                if (_paso == 1) const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Mínimo 12 caracteres y al menos tres tipos: letras mayúsculas, minúsculas, números o símbolos.'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: ValueKey('cuenta-inicial-$_paso'),
                  controller: _input,
                  autofocus: true,
                  obscureText: _paso != 0,
                  enableSuggestions: _paso == 0,
                  autocorrect: _paso == 0,
                  onSubmitted: (_) => _siguiente(),
                  decoration: InputDecoration(
                    labelText: _paso == 0 ? 'Usuario' : 'Contraseña',
                    errorText: _error, errorMaxLines: 3),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _siguiente, child: Text(_paso == 2 ? 'Crear cuenta' : 'Continuar')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
