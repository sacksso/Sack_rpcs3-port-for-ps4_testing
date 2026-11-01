<#
  Prepara el entorno de build en un runner Windows (idempotente: lo que ya existe, no se vuelve a bajar).
  Layout resultante (el que pide BUILDING.md):
    <Root>/rpcs3-ps4, <Root>/orbis-compat            (el repo)
    <Root>/orbis-porting-kit                          (commit fijado)
    <Root>/orbis-mesa-bundle/orbis-mesa-4c934ebf9cda  (bundle de Mesa PS4)
    <Tools>/llvm-mingw-20240619-ucrt-x86_64, <Tools>/PS4Toolchain
  Necesita 'gh' con GH_TOKEN (viene en los runners de GitHub).
#>
param(
    [string]$Root = 'C:/w',
    [string]$Tools = 'C:/tools'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Invoke-Checked([string]$What, [scriptblock]$Block) {
    $global:LASTEXITCODE = 0
    & $Block
    if ($LASTEXITCODE) { throw "$What fallo (exit $LASTEXITCODE)" }
}
New-Item -ItemType Directory -Force $Tools | Out-Null
$repo = "$Root/rpcs3-ps4"

# 1. llvm-mingw 20240619 (clang/lld para los objetos de consola y los tests de host)
$llvmDir = "$Tools/llvm-mingw-20240619-ucrt-x86_64"
if (-not (Test-Path "$llvmDir/bin/clang++.exe")) {
    Write-Host '== llvm-mingw'
    $zip = "$Tools/llvm-mingw.zip"
    Invoke-WebRequest 'https://github.com/mstorsjo/llvm-mingw/releases/download/20240619/llvm-mingw-20240619-ucrt-x86_64.zip' -OutFile $zip
    Invoke-Checked 'tar llvm-mingw' { tar -xf $zip -C $Tools }
    Remove-Item $zip
}

# 2. OpenOrbis PS4 Toolchain v0.5.4 (el asset se elige solo: primer .zip de la release)
$sdk = "$Tools/PS4Toolchain"
if (-not (Test-Path "$sdk/link.x")) {
    Write-Host '== OpenOrbis PS4 Toolchain v0.5.4'
    $dl = "$Tools/oo-dl"
    New-Item -ItemType Directory -Force $dl | Out-Null
    $names = @(gh release view v0.5.4 -R OpenOrbis/OpenOrbis-PS4-Toolchain --json assets --jq '.assets[].name')
    Write-Host "Assets de la release:`n$($names -join "`n")"
    $pick = $names | Where-Object { $_ -match '\.zip$' } | Select-Object -First 1
    if (-not $pick) { $pick = $names | Where-Object { $_ -match '\.(tar\.gz|tgz)$' } | Select-Object -First 1 }
    if (-not $pick) { throw 'La release v0.5.4 de OpenOrbis no tiene un .zip/.tar.gz utilizable' }
    Invoke-Checked 'gh download OpenOrbis' { gh release download v0.5.4 -R OpenOrbis/OpenOrbis-PS4-Toolchain -p $pick -D $dl --clobber }
    Invoke-Checked 'extraer OpenOrbis' { tar -xf "$dl/$pick" -C $dl }
    $link = Get-ChildItem $dl -Recurse -Filter link.x -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $link) { throw 'No encontre link.x dentro del paquete de OpenOrbis' }
    Move-Item $link.DirectoryName $sdk
    Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($need in 'include/orbis', 'lib/libc++.a', 'samples/hello_world/sce_sys/about/right.sprx') {
    if (-not (Test-Path "$sdk/$need")) { Write-Warning "OpenOrbis: falta $need (el build puede fallar)" }
}

# 3. orbis-porting-kit (commit fijado)
$kit = "$Root/orbis-porting-kit"
if (-not (Test-Path "$kit/.git")) {
    Write-Host '== orbis-porting-kit'
    Invoke-Checked 'clone porting-kit' { git clone --quiet https://github.com/orbis-ports/orbis-porting-kit.git $kit }
    Invoke-Checked 'checkout porting-kit' { git -C $kit checkout --quiet 213b0c38ff25ea7ca402c8844a6494086d0f1cae }
}

# 4. Bundle de Mesa PS4
$mesaRoot = "$Root/orbis-mesa-bundle"
$mesa = "$mesaRoot/orbis-mesa-4c934ebf9cda"
if (-not (Test-Path $mesa)) {
    Write-Host '== Mesa PS4 bundle'
    $tmp = "$Tools/mesa-dl"
    New-Item -ItemType Directory -Force "$tmp/x" | Out-Null
    gh release download orbis-mesa-4c934ebf9cda -R orbis-ports/mesa-ps4 -p 'orbis-mesa-4c934ebf9cda.tar.gz' -D $tmp --clobber
    if ($LASTEXITCODE) {
        gh release list -R orbis-ports/mesa-ps4 --limit 10
        throw 'No pude bajar el bundle de Mesa (tag orbis-mesa-4c934ebf9cda); revisa la lista de releases de arriba'
    }
    tar -xzf "$tmp/orbis-mesa-4c934ebf9cda.tar.gz" -C "$tmp/x"
    if ($LASTEXITCODE) { Write-Warning "tar de Mesa devolvio $LASTEXITCODE (puede ser por enlaces simbolicos); sigo si existe el contenido" }
    New-Item -ItemType Directory -Force $mesaRoot | Out-Null
    $entries = @(Get-ChildItem "$tmp/x")
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { Move-Item $entries[0].FullName $mesa } else { Move-Item "$tmp/x" $mesa }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# 5. Pin de LLVM como gitlink (BUILDING.md paso 3): el arbol del port debe ser un work tree git
if (-not (Test-Path "$repo/.git")) {
    Write-Host '== gitlink del submodulo LLVM'
    Push-Location $repo
    try {
        git init -q
        git update-index --add --cacheinfo '160000,ca7933e47d3a3451d81e72ac174dcb5aa28b59d1,3rdparty/llvm/llvm'
        git -c user.name=ci -c user.email=ci@localhost commit -q -m "Record RPCS3's LLVM submodule pin"
        if ($LASTEXITCODE) { throw 'git commit del pin fallo' }
    } finally { Pop-Location }
}

# 6. Dependencias fijadas: Abseil, GNU Make, Ninja
Write-Host '== Abseil / Make / Ninja'
& "$repo/ps4-port/prepare-abseil.ps1"
& "$repo/ps4-port/prepare-make.ps1"
$ninjaDst = "$repo/ps4-port/.build-tools/ninja.exe"
if (-not (Test-Path $ninjaDst)) {
    $nz = "$Tools/ninja-win.zip"
    Invoke-WebRequest 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip' -OutFile $nz
    Expand-Archive $nz "$Tools/ninja" -Force
    Copy-Item "$Tools/ninja/ninja.exe" $ninjaDst
}

# Variables para los pasos siguientes
if ($env:GITHUB_ENV) {
    Add-Content $env:GITHUB_ENV "SDK=$sdk"
    Add-Content $env:GITHUB_ENV "LLVM_BIN=$llvmDir/bin"
    Add-Content $env:GITHUB_ENV 'DOTNET_ROLL_FORWARD=Major'
    Add-Content $env:GITHUB_ENV "OO_PS4_TOOLCHAIN=$sdk"
}
Write-Host "Listo. SDK=$sdk LLVM_BIN=$llvmDir/bin"
