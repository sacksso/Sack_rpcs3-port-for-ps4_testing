<#
.SYNOPSIS
  Compila y ejecuta los tests de host de ps4-port/tests con el clang++ de llvm-mingw.
  Requiere PowerShell 7 (usa ForEach-Object -Parallel).
.EXAMPLE
  cd rpcs3-ps4
  ./ps4-port/tools/run-host-tests.ps1 -Llvm C:/tools/llvm-mingw-20240619-ucrt-x86_64/bin
.NOTES
  Un test falla el job solo si su nombre esta en ps4-port/tests/ci-required.txt.
  El resto se informa en el resumen (PASS / FAIL-COMPILE / FAIL-RUN / TIMEOUT / SKIP).
#>
param(
    [Parameter(Mandatory)][string]$Llvm,
    [string]$Out = 'ps4-port/.host-tests',
    [int]$Jobs = 4,
    [int]$RunTimeoutSec = 120,
    [string]$Only = ''
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
Set-Location $root
$clang = (Resolve-Path (Join-Path $Llvm 'clang++.exe')).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$outAbs = (Resolve-Path $Out).Path

# Ajustes por test (las lineas de compilacion reales estan en la cabecera de cada .cpp).
# Inc: -I extra (van antes de -I rpcs3 para que los mocks tengan prioridad). Src: fuentes extra. Libs: libs. Std: estandar.
$spec = @{
    'policy_test'           = @{ Inc = @('ps4-port/tests/policy-mocks') }
    'cfg_browser_test'      = @{ Inc = @('ps4-port/tests/cfg-mocks', 'ps4-port/tests/policy-mocks') }
    'i18n_test'             = @{ Inc = @('3rdparty/stblib/stb') }
    'fenv_test'             = @{ Libs = @('-lpthread') }
    'disc_stream_test'      = @{ Src = @('rpcs3/Crypto/aes.cpp', 'rpcs3/Crypto/aesni.cpp') }
    'fs_eio_test'           = @{ Std = 'c++23' }
    'xmb_folders_test'      = @{ Std = 'c++23' }
    'xmb_media_test'        = @{ Std = 'c++23' }
    # Estos dos reciben como argumento un directorio temporal que no debe existir (lo crea el script)
    'game_library_test'     = @{ TempArg = $true }
    'ps4_directory_test'    = @{ TempArg = $true }
    'jaguar_simd_test'      = @{ Inc = @('3rdparty/asmjit/asmjit/src') }
    'overlay_audio_test'    = @{ Inc = @('ps4-port/tests/overlay-audio-mocks'); Src = @('rpcs3/Emu/RSX/Overlays/overlay_audio.cpp') }
    'virtual_memory_test'   = @{ Src = @('ps4-port/runtime/ps4_virtual_memory.cpp') }
    'shared_memory_test'    = @{ Src = @('ps4-port/runtime/ps4_virtual_memory.cpp', 'ps4-port/runtime/ps4_shared_memory.cpp') }
    'disc_key_test'         = @{ Skip = 'necesita objetos de zlib (ver cabecera del test)' }
    'patches_test'          = @{ Skip = 'necesita yaml-cpp (ver cabecera del test)' }
    'rpcn_account_test'     = @{ Skip = 'necesita wolfSSL (ver cabecera del test)' }
    'orbis_mmap_trim_test'  = @{ Skip = 'necesita orbis-compat y mocks propios (ver cabecera)' }
    'pad_slots_test'        = @{ Skip = 'se compila desde ps4-port/ con -I../rpcs3' }
    'capture_adapter_test'  = @{ Skip = 'necesita el SDK de OpenOrbis (orbis/Sysmodule.h), OpenAL y FFmpeg' }
    'usb_adapter_test'      = @{ Skip = 'necesita el SDK de OpenOrbis (orbis/Sysmodule.h) y libusb' }
}

$reqFile = 'ps4-port/tests/ci-required.txt'
$required = @()
if (Test-Path $reqFile) {
    $required = @(Get-Content $reqFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

$tests = @(Get-ChildItem 'ps4-port/tests' -Filter '*_test.cpp' | Sort-Object Name)
if ($Only) { $tests = @($tests | Where-Object { $_.BaseName -match $Only }) }
Write-Host "Tests: $($tests.Count) (requeridos: $($required.Count))"

$results = $tests | ForEach-Object -ThrottleLimit $Jobs -Parallel {
    $name = $_.BaseName
    $spec = $using:spec; $clang = $using:clang; $outAbs = $using:outAbs; $root = $using:root; $timeout = $using:RunTimeoutSec
    $s = if ($spec.ContainsKey($name)) { $spec[$name] } else { @{} }
    $r = [pscustomobject]@{ Name = $name; Status = 'PASS'; Detail = ''; Seconds = 0 }
    if ($s.ContainsKey('Skip')) { $r.Status = 'SKIP'; $r.Detail = $s.Skip; return $r }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exe = Join-Path $outAbs "$name.exe"
    $log = Join-Path $outAbs "$name.compile.log"
    $std = if ($s.ContainsKey('Std')) { $s.Std } else { 'c++20' }
    $cargs = @("-std=$std", '-O1', '-static', '-Wall', '-Wextra')
    foreach ($i in @($s.Inc)) { if ($i) { $cargs += @('-I', $i) } }
    $cargs += @('-I', 'rpcs3', '-I', '.', "ps4-port/tests/$name.cpp")
    foreach ($x in @($s.Src)) { if ($x) { $cargs += $x } }
    $cargs += @('-o', $exe)
    foreach ($l in @($s.Libs)) { if ($l) { $cargs += $l } }
    Push-Location $root
    try {
        & $clang @cargs *> $log
        if ($LASTEXITCODE -ne 0) {
            $r.Status = 'FAIL-COMPILE'
            $err = Select-String -Path $log -Pattern 'error' -SimpleMatch | Select-Object -First 1
            $r.Detail = if ($err) { $err.Line.Trim() } else { 'ver ' + "$name.compile.log" }
        } else {
            $ro = Join-Path $outAbs "$name.run.out.log"; $re = Join-Path $outAbs "$name.run.err.log"
            $sp = @{ FilePath = $exe; WorkingDirectory = $root; PassThru = $true; NoNewWindow = $true; RedirectStandardOutput = $ro; RedirectStandardError = $re }
            if ($s.ContainsKey('TempArg')) {
                $fx = Join-Path $outAbs "fixture-$name"
                if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
                $sp.ArgumentList = "`"$fx`""
            }
            $p = Start-Process @sp
            if (-not $p.WaitForExit($timeout * 1000)) {
                try { $p.Kill($true) } catch {}
                $r.Status = 'TIMEOUT'; $r.Detail = "mas de $timeout s"
            } else {
                $p.WaitForExit()
                if ($p.ExitCode -ne 0) {
                    $r.Status = 'FAIL-RUN'
                    $last = @(Get-Content $re, $ro -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }) | Select-Object -Last 1
                    $r.Detail = "exit $($p.ExitCode): $last"
                }
            }
        }
    } finally { Pop-Location }
    $r.Seconds = [int]$sw.Elapsed.TotalSeconds
    return $r
}

$results = @($results | Sort-Object Name)
$fence = '```'
$md = [Text.StringBuilder]::new()
[void]$md.AppendLine('## Tests de host')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Test | Estado | s | Detalle |')
[void]$md.AppendLine('| --- | --- | --- | --- |')
foreach ($r in $results) {
    $req = if ($required -contains $r.Name) { ' (req)' } else { '' }
    $d = ($r.Detail -replace '\|', '/')
    if ($d.Length -gt 160) { $d = $d.Substring(0, 160) + '...' }
    [void]$md.AppendLine("| $($r.Name)$req | $($r.Status) | $($r.Seconds) | $d |")
}
$groups = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
[void]$md.AppendLine('')
[void]$md.AppendLine("Totales: $($groups -join ', ')")
$text = $md.ToString()
Set-Content -Path (Join-Path $outAbs 'summary.md') -Value $text -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $text }
Write-Host $text

$bad = @($results | Where-Object { $required -contains $_.Name -and $_.Status -ne 'PASS' })
if ($bad.Count) {
    Write-Host "Fallan tests requeridos: $($bad.Name -join ', ')"
    exit 1
}
exit 0
