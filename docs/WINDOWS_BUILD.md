# Cliente Windows

Flutter 3.50.1 (Dart 3.14), Windows 10 1809+ / Windows 11 x64.

## Compilación

Se compila en GitHub Actions (`.github/workflows/build-windows.yml`, runner
`windows-2025`); no hace falta un equipo Windows de desarrollo.

```powershell
cd apps/flutter_client
flutter pub get --enforce-lockfile
flutter build windows --release
```

Artefactos (`lexair-geo-windows-X.Y.Z`):

| Archivo | Contenido |
|---------|-----------|
| `LexairGeo-X.Y.Z-windows-x64.zip` | Carpeta completa: `lexair_geo.exe`, `flutter_windows.dll`, DLL de plugins, `data\` (`app.so`, `icudtl.dat`, `flutter_assets`), `config.example.json` |
| `LexairGeo-X.Y.Z-Setup-x64.exe` | Instalador offline Inno Setup 6.7.1 (todo incluido, sin descargas) |
| `SHA256SUMS-windows.txt` | Sumas de verificación |

El flujo comprueba que `lexair_geo.exe`, `flutter_windows.dll`, `data\icudtl.dat` y
`data\app.so` existen antes de empaquetar.

## Instalación

Interactiva: el asistente pide la URL del servidor. Silenciosa (despliegue en 30 puestos):

```bat
LexairGeo-0.1.0-Setup-x64.exe /VERYSILENT /SERVERURL=https://geo.internal /CAFILE=\\servidor\share\lexair-geo-ca.crt
```

- Instala en `C:\Program Files\LexairGeo`.
- Escribe `C:\ProgramData\LexairGeo\config.json` solo si no existe (las
  actualizaciones conservan la configuración).
- Con `/CAFILE`, copia la CA a `C:\ProgramData\LexairGeo\` y la añade al almacén
  «Raíz de confianza» (`certutil -addstore Root`).

ZIP portable: descomprima en cualquier carpeta y cree `config.json` junto a
`lexair_geo.exe`:

```json
{ "serverUrl": "https://geo.internal", "healthPollSeconds": 15,
  "caCertificatePath": "C:\\ProgramData\\LexairGeo\\lexair-geo-ca.crt" }
```

Orden de búsqueda de configuración: `config.json` junto al ejecutable →
`%PROGRAMDATA%\LexairGeo\config.json` → ajuste guardado desde la pantalla de acceso.

## Requisitos en el puesto

- Microsoft Visual C++ Redistributable 2015–2022 x64 (presente en Windows 10/11
  actualizados; si falta, distribúyalo con el instalador offline de Microsoft).
- Sin Internet: la aplicación solo contacta con el servidor configurado.

## Estado de verificación

La compilación Windows se ejecuta en CI. Las pruebas manuales en un puesto Windows
real de la LAN quedan registradas en [TESTING.md](TESTING.md) cuando se realicen; no
se declara probado lo que no se ha ejecutado.
