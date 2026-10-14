<#
  Inspect HID collections for a given VID/PID: caps, product string and a parsed
  report descriptor. Read-only unless -SendFeature is used.

  Usage:
    .\hid-inspect.ps1 -Vid 18F8 -Pid 0FC0
#>
param(
  [string]$Vid = '18F8',
  [string]$ProdId = '0FC0'
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HidInsp {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint cd, uint fa, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize,
      byte[] outBuf, uint outSize, out uint returned, IntPtr overlapped);
  [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
  [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pp);
  [DllImport("hid.dll")] public static extern bool HidD_GetProductString(IntPtr h, byte[] buf, int len);
  [DllImport("hid.dll")] public static extern bool HidD_GetManufacturerString(IntPtr h, byte[] buf, int len);
  [DllImport("hid.dll")] public static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
  [DllImport("hid.dll")] public static extern bool HidD_SetFeature(IntPtr h, byte[] buf, int len);
  [DllImport("hid.dll")] public static extern bool HidD_GetFeature(IntPtr h, byte[] buf, int len);
}
'@

$HID_GUID = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
$IOCTL_GET_REPORT_DESCRIPTOR = 0x000B0190

function Get-U16($b, $o) { return [BitConverter]::ToUInt16($b, $o) }
function Get-Str($b) { return ([Text.Encoding]::Unicode.GetString($b)).Trim([char]0) }

# ---- parse a HID report descriptor, collecting per-report-ID byte lengths ----
function Parse-Descriptor($d) {
  $state = @{ usagePage = 0; reportSize = 0; reportCount = 0; reportId = 0 }
  $out = @()
  $i = 0
  while ($i -lt $d.Length) {
    $prefix = $d[$i]; $i++
    if ($prefix -eq 0xFE) {                       # long item
      $size = $d[$i + 1]; $i += 3 + $size; continue
    }
    $sizeCode = $prefix -band 0x03
    $size = switch ($sizeCode) { 0 {0} 1 {1} 2 {2} 3 {4} }
    $type = ($prefix -shr 2) -band 0x03           # 0 main, 1 global, 2 local
    $tag = ($prefix -shr 4) -band 0x0F
    $data = 0
    for ($k = 0; $k -lt $size; $k++) { $data = $data -bor ($d[$i + $k] -shl (8 * $k)) }
    $i += $size

    if ($type -eq 1) {
      switch ($tag) {
        0 { $state.usagePage = $data }
        7 { $state.reportSize = $data }
        8 { $state.reportId = $data }
        9 { $state.reportCount = $data }
      }
    } elseif ($type -eq 0) {
      $kind = switch ($tag) { 8 {'Input'} 9 {'Output'} 11 {'Feature'} default { $null } }
      if ($kind) {
        $bits = $state.reportSize * $state.reportCount
        $bytes = [Math]::Ceiling($bits / 8)
        $out += [pscustomobject]@{ ReportID = $state.reportId; Kind = $kind; Bits = $bits; Bytes = $bytes }
      }
    }
  }
  return $out
}

$devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like "HID\VID_$Vid&PID_$ProdId*" } |
        Sort-Object InstanceId

if (-not $devs) { Write-Host "Tidak ada device HID $Vid`:$ProdId"; exit 1 }

foreach ($dev in $devs) {
  $path = '\\.\' -replace '\\\\\.', '\\?\'   # placeholder, replaced below
  $path = '\\?\' + ($dev.InstanceId -replace '\\', '#').ToLower() + '#' + $HID_GUID
  Write-Host ("`n===== {0}  [{1}] =====" -f $dev.InstanceId, $dev.Status)
  Write-Host ("  path: {0}" -f $path)

  $h = [HidInsp]::CreateFileW($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
  if ($h -eq [IntPtr](-1)) {
    Write-Host ("  CreateFile gagal, err={0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    continue
  }

  $buf = New-Object byte[] 256
  if ([HidInsp]::HidD_GetProductString($h, $buf, 256)) { Write-Host ("  product     : {0}" -f (Get-Str $buf)) }
  if ([HidInsp]::HidD_GetManufacturerString($h, $buf, 256)) { Write-Host ("  manufacturer: {0}" -f (Get-Str $buf)) }

  $pp = [IntPtr]::Zero
  if ([HidInsp]::HidD_GetPreparsedData($h, [ref]$pp)) {
    $caps = New-Object byte[] 64
    if ([HidInsp]::HidP_GetCaps($pp, $caps) -eq 0x00110000) {
      Write-Host ("  usagePage=0x{0:X4}  usage=0x{1:X4}" -f (Get-U16 $caps 2), (Get-U16 $caps 0))
      Write-Host ("  inLen={0}  outLen={1}  featureLen={2}" -f (Get-U16 $caps 4), (Get-U16 $caps 6), (Get-U16 $caps 8))
      Write-Host ("  caps: inBtn={0} inVal={1} outBtn={2} outVal={3} featBtn={4} featVal={5} collections={6}" -f `
        (Get-U16 $caps 46), (Get-U16 $caps 48), (Get-U16 $caps 52), (Get-U16 $caps 54), `
        (Get-U16 $caps 58), (Get-U16 $caps 60), (Get-U16 $caps 44))
    }
    [void][HidInsp]::HidD_FreePreparsedData($pp)
  }

  # report descriptor
  $desc = New-Object byte[] 4096
  $ret = 0
  if ([HidInsp]::DeviceIoControl($h, $IOCTL_GET_REPORT_DESCRIPTOR, $null, 0, $desc, 4096, [ref]$ret, [IntPtr]::Zero)) {
    $real = $desc[0..([Math]::Max(0, $ret - 1))]
    Write-Host ("  report descriptor: {0} byte" -f $ret)
    $parsed = Parse-Descriptor $real
    foreach ($p in ($parsed | Sort-Object ReportID, Kind)) {
      Write-Host ("     reportID={0,-4} {1,-8} {2,4} bit = {3} byte" -f $p.ReportID, $p.Kind, $p.Bits, $p.Bytes)
    }
  } else {
    Write-Host "  report descriptor: gagal dibaca"
  }
  [void][HidInsp]::CloseHandle($h)
}
