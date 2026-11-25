# Compatibilidad de navegadores

Aquí solo constan resultados de pruebas reales. Que algo no aparezca no significa que sea
compatible.

## Política oficial de Flutter 3.50 (cliente web)

Flutter 3.50 soporta oficialmente Chrome y Edge (últimas 2 versiones), Firefox (últimas 2
versiones) y Safari 15.6+. Firefox 98 y anteriores están **fuera del soporte oficial**,
y eso incluye Firefox 85. Por eso Firefox 85 se ha probado de verdad y no se da nada
por supuesto.

## Compilación probada

- Artefacto `lexair-geo-web` de GitHub Actions (`build-web.yml`, commit `edf73f0`),
  compilado con `--no-web-resources-cdn --no-source-maps --no-wasm-dry-run`.
  Renderizador CanvasKit (JavaScript + WebAssembly).
- Servido detrás de Nginx en el mismo origen (`/` → aplicación, `/api/` → API,
  `/tiles/` → mosaicos) con el API real sobre la base de 500 000 personas sintéticas y
  el paquete cartográfico real `vc-20261125-z16`.
- `check_no_external_urls.sh` correcto: CanvasKit local, fuentes Noto empaquetadas
  (incluido el alias «Roboto») y `fontFallbackBaseUrl` local.

## Resultados (2026-11-25)

| Navegador | Entorno | Acceso | Mapa z11 (agrupaciones) | Zoom a z16 (Santa Clara) | Peticiones externas | Errores de la aplicación |
|---|---|---|---|---|---|---|
| Chromium 156.0.8078.108 (Debian) | Headless, SwiftShader, Playwright | correcto | correcto | — | ninguna | ninguno |
| **Firefox 85.0** (binario oficial de Mozilla, SHA-512 verificado) | Xvfb 1366×768, GL por software, xdotool | correcto | correcto | correcto | ninguna | ninguno |

Evidencias en `docs/results/browser/`: `chromium156-mapa-z11.jpg`,
`firefox85-login.jpg`, `firefox85-mapa-z11.jpg` y `firefox85-santa-clara-z16.jpg`.

Lo que se comprobó en Firefox 85 (agente de usuario
`Mozilla/5.0 (X11; Linux x86_64; rv:85.0) Gecko/20100101 Firefox/85.0` en el registro de
Nginx):

1. Carga completa de la aplicación: `main.dart.js`, CanvasKit genérico
   (`canvaskit/canvaskit.wasm`), fuentes y configuración. Indicador «Servidor
   conectado».
2. Inicio de sesión por teclado y ratón (`/auth/login`, `/auth/me`): 200.
3. Panel de personas con paginación, lista de 10 000+ resultados con grupos A/B/AB y
   mapa provincial con agrupaciones.
4. Cinco pasos de zoom con el botón «+» hasta z16: 220 mosaicos y 6 llamadas a
   `/maps/points`, todo con respuesta 200. Calles reales de Santa Clara (Marta Abreu,
   Independencia, Máximo Gómez, parque Vidal) y atribución © OpenStreetMap visibles.

### Advertencias sobre la prueba

- **Incidencia detectada y corregida.** En el primer intento, el Firefox 85 extraído
  se actualizó solo en segundo plano a la 161 y la prueba se hizo, sin querer, con esa
  versión. Ese resultado se descartó. Se reinstaló 85.0 desde
  `ftp.mozilla.org` (SHA-512 verificado contra `SHA512SUMS`), con
  `distribution/policies.json` (`DisableAppUpdate`) y el directorio en solo lectura,
  y se confirmó la versión por el agente de usuario de cada petición. **En los puestos
  con Firefox 85 hay que desactivar igualmente las actualizaciones** si se quiere
  mantener esa versión. Ver el despliegue más abajo.
- El entorno de pruebas (contenedor) no permite el *sandbox* de contenido de Firefox,
  así que se ejecutó con `MOZ_DISABLE_CONTENT_SANDBOX=1`. Esto no afecta al
  funcionamiento de la aplicación, pero en los puestos reales Firefox debe usar su
  *sandbox* normal.
- Render por software (sin GPU): en equipos reales con aceleración el render será igual
  o más fluido. **No se ha medido la fluidez en hardware antiguo real.**
- **No probado todavía en Firefox 85:** las 17 secciones del panel de administración,
  la importación CSV (selector de archivos), la exportación (descarga), la impresión y
  las ventanas emergentes. Se probarán antes de declarar el soporte completo.

## Cliente heredado (Leaflet)

Con el resultado anterior, Firefox 85 carga y usa el cliente Flutter Web principal, así
que **no hace falta por ahora el cliente heredado con Leaflet 1.9.4**. Se reconsiderará
si las pruebas pendientes en Firefox 85 (administración, archivos) fallan o si el
rendimiento en los equipos reales resulta inaceptable.

## Despliegue en puestos con navegadores antiguos

- Instalar la CA interna (`http://geo.internal/ca/lexair-geo-ca.crt`) en el almacén
  del navegador. Firefox usa su propio almacén salvo con `security.enterprise_roots.enabled`.
- Para fijar una versión de Firefox: `distribution/policies.json` con
  `{"policies": {"DisableAppUpdate": true}}` en el directorio de instalación.
- WebGL habilitado. CanvasKit también funciona con render por software, pero más
  lento.

## Cliente Windows

El cliente de escritorio no depende del navegador. Se compila en CI
(`build-windows.yml`, runner windows-2025) como ZIP portable completo (exe, DLL y
`data/`) e instalador Inno Setup offline. Requiere Windows 10/11 x64. **Pendiente:**
prueba manual de instalación y uso en un equipo Windows real.
