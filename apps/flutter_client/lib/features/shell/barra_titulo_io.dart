import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/config/terminologia.dart';
import '../../core/theme/app_theme.dart';

/// Barra de título propia de VIGÍA (sustituye a la de Windows): logo, nombre
/// completo, distintivo de modo y botones minimizar/maximizar/cerrar; toda la
/// zona es arrastrable para mover la ventana.
class BarraTitulo extends StatefulWidget {
  const BarraTitulo({super.key, this.badge});
  final String? badge;

  @override
  State<BarraTitulo> createState() => _BarraTituloState();
}

class _BarraTituloState extends State<BarraTitulo> with WindowListener {
  bool _maximizada = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refrescar();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refrescar() async {
    try {
      final m = await windowManager.isMaximized();
      if (mounted && m != _maximizada) setState(() => _maximizada = m);
    } catch (_) {}
  }

  @override
  void onWindowMaximize() => setState(() => _maximizada = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximizada = false);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: LexairColors.sidebar,
      child: DragToMoveArea(
        child: Row(children: [
          const SizedBox(width: 10),
          Image.asset('assets/branding/vigia_logo.png', width: 26, height: 26),
          const SizedBox(width: 10),
          Text('${T.orgNombre} · Lexair Geo',
              style: const TextStyle(
                  color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
          if (widget.badge != null) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: LexairColors.sidebarActive,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(widget.badge!,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ),
          ],
          const Spacer(),
          _BotonVentana(
            icon: Icons.minimize,
            tooltip: 'Minimizar',
            onTap: () => windowManager.minimize(),
          ),
          _BotonVentana(
            icon: _maximizada ? Icons.filter_none : Icons.crop_square,
            tooltip: _maximizada ? 'Restaurar' : 'Maximizar',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _BotonVentana(
            icon: Icons.close,
            tooltip: 'Cerrar',
            peligroso: true,
            onTap: () => windowManager.close(),
          ),
        ]),
      ),
    );
  }
}

class _BotonVentana extends StatelessWidget {
  const _BotonVentana({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.peligroso = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool peligroso;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: peligroso ? const Color(0xFFC0392B) : Colors.white24,
          child: SizedBox(
            width: 46,
            height: 44,
            child: Icon(icon, size: 17, color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

BarraTitulo crearBarraTitulo(String? badge) => BarraTitulo(badge: badge);
