import 'barra_titulo_stub.dart'
    if (dart.library.io) 'barra_titulo_io.dart' as impl;

export 'barra_titulo_stub.dart'
    if (dart.library.io) 'barra_titulo_io.dart' show BarraTitulo;
export 'barra_titulo_stub.dart'
    if (dart.library.io) 'barra_titulo_io.dart' show crearBarraTitulo;

/// Crea una [BarraTitulo] real en escritorio y vacía en web.
impl.BarraTitulo? barraTitulo(String? badge) =>
    impl.crearBarraTitulo(badge);
