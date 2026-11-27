import 'window_init_stub.dart'
    if (dart.library.io) 'window_init_io.dart' as impl;

/// Prepara la ventana de escritorio usando la barra de título de Windows.
Future<void> inicializarVentana() => impl.inicializarVentana();
