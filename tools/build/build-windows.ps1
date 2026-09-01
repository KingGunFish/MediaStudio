# build-windows.ps1 - Build media_studio SDK on Windows
# Requires: CMake, MSVC (or MinGW), ffmpeg in PATH or system-installed

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sdk = Join-Path $root "sdk"
$build = Join-Path $sdk "build"

if (Test-Path $build) { Remove-Item $build -Recurse -Force }
New-Item -ItemType Directory -Path $build | Out-Null

Push-Location $build

try {
    cmake $sdk `
        -DCMAKE_BUILD_TYPE=Release `
        -DFFMPEG_EXECUTABLE="$((Get-Command ffmpeg -ErrorAction SilentlyContinue).Source ?? 'ffmpeg')" `
        -DFFPROBE_EXECUTABLE="$((Get-Command ffprobe -ErrorAction SilentlyContinue).Source ?? 'ffprobe')"
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

    cmake --build . --config Release --parallel
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

    $lib = Join-Path $build "Release\media_studio.dll"
    if (Test-Path $lib) {
        Write-Host ""
        Write-Host "Built: $lib" -ForegroundColor Green
    } else {
        throw "Build artifact not found"
    }
} finally {
    Pop-Location
}