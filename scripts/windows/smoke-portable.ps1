# Prueba el ZIP portable DESCOMPRIMIDO en el runner temporal, con datos ficticios.
$ErrorActionPreference = 'Stop'
$zip = (Get-ChildItem (Join-Path $env:GITHUB_WORKSPACE 'out') -Filter '*portable.zip' | Select-Object -First 1).FullName
if (-not $zip) { throw 'No se encontró el ZIP portable' }
$root = Join-Path $env:RUNNER_TEMP 'VigiaPortablePrueba'
Expand-Archive -LiteralPath $zip -DestinationPath $root
$app = Join-Path $root 'lexair_geo.exe'
if (-not (Test-Path (Join-Path $root 'servidor\mapa\manifest.json'))) { throw 'Portable sin mapa' }
$oldLocal = $env:LOCALAPPDATA
$oldRoaming = $env:APPDATA
# initdb necesita poder ajustar la ACL: usar el perfil local del runner,
# no D:\a\_temp, que puede negar el cambio de permisos.
$env:LOCALAPPDATA = Join-Path $oldLocal 'vigia-portable-ci'
$env:APPDATA = Join-Path $oldRoaming 'vigia-portable-ci'
$vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($app)
foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA, $oldLocal, $oldRoaming)) {
  $prefs = Join-Path (Join-Path $base $vi.CompanyName) $vi.ProductName
  New-Item -ItemType Directory -Force $prefs | Out-Null
  '{"flutter.lexair.asistenteCompletado":true,"flutter.lexair.serverUrlOverride":"http://127.0.0.1:3000"}' | Set-Content (Join-Path $prefs 'shared_preferences.json') -Encoding utf8NoBOM
}
$local = Join-Path $env:LOCALAPPDATA 'VIGIA'
New-Item -ItemType Directory -Force $local | Out-Null
. (Join-Path $env:GITHUB_WORKSPACE 'scripts\windows\create-initial-account-ci.ps1')
$process = $null
try {
  $process = Start-Process -FilePath $app -WorkingDirectory $root -PassThru
  New-VigiaCiAccount $process $local 'portable-ci' 'Portable-CI-3842'
  $ok = $false
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    try { Invoke-RestMethod -TimeoutSec 2 'http://127.0.0.1:3000/api/v1/health/live' | Out-Null; $ok = $true; break } catch {}
    if ($process.HasExited) { throw 'El portable terminó antes de arrancar' }
  }
  if (-not $ok) { throw 'El portable no arrancó el servidor' }
  $configPath = Join-Path $local 'servidor-local.json'
  if ((Test-Path $configPath) -and ((Get-Content $configPath -Raw) -match 'Portable-CI-3842|claveAdmin')) { throw 'Se guardó la clave inicial en el archivo de configuración' }
  $body = @{ username='portable-ci'; password='Portable-CI-3842'; clientKind='windows' } | ConvertTo-Json
  $auth = Invoke-RestMethod -Method Post -ContentType 'application/json' -Body $body 'http://127.0.0.1:3000/api/v1/auth/login'
  if (-not $auth.token) { throw 'El acceso del portable no funcionó' }
  $tile = Invoke-WebRequest -Uri 'http://127.0.0.1:3000/tiles/standard/10/284/446.png'
  if ($tile.StatusCode -ne 200 -or $tile.Headers['Content-Type'] -notmatch 'image/png') { throw 'El mapa portable no respondió' }
  Write-Host 'Portable descomprimido: arranque, acceso y mapa correctos.'
} finally {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $env:RUNNER_TEMP 'vigia-portable.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
  } catch { Write-Host "Captura portable no disponible: $_" }
  if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  $pgctl = Join-Path $root 'servidor\pg\bin\pg_ctl.exe'
  $data = Join-Path $local 'datos'
  if ((Test-Path $pgctl) -and (Test-Path (Join-Path $data 'PG_VERSION'))) { & $pgctl -D $data -m fast -w stop 2>&1 | Out-Host }
  $node = Join-Path $root 'servidor\node\node.exe'
  Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $node } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
  $log = Join-Path $local 'logs\arranque.log'
  if (Test-Path $log) { Write-Host 'Diagnóstico de arranque portable:'; Get-Content $log -Tail 100 }
  $env:LOCALAPPDATA = $oldLocal
  $env:APPDATA = $oldRoaming
}
