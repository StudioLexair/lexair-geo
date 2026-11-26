import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/config/app_config.dart';
import '../../core/state/connection_monitor.dart';
import '../../core/theme/app_theme.dart';
import '../shell/connection_badge.dart';
import 'auth_controller.dart';
import 'server_settings_dialog.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    await context.read<AuthController>().login(_user.text, _pass.text);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final services = context.read<AppServices>();
    final busy = auth.status == AuthStatus.signingIn;
    return Scaffold(
      body: Row(
        children: [
          if (MediaQuery.sizeOf(context).width > 900)
            const Expanded(child: _BrandPanel()),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Form(
                    key: _form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Iniciar sesión',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Acceso restringido a personal autorizado.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          key: const Key('login-username'),
                          controller: _user,
                          autofillHints: const [AutofillHints.username],
                          decoration: const InputDecoration(
                            labelText: 'Usuario',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          validator: (v) => (v == null || v.trim().length < 3)
                              ? 'Indique su usuario'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('login-password'),
                          controller: _pass,
                          obscureText: _obscure,
                          onFieldSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: 'Contraseña',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: _obscure ? 'Mostrar' : 'Ocultar',
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Indique su contraseña'
                              : null,
                        ),
                        if (auth.error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            auth.error!,
                            key: const Key('login-error'),
                            style: const TextStyle(color: LexairColors.danger),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          key: const Key('login-submit'),
                          onPressed: busy ? null : _submit,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: busy
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Entrar'),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const ConnectionBadge(compact: false),
                            TextButton.icon(
                              icon: const Icon(Icons.dns_outlined, size: 18),
                              label: const Text('Servidor'),
                              onPressed: () async {
                                final changed = await showDialog<bool>(
                                  context: context,
                                  builder: (_) => ServerSettingsDialog(
                                    config: services.config,
                                    store: services.configStore,
                                  ),
                                );
                                if (changed == true && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Guardado. Reinicie la aplicación para aplicar el cambio.',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                        Text(
                          services.config.serverUrl,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    final monitor = context.watch<ConnectionMonitor>();
    return Container(
      color: LexairColors.sidebar,
      padding: const EdgeInsets.all(48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Image(image: AssetImage('assets/branding/vigia_logo.png'), width: 48, height: 48),
              SizedBox(width: 12),
              Text(
                'VIGÍA',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Sistema de información geográfica de Villa Clara',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const Spacer(),
          _fact(
            Icons.lan_outlined,
            'Funciona íntegramente en la red interna, sin Internet.',
          ),
          _fact(
            Icons.map_outlined,
            'Cartografía local: © OpenStreetMap contributors (ODbL).',
          ),
          _fact(
            Icons.verified_user_outlined,
            'Acceso auditado y controlado por permisos.',
          ),
          if (monitor.mapIsSynthetic)
            _fact(
              Icons.warning_amber,
              'Atención: el servidor usa un paquete cartográfico SINTÉTICO de pruebas.',
            ),
          const SizedBox(height: 32),
          const Text(
            'Studio Lexair · v${AppConfig.appVersion}',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _fact(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Icon(icon, color: Colors.white54, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: const TextStyle(color: Colors.white70)),
        ),
      ],
    ),
  );
}
