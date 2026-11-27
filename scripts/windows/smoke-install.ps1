# Prueba el EXE instalado y su arranque completo, no solo el paquete previo.
# Se ejecuta únicamente en un runner Windows efímero de GitHub Actions.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP 'VigiaPruebaInstalada'
$exe = (Get-ChildItem (Join-Path $env:GITHUB_WORKSPACE 'out') -Filter '*Servidor-x64.exe' | Select-Object -First 1).FullName
if (-not $exe) { throw 'No se encontró el instalador de servidor' }
$installer = Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/ROLE=red',"/DIR=$root") -Wait -PassThru
if ($installer.ExitCode -ne 0) { throw "Instalador falló: $($installer.ExitCode)" }
$app = Join-Path $root 'lexair_geo.exe'
foreach ($f in @('lexair_geo.exe','servidor\sql\migrations\0001_extensions_and_schemas.sql','servidor\pg\lib\postgis-3.dll','servidor\tiles\src\server.mjs','servidor\mapa\manifest.json','servidor\mapa\standard.mbtiles')) {
  if (-not (Test-Path (Join-Path $root $f))) { throw "Falta en la instalación: $f" }
}
# Evita depender de la pantalla interactiva para ejercitar el arranque real.
# Se crea una cuenta efímera de CI, nunca datos reales.
$vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($app)
$prefsDir = Join-Path (Join-Path $env:APPDATA $vi.CompanyName) $vi.ProductName
New-Item -ItemType Directory -Force $prefsDir | Out-Null
'{"flutter.lexair.asistenteCompletado":true}' | Set-Content (Join-Path $prefsDir 'shared_preferences.json') -Encoding utf8NoBOM
$localDir = Join-Path $env:LOCALAPPDATA 'VIGIA'
New-Item -ItemType Directory -Force $localDir | Out-Null
'{"usuarioAdmin":"ci-operator","claveAdmin":"Temporary-CI-8192"}' | Set-Content (Join-Path $localDir 'servidor-local.json') -Encoding utf8NoBOM
$oldPath = $env:PATH
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
try {
  $process = Start-Process -FilePath $app -WorkingDirectory $root -PassThru
  $ok = $false
  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 2
    try { $health = Invoke-RestMethod -TimeoutSec 2 'http://127.0.0.1:3000/api/v1/health/live'; $ok = $true; break } catch {}
    if ($process.HasExited) { throw "La aplicación terminó antes de arrancar: $($process.ExitCode)" }
  }
  if (-not $ok) { throw 'La API no respondió dentro del límite de arranque' }
  $body = @{ username='ci-operator'; password='Temporary-CI-8192'; clientKind='windows' } | ConvertTo-Json
  $auth = Invoke-RestMethod -Method Post -ContentType 'application/json' -Body $body 'http://127.0.0.1:3000/api/v1/auth/login'
  if (-not $auth.token) { throw 'El acceso de CI no devolvió un token' }
  # La cuenta temporal debe cambiar su contraseña antes de consultar mapas.
  $change = @{ currentPassword='Temporary-CI-8192'; newPassword='Changed-CI-4769' } | ConvertTo-Json
  Invoke-RestMethod -Method Post -ContentType 'application/json' -Headers @{Authorization="Bearer $($auth.token)"} -Body $change 'http://127.0.0.1:3000/api/v1/auth/change-password' | Out-Null
  $styles = Invoke-RestMethod -Headers @{Authorization="Bearer $($auth.token)"} 'http://127.0.0.1:3000/api/v1/maps/styles'
  if (-not $styles.installed -or $styles.isSynthetic -ne $false -or $styles.styles.Count -ne 3) { throw 'El mapa real no se anunció correctamente' }
  $tile = Invoke-WebRequest 'http://127.0.0.1:3000/tiles/standard/10/284/446.png' -OutFile (Join-Path $env:RUNNER_TEMP 'vigia-ci-mapa.png') -PassThru
  if ($tile.StatusCode -ne 200 -or $tile.Headers['Content-Type'] -notmatch 'image/png') { throw 'No se pudo servir el mapa local' }
  $signature = [System.IO.File]::ReadAllBytes((Join-Path $env:RUNNER_TEMP 'vigia-ci-mapa.png'))
  if ($signature.Length -lt 100 -or $signature[0] -ne 137 -or $signature[1] -ne 80 -or $signature[2] -ne 78 -or $signature[3] -ne 71) { throw 'Mosaico PNG inválido' }
  Write-Host 'Mapa real: manifiesto, estilos y mosaico local verificados.'
  Write-Host 'Instalador, arranque del programa y acceso mediante API: correctos'
} finally {
  $env:PATH = $oldPath
  Write-Host 'Diagnóstico de dependencias PE de PostGIS instalado:'
  try { python (Join-Path $env:GITHUB_WORKSPACE 'scripts\windows\diagnose_dll.py') $root } catch { Write-Host "Diagnóstico PE no disponible: $_" }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $env:RUNNER_TEMP 'vigia-ci-pantalla.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
  } catch { Write-Host "Captura no disponible en este runner: $_" }
  $bootstrapLog = Join-Path $localDir 'logs\arranque.log'
  if (Test-Path $bootstrapLog) { Write-Host 'Detalle del arranque:'; Get-Content $bootstrapLog -Tail 100 }
  $log = Join-Path $localDir 'logs\postgresql.log'
  if (Test-Path $log) { Get-Content $log -Tail 100 }
  if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  $pgctl = Join-Path $root 'servidor\pg\bin\pg_ctl.exe'
  $data = Join-Path $localDir 'datos'
  if ((Test-Path $pgctl) -and (Test-Path (Join-Path $data 'PG_VERSION'))) { & $pgctl -D $data -m fast -w stop 2>&1 | Out-Host }
}
