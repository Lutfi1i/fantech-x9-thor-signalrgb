<#
  Fantech X9 Thor / SONiX 18F8:xxxx mouse LED control.

  Protocol recovered from the open-source Linux driver
  https://github.com/GuessWhatBBQ/FantechX9ThorDriver (driver_backend.py):

      control transfer: bmRequestType=0x21 bRequest=0x09 (SET_REPORT)
                        wValue=0x0307 (Feature, report ID 7)  wIndex=1
      payload: [0x07, instruction, ...]  (8 bytes total)

      instruction 0x14 -> colour for one profile
      instruction 0x13 -> rgb effect mode + cyclic colour mask
      instruction 0x11 -> scroll wheel function
      instruction 0x09 -> dpi for one profile

  Colour is 4-bit per channel and INVERTED: internal = (255 - value) / 16

  Usage:
    .\x9-ctl.ps1 -ColorHex FF0000 -Mode Static
    .\x9-ctl.ps1 -ColorHex 00FF00 -Mode Cyclic -Duration 2
    .\x9-ctl.ps1 -Mode Off
    .\x9-ctl.ps1 -ColorHex 0000FF -DryRun
#>
param(
  [string]$Vid        = '18F8',
  [string]$ProdId     = '0FC0',
  [string]$ColorHex   = 'FF0000',
  [ValidateSet('Static','Cyclic','Fixed','Off')]
  [string]$Mode       = 'Static',
  [int]$Duration      = 2,          # 1..6, only for Cyclic / Fixed
  [int]$CyclicMask    = 0x7F,       # bit0 Yellow bit1 Blue bit2 Violet bit3 Green bit4 Red bit5 Cyan bit6 White
  [int]$ActiveMask    = 0x3F,       # which of the 6 profiles are enabled
  [switch]$SkipColors,              # only send the mode packet
  [switch]$DryRun
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class X9Hid {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint cd, uint fa, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr h);
  [DllImport("hid.dll")] public static extern bool HidD_SetFeature(IntPtr h, byte[] buf, int len);
  [DllImport("hid.dll")] public static extern bool HidD_GetFeature(IntPtr h, byte[] buf, int len);
  [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
  [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pp);
  [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
}
'@

$HID_GUID = '{4d1e55b2-f16f-11cf-88cb-001111000030}'

function New-ColorPayload {
  param([int]$Profile, [int]$R, [int]$G, [int]$B, [int]$Mask)
  $ir = [int][Math]::Floor((255 - $R) / 16)
  $ig = [int][Math]::Floor((255 - $G) / 16)
  $ib = [int][Math]::Floor((255 - $B) / 16)
  $internalProfile = ($Profile - 1) * 2
  $byte1 = $internalProfile * 16 + $ig
  $byte2 = $ir * 16 + $ib
  return [byte[]]@(0x07, 0x14, $byte1, $byte2, $Mask, 0x00, 0x00, 0x00)
}

function New-ModePayload {
  param([string]$M, [int]$Dur, [int]$CycMask)
  $eff = switch ($M) {
    'Static' { 0x86 }
    'Off'    { 0x87 }
    'Fixed'  { 0x86 - $Dur }
    'Cyclic' { 0x96 - $Dur }
  }
  return [byte[]]@(0x07, 0x13, $CycMask, $eff, 0x00, 0x00, 0x00, 0x00)
}

function Format-Payload($p) { return ($p | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

# ---- colour ----
if ($ColorHex.StartsWith('#')) { $ColorHex = $ColorHex.Substring(1) }
if ($ColorHex.Length -ne 6) { throw "ColorHex harus 6 digit hex, misal FF0000" }
$R = [Convert]::ToInt32($ColorHex.Substring(0,2), 16)
$G = [Convert]::ToInt32($ColorHex.Substring(2,2), 16)
$B = [Convert]::ToInt32($ColorHex.Substring(4,2), 16)

Write-Host ("warna     : #{0}  (R={1} G={2} B={3})" -f $ColorHex, $R, $G, $B)
Write-Host ("mode      : {0}  durasi={1}  cyclicMask=0x{2:X2}  activeMask=0x{3:X2}" -f $Mode, $Duration, $CyclicMask, $ActiveMask)
Write-Host ("quantisasi: R->{0} G->{1} B->{2}  (4-bit terbalik, 16 tingkat per kanal)" -f `
  [int][Math]::Floor((255-$R)/16), [int][Math]::Floor((255-$G)/16), [int][Math]::Floor((255-$B)/16))

$colorPackets = @()
if (-not $SkipColors) {
  for ($p = 1; $p -le 6; $p++) { $colorPackets += ,(New-ColorPayload -Profile $p -R $R -G $G -B $B -Mask $ActiveMask) }
}
$modePacket = New-ModePayload -M $Mode -Dur $Duration -CycMask $CyclicMask

if ($DryRun) {
  Write-Host "`n--- payload (dry run, tidak dikirim) ---"
  $i = 1
  foreach ($cp in $colorPackets) { Write-Host ("  warna profil {0}: {1}" -f $i, (Format-Payload $cp)); $i++ }
  Write-Host ("  mode          : {0}" -f (Format-Payload $modePacket))
  exit 0
}

# ---- open COL04 (the 8-byte feature-report collection) ----
$dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -like "HID\VID_$Vid&PID_$ProdId&MI_01&COL04*" } |
       Select-Object -First 1
if (-not $dev) { throw "Collection vendor (MI_01 COL04) tidak ditemukan untuk $Vid`:$ProdId" }

$path = '\\?\' + ($dev.InstanceId -replace '\\','#').ToLower() + '#' + $HID_GUID
Write-Host "endpoint  : $path"

$h = [X9Hid]::CreateFileW($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h -eq [IntPtr](-1)) { throw ('CreateFile gagal, err={0}' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }

$pp = [IntPtr]::Zero
if ([X9Hid]::HidD_GetPreparsedData($h, [ref]$pp)) {
  $caps = New-Object byte[] 64
  [void][X9Hid]::HidP_GetCaps($pp, $caps)
  Write-Host ("            feature report = {0} byte (termasuk report ID)" -f [BitConverter]::ToUInt16($caps, 8))
  [void][X9Hid]::HidD_FreePreparsedData($pp)
}

$ok = 0; $fail = 0
foreach ($cp in $colorPackets) {
  if ([X9Hid]::HidD_SetFeature($h, $cp, $cp.Length)) { $ok++ }
  else { $fail++; Write-Host ("  GAGAL: {0}  err={1}" -f (Format-Payload $cp), [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  Start-Sleep -Milliseconds 20
}
if ([X9Hid]::HidD_SetFeature($h, $modePacket, $modePacket.Length)) { $ok++ }
else { $fail++; Write-Host ("  GAGAL mode: {0}  err={1}" -f (Format-Payload $modePacket), [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }

Write-Host ("`nhasil     : {0} paket terkirim, {1} gagal" -f $ok, $fail)
Write-Host ("            mode payload = {0}" -f (Format-Payload $modePacket))

[void][X9Hid]::CloseHandle($h)
Write-Host "selesai   : handle dilepas (mouse tetap menyimpan setting ini)"
