import 'package:flutter/material.dart';

import '../../core/config/terminologia.dart';
import '../../core/runtime/local_runtime.dart';
import '../../core/theme/app_theme.dart';

/// Decisión final del asistente de primera configuración.
sealed class DecisionAsistente {
  const DecisionAsistente();
}

/// Usar el modo de prueba (todo local): se prepara el servidor integrado.
class DecisionLocal extends DecisionAsistente {
  const DecisionLocal();
}

/// Usar el modo de red: conecta al servidor indicado.
class DecisionRed extends DecisionAsistente {
  const DecisionRed(this.url);
  final String url;
}

/// Continuar sin configurar (usa la configuración existente).
class DecisionSaltar extends DecisionAsistente {
  const DecisionSaltar();
}

class _Msg {
  _Msg.bot(this.texto) : esBot = true;
  _Msg.yo(this.texto) : esBot = false;
  final String texto;
  final bool esBot;
}

/// Asistente de primera configuración: un bot conversacional que va
/// preguntando poco a poco y guarda cada respuesta sobre la marcha.
/// Nunca muestra un formulario de golpe.
class AsistenteScreen extends StatefulWidget {
  const AsistenteScreen({
    super.key,
    required this.onDecision,
    required this.onFlag,
  });

  /// Decide el flujo tras el asistente (local / red / saltar).
  final void Function(DecisionAsistente decision) onDecision;

  /// Marca persistente «asistente completado».
  final Future<void> Function() onFlag;

  @override
  State<AsistenteScreen> createState() => _AsistenteScreenState();
}

class _AsistenteScreenState extends State<AsistenteScreen> {
  final List<_Msg> _msgs = [];
  final TextEditingController _texto = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _escribiendo = true;
  bool _ocupado = false;
  int _paso = 0;

  @override
  void initState() {
    super.initState();
    _arrancar();
  }

  @override
  void dispose() {
    _texto.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _arrancar() async {
    await _bot('¡Hola! Soy el asistente de ${T.orgNombre}. Te acompaño para '
        'dejar todo listo en un minuto: te pregunto poco a poco y voy '
        'guardando cada respuesta.');
    await _bot('Primero lo importante: ¿para qué vas a usar este proyecto?');
    if (mounted) setState(() => _escribiendo = false);
  }

  Future<void> _bot(String texto, {Duration espera = const Duration(milliseconds: 500)}) async {
    if (!mounted) return;
    setState(() {
      _escribiendo = true;
      _ocupado = true;
    });
    await Future<void>.delayed(espera);
    if (!mounted) return;
    setState(() {
      _msgs.add(_Msg.bot(texto));
      _escribiendo = false;
      _ocupado = false; // deja ver los botones de respuesta
    });
    _bajar();
  }

  void _yo(String texto) {
    setState(() {
      _msgs.add(_Msg.yo(texto));
      _texto.clear();
    });
    _bajar();
  }

  void _bajar() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  // --- Paso 1 · propósito + terminología automática -----------------------
  Future<void> _elegirProposito(String singular, String plural, String etiqueta) async {
    _yo(etiqueta);
    await Terminologia.I.saveOverrides({
      'sujetoSingular': singular,
      'sujetoPlural': plural,
      'kardexTitulo': plural,
      'kardexTituloCorto': plural.toUpperCase(),
      'importTitulo': 'Importar ${plural.toLowerCase()} (Excel XML)',
    });
    await widget.onFlag();
    _paso = 1;
    await _bot('Perfecto: usaré «$plural» en toda la interfaz. Puedes '
        'cambiarlo después editando terminologia.json o volviendo a este '
        'asistente desde Conexiones de datos.');
    await _bot('Ahora, ¿cómo lo vas a usar aquí?');
    if (mounted) setState(() {});
  }

  // --- Paso 2 · modo (servidor de red · prueba local · cliente) ------------
  Future<void> _elegirModo(bool local, String etiqueta) async {
    _yo(etiqueta);
    _paso = 2;
    if (local) {
      if (etiqueta.startsWith('Servidor')) {
        await _bot('Perfecto: este equipo guardará los datos y atenderá a los '
            'demás. Base de datos y servidor van dentro del programa y los '
            'otros equipos entran como clientes a http://IP-de-este-equipo:3000.');
      } else {
        await _bot('Bien: base de datos y servidor van dentro del programa, '
            'sin red. La primera preparación tarda uno o dos minutos; las '
            'siguientes veces abre rápido.');
      }
      await _bot('¿Dejamos la cuenta inicial por defecto o la personalizas?',
          espera: const Duration(milliseconds: 400));
      if (mounted) setState(() {});
    } else {
      await _bot('Escribe la dirección del servidor de tu organización '
          '(por ejemplo https://geo.interno o http://192.168.10.10:3000). '
          'Después podrás configurar bases externas en Conexiones de datos.');
      if (mounted) setState(() {});
    }
  }

  // --- Paso 3 · cuenta local ------------------------------------------------
  Future<void> _cuenta(bool personalizar) async {
    _yo(personalizar ? 'Quiero personalizarla' : 'Cuenta por defecto');
    if (!personalizar) {
      await _terminarLocal(null, null);
      return;
    }
    await _bot('Indica el nombre de la cuenta (la contraseña inicial será '
        '123k20@A; cámbiala después en Administración → Usuarios).');
    if (mounted) setState(() {});
  }

  Future<void> _guardarCuenta(String usuario) async {
    _yo(usuario);
    await _terminarLocal(usuario, null);
  }

  Future<void> _terminarLocal(String? usuario, String? clave) async {
    if (usuario != null && usuario.trim().isNotEmpty) {
      await guardarConfigLocal(usuarioAdmin: usuario, claveAdmin: clave);
    }
    await widget.onFlag();
    await _bot('Todo guardado. Preparo el sistema (puedes ver el avance '
        'paso a paso) y pasamos al acceso.');
    widget.onDecision(const DecisionLocal());
  }

  Future<void> _guardarUrl(String url) async {
    final u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      await _bot('Esa dirección no parece válida: debe empezar por http:// '
          'o https://. Inténtalo otra vez.');
      if (mounted) setState(() {});
      return;
    }
    _yo(u);
    await widget.onFlag();
    await _bot('Guardado. Si más adelante quieres usar el modo de prueba '
        'local, vuelve a este asistente desde Conexiones de datos.');
    widget.onDecision(DecisionRed(u));
  }

