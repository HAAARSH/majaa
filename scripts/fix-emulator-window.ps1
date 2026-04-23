# Moves any qemu-system-x86_64.exe emulator window to (50, 50) on primary monitor.
# Workaround for Windows remembering a phantom secondary monitor above primary
# that causes Qt-based emulator windows to position at y = -750.
#
# Usage: launch emulator, then run this script:
#   powershell -NoProfile -ExecutionPolicy Bypass -File fix-emulator-window.ps1

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class EmuWin {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumDel f, IntPtr l);
  public delegate bool EnumDel(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@

$qemu = Get-Process -Name "qemu-system-x86_64" -ErrorAction SilentlyContinue
if (-not $qemu) {
    Write-Host "No qemu-system-x86_64 process running. Start the emulator first."
    exit 1
}
$targetPid = $qemu.Id
Write-Host "Targeting qemu PID: $targetPid"

$found = $false
$cb = [EmuWin+EnumDel]{
  param($h, $l)
  $procId = [uint32]0
  [EmuWin]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
  if ($procId -eq $script:targetPid) {
    $sb = New-Object System.Text.StringBuilder 256
    [EmuWin]::GetWindowText($h, $sb, 256) | Out-Null
    $title = $sb.ToString()
    if ($title -like "*Android Emulator*") {
      [EmuWin]::SetWindowPos($h, [IntPtr]::Zero, 50, 50, 500, 900, 0x0044) | Out-Null
      [EmuWin]::ShowWindow($h, 9) | Out-Null
      [EmuWin]::SetForegroundWindow($h) | Out-Null
      Write-Host "Moved '$title' to (50, 50) at 500x900"
      $script:found = $true
    }
  }
  return $true
}
[EmuWin]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if (-not $found) { Write-Host "No 'Android Emulator' window found for PID $targetPid" }
