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
  # Entrada interactiva real: solo cuenta ficticia en el runner efímero.
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VigiaCiWindow {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
'@
  $psql = Join-Path $root 'servidor\pg\bin\psql.exe'
  $sql = 'SELECT count(*) FROM security.sessions'
  $before = [int]((& $psql -h 127.0.0.1 -p 5433 -U lexair -d lexair_geo -tAc $sql | Out-String).Trim())
  $process.Refresh()
  if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'No se encontró la ventana para probar el acceso visual' }
  [VigiaCiWindow]::ShowWindow($process.MainWindowHandle, 3) | Out-Null
  [VigiaCiWindow]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
  Start-Sleep -Seconds 3
  $rect = New-Object VigiaCiWindow+Rect
  [VigiaCiWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect) | Out-Null
  $width = $rect.Right - $rect.Left; $height = $rect.Bottom - $rect.Top
  $x = [int]($rect.Left + $width * 0.75)
  $y = [int]($rect.Top + 30 + ($height - 30) / 2 - 48)
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
  [VigiaCiWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  [VigiaCiWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  [System.Windows.Forms.SendKeys]::SendWait('ci-operator')
  [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
  [System.Windows.Forms.SendKeys]::SendWait('Changed-CI-4769')
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  $guiOk = $false
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $after = [int]((& $psql -h 127.0.0.1 -p 5433 -U lexair -d lexair_geo -tAc $sql | Out-String).Trim())
    if ($after -gt $before) { $guiOk = $true; break }
  }
  if (-not $guiOk) { throw 'No se pudo confirmar el acceso mediante la ventana de VIGÍA' }
  Start-Sleep -Seconds 5
  Write-Host 'Acceso interactivo confirmado en la ventana con una cuenta ficticia.'
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
  # Solo procesos ejecutados desde esta instalación de prueba desechable.
  $node = Join-Path $root 'servidor\node\node.exe'
  Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $node } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

# Reinstalar sobre la misma ruta, sin borrar datos, y comprobar la cuenta y
# contraseña modificada del ensayo anterior (no hay datos de producción).
$updateLog = Join-Path $env:RUNNER_TEMP 'vigia-ci-reinstalacion.log'
Write-Host 'Iniciando reinstalación silenciosa sobre los datos de prueba…'
$again = Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/ROLE=red',"/DIR=$root", "/LOG=$updateLog") -PassThru
if (-not $again.WaitForExit(240000)) {
  if (Test-Path $updateLog) { Get-Content $updateLog -Tail 60 | Out-Host }
  Stop-Process -Id $again.Id -Force -ErrorAction SilentlyContinue
  throw 'La reinstalación no terminó en cuatro minutos'
}
if ($again.ExitCode -ne 0) {
  if (Test-Path $updateLog) { Get-Content $updateLog -Tail 60 | Out-Host }
  throw "Reinstalación falló: $($again.ExitCode)"
}
if (-not (Test-Path (Join-Path $data 'PG_VERSION'))) { throw 'La reinstalación no conservó la base de datos' }
try {
  $process2 = Start-Process -FilePath $app -WorkingDirectory $root -PassThru
  $ok = $false
  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 2
    try { Invoke-RestMethod -TimeoutSec 2 'http://127.0.0.1:3000/api/v1/health/live' | Out-Null; $ok = $true; break } catch {}
    if ($process2.HasExited) { throw 'VIGÍA se cerró durante la prueba de reinstalación' }
  }
  if (-not $ok) { throw 'No arrancó tras reinstalar' }
  $body2 = @{ username='ci-operator'; password='Changed-CI-4769'; clientKind='windows' } | ConvertTo-Json
  $auth2 = Invoke-RestMethod -Method Post -ContentType 'application/json' -Body $body2 'http://127.0.0.1:3000/api/v1/auth/login'
  if (-not $auth2.token) { throw 'La cuenta anterior no sobrevivió a la reinstalación' }
  Write-Host 'Reinstalación silenciosa: datos y cuenta anterior conservados.'
} finally {
  if ($process2 -and -not $process2.HasExited) { Stop-Process -Id $process2.Id -Force -ErrorAction SilentlyContinue }
  if ((Test-Path $pgctl) -and (Test-Path (Join-Path $data 'PG_VERSION'))) { & $pgctl -D $data -m fast -w stop 2>&1 | Out-Host }
  $node = Join-Path $root 'servidor\node\node.exe'
  Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $node } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
}
