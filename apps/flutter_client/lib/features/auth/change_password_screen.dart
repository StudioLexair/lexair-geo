import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import 'auth_controller.dart';

/// Misma política que el servidor (mín. 12 caracteres, 3 tipos).
String? passwordPolicyError(String? v) {
  final s = v ?? '';
  if (s.length < 12) return 'Mínimo 12 caracteres';
  final classes = [RegExp('[a-z]'), RegExp('[A-Z]'), RegExp(r'\d'), RegExp('[^A-Za-z0-9]')]
      .where((r) => r.hasMatch(s))
      .length;
  return classes < 3 ? 'Combine minúsculas, mayúsculas, números o símbolos' : null;
}


/// Obligatoria tras una contraseña temporal. El servidor bloquea el resto
/// de operaciones hasta completarla.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    final err = await context.read<AuthController>().changePassword(_current.text, _next.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthController>();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Cambiar contraseña', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text('${auth.user?.displayName ?? ''}: su contraseña es temporal y debe sustituirla.',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 20),
                TextFormField(controller: _current, obscureText: true,
                    decoration: const InputDecoration(labelText: 'Contraseña actual'),
                    validator: (v) => (v ?? '').isEmpty ? 'Obligatoria' : null),
                const SizedBox(height: 10),
                TextFormField(controller: _next, obscureText: true,
                    decoration: const InputDecoration(labelText: 'Nueva contraseña'), validator: passwordPolicyError),
                const SizedBox(height: 10),
                TextFormField(controller: _repeat, obscureText: true,
                    decoration: const InputDecoration(labelText: 'Repetir nueva contraseña'),
                    validator: (v) => v != _next.text ? 'No coincide' : null),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: LexairColors.danger)),
                ],
                const SizedBox(height: 18),
                FilledButton(onPressed: _busy ? null : _submit, child: const Text('Guardar')),
                TextButton(onPressed: auth.logout, child: const Text('Cerrar sesión')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
