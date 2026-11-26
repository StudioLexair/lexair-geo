import 'window_init_stub.dart'
    if (dart.library.io) 'window_init_io.dart' as impl;

/// Prepara la ventana de escritorio: sin barra de título nativa (la
/// aplicación dibuja la suya propia con logo, nombre y botones).
Future<void> inicializarVentana() => impl.inicializarVentana();
