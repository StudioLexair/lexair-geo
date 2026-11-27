# Solo runner desechable de GitHub: no instala ni borra datos del usuario.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function Capture([string]$name) {
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
  $g = [System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save((Join-Path $env:RUNNER_TEMP "vigia-setup-$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $g.Dispose(); $bitmap.Dispose() }
}
$exe = (Get-ChildItem (Join-Path $env:GITHUB_WORKSPACE 'instalador') -Filter '*Servidor-x64.exe' | Select-Object -First 1).FullName
if (-not $exe) { throw 'Falta el instalador de servidor' }
$installer = Start-Process -FilePath $exe -ArgumentList '/NORESTART' -PassThru
try {
  Start-Sleep -Seconds 15
  if ($installer.HasExited) { throw "El instalador terminó antes de capturar: $($installer.ExitCode)" }
  Capture 'bienvenida'
} finally {
  Stop-Process -Id $installer.Id -Force -ErrorAction SilentlyContinue
}
