{{flutter_js}}
{{flutter_build_config}}

// LEXAIR GEO funciona sin Internet: CanvasKit se sirve desde el propio servidor
// (--no-web-resources-cdn) y el motor no debe pedir fuentes a fonts.gstatic.com.
// La interfaz usa Noto Sans empaquetada; si faltara algún glifo, el motor buscaría
// el respaldo en esta ruta local en lugar de Internet.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'assets/fonts/fallback/',
  },
});