  // --- UI -------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final soloTexto = _paso == 2 && !_msgs.any((m) => m.texto.startsWith('http'))
        && _msgs.isNotEmpty && _msgs.last.texto.contains('dirección del servidor');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        backgroundColor: LexairColors.sidebar,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  _cabecera(context),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(children: [
                        Expanded(child: _chat()),
                        if (!_escribiendo && !_ocupado) _preguntaActual(soloTexto),
                        if (_ocupado && _escribiendo)
                          const Padding(
                            padding: EdgeInsets.all(14),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _TresPuntos(),
                            ),
                          ),
                      ]),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      key: const Key('saltar-asistente'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      onPressed: () async {
                        await widget.onFlag();
                        widget.onDecision(const DecisionSaltar());
                      },
                      icon: const Icon(Icons.skip_next, size: 16),
                      label: const Text('Saltar asistente'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cabecera(BuildContext context) {
    return Row(children: [
      CircleAvatar(
        radius: 22,
        backgroundColor: LexairColors.primary,
        child: ClipOval(
          child: Image.asset('assets/branding/vigia_logo.png', width: 44, height: 44,
              fit: BoxFit.cover),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Asistente de configuración',
              style: TextStyle(
                  color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w700)),
          Text('Te guía paso a paso · guardado automático',
              style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12.5)),
        ]),
      ),
      Image.asset('assets/branding/vigia_logo.png', width: 34, height: 34),
    ]);
  }

  Widget _chat() {
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      children: [
        for (final m in _msgs) _burbuja(m),
      ],
    );
  }

  Widget _burbuja(_Msg m) {
    return Align(
      alignment: m.esBot ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 460),
        decoration: BoxDecoration(
          color: m.esBot ? LexairColors.panel : LexairColors.primary,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(m.esBot ? 4 : 14),
            bottomRight: Radius.circular(m.esBot ? 14 : 4),
          ),
          border: m.esBot ? Border.all(color: LexairColors.border) : null,
        ),
        child: Text(m.texto,
            style: TextStyle(
                fontSize: 14,
                height: 1.35,
                color: m.esBot ? LexairColors.ink : Colors.white)),
      ),
    );
  }

  Widget _preguntaActual(bool soloTexto) {
    switch (_paso) {
      case 0:
        return _filaOpciones([
          ('Estudiantes', () => _elegirProposito('Estudiante', 'Estudiantes', 'Estudiantes')),
          ('Profesorado', () => _elegirProposito('Profesor', 'Profesores', 'Profesorado')),
          ('Personal y visitas', () => _elegirProposito('Colaborador', 'Colaboradores', 'Personal y visitas')),
        ], textoLibre: true, onTexto: (t) => _elegirProposito(t, t, t));
      case 1:
        return _dosModos();
      case 2:
        if (_msgs.isNotEmpty && _msgs.last.texto.contains('cuenta inicial')) {
          return _filaOpciones([
            ('Por defecto (yolexis)', () => _cuenta(false)),
            ('Personalizar', () => _cuenta(true)),
          ]);
        }
        return _entrada(soloTexto: soloTexto);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _dosModos() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: _tarjetaModo(
              icono: Icons.lan_outlined,
              titulo: 'Servidor de red',
              subtitulo: 'Este equipo atiende a los demás',
              texto: 'Guarda la base de datos aquí y los otros equipos '
                  'entran como clientes. Para el servidor del unidad.',
              onTap: () => _elegirModo(true, 'Servidor de red'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _tarjetaModo(
              icono: Icons.computer_outlined,
              titulo: 'Prueba local',
              subtitulo: 'Todo en este equipo',
              texto: 'Base de datos y servidor incluidos, sin red. Ideal '
                  'para probar o trabajar solo.',
              onTap: () => _elegirModo(true, 'Prueba local (todo local)'),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        _tarjetaModo(
          icono: Icons.devices_outlined,
          titulo: 'Solo cliente',
          subtitulo: 'Se conecta a otro equipo',
          texto: 'Este equipo no guarda datos: se conecta al servidor de la '
              'red. Después se puede cambiar.',
          onTap: () => _elegirModo(false, 'Solo cliente'),
        ),
      ]),
    );
  }

  Widget _tarjetaModo({
    required IconData icono,
    required String titulo,
    required String subtitulo,
    required String texto,
    required VoidCallback onTap,
  }) {
    return Material(
      color: LexairColors.panel,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: LexairColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icono, color: LexairColors.primary, size: 26),
            const SizedBox(height: 8),
            Text(titulo,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
            Text(subtitulo,
                style: const TextStyle(fontSize: 12, color: LexairColors.muted)),
            const SizedBox(height: 6),
            Text(texto, style: const TextStyle(fontSize: 12.5, height: 1.3)),
          ]),
        ),
      ),
    );
  }

  Widget _filaOpciones(
    List<(String, VoidCallback)> opciones, {
    bool textoLibre = false,
    void Function(String)? onTexto,
  }) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (t, cb) in opciones)
            OutlinedButton(onPressed: cb, child: Text(t)),
        ]),
        if (textoLibre) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _texto,
                onSubmitted: onTexto,
                decoration: const InputDecoration(
                    hintText: '…o escribe el nombre que prefieras'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                if (_texto.text.trim().isNotEmpty) onTexto!(_texto.text.trim());
              },
              child: const Text('Listo'),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _entrada({required bool soloTexto}) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _texto,
            autofocus: soloTexto,
            onSubmitted: soloTexto
                ? null
                : (v) {
                    if (_msgs.any((m) => m.texto.contains('cuenta inicial')) &&
                        !_msgs.any((m) => m.texto.contains('dirección del servidor'))) {
                      _guardarCuenta(v);
                    } else {
                      _guardarUrl(v);
                    }
                  },
            decoration: InputDecoration(
              hintText: soloTexto
                  ? 'Escribe tu respuesta aquí…'
                  : 'https://… o http://…',
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () {
            final v = _texto.text.trim();
            if (v.isEmpty) return;
            if (soloTexto) return;
            if (_msgs.any((m) => m.texto.contains('cuenta inicial')) &&
                !_msgs.any((m) => m.texto.contains('dirección del servidor'))) {
              _guardarCuenta(v);
            } else {
              _guardarUrl(v);
            }
          },
          child: const Text('Listo'),
        ),
      ]),
    );
  }
}

class _TresPuntos extends StatefulWidget {
  const _TresPuntos();

  @override
  State<_TresPuntos> createState() => _TresPuntosState();
}

class _TresPuntosState extends State<_TresPuntos>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final n = _c.value * 3;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Opacity(
                opacity: n.floor() == i ? 1.0 : 0.35,
                child: const CircleAvatar(
                    radius: 4, backgroundColor: LexairColors.primary),
              ),
            ),
        ]);
      },
    );
  }
}
