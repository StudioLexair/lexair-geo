# Solo para runners desechables: interactúa con la pantalla real de primera cuenta.
function New-VigiaCiAccount([System.Diagnostics.Process]$Process, [string]$Local, [string]$User, [string]$Password) {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VigiaAccountCiWindow {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
  $log = Join-Path $Local 'logs\arranque.log'
  $found = $false
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    if ($Process.HasExited) { throw 'La aplicación terminó antes de crear la cuenta' }
    if ((Test-Path $log) -and (Select-String -Quiet -Path $log -SimpleMatch 'Esperando creación de la primera cuenta.')) { $found = $true; break }
  }
  if (-not $found) { throw 'No se solicitó la primera cuenta' }
  Start-Sleep -Seconds 3
  $Process.Refresh()
  if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'No hay ventana para crear la cuenta' }
  [VigiaAccountCiWindow]::ShowWindow($Process.MainWindowHandle, 3) | Out-Null
  [VigiaAccountCiWindow]::SetForegroundWindow($Process.MainWindowHandle) | Out-Null
  Start-Sleep -Seconds 2
  [System.Windows.Forms.SendKeys]::SendWait($User)
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 1
  [System.Windows.Forms.SendKeys]::SendWait($Password)
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 1
  [System.Windows.Forms.SendKeys]::SendWait($Password)
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Write-Host 'Datos ficticios introducidos mediante la ventana de primera cuenta.'
}
