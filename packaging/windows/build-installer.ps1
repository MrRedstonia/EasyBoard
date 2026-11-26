<#
 Builds the Windows installer.

 Needs: Rust, Qt 6 (msvc2022_64), Inno Setup 6.6 or newer (ISCC.exe) and the minimal LGPL ffmpeg.exe
 (build it with packaging/ffmpeg/build-ffmpeg.sh in an MSYS2 MINGW64 shell).

 Usage (PowerShell, from the project root):
   .\packaging\windows\build-installer.ps1 -QtBin C:\Qt\6.12.0\msvc2022_64\bin `
       -Ffmpeg C:\path\to\ffmpeg.exe
 Result: dist\EasyBoard-<version>-setup.exe
#>
param(
  [Parameter(Mandatory)] [string]$QtBin,
  [Parameter(Mandatory)] [string]$Ffmpeg,
  [string]$Iscc = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
)
$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path "$PSScriptRoot\..\..")

$version = (Select-String -Path Cargo.toml -Pattern '^version\s*=\s*"(.+)"' | Select-Object -First 1).Matches.Groups[1].Value
Write-Host "EasyBoard $version"

cargo build --release
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$stage = "dist\EasyBoard"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item target\release\easyboard.exe $stage
Copy-Item $Ffmpeg "$stage\ffmpeg.exe"
Copy-Item LICENSE, THIRD-PARTY.md $stage

# Copies the Qt DLLs, plugins and the QML modules the app imports next to the exe.
& "$QtBin\windeployqt.exe" --release --qmldir qml --no-translations "$stage\easyboard.exe"
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed" }

if (-not (Test-Path $Iscc)) {
  # any installed version (6, 7, ...), newest first
  $found = @("$env:LOCALAPPDATA\Programs", "C:\Program Files", "C:\Program Files (x86)") |
    ForEach-Object { Get-ChildItem -Path $_ -Directory -Filter "Inno Setup *" -ErrorAction SilentlyContinue } |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName "ISCC.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $found) { $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue; if ($cmd) { $found = $cmd.Source } }
  if (-not $found) { throw "Inno Setup was not found. Install it from https://jrsoftware.org/isdl.php or pass its location with -Iscc `"C:\...\ISCC.exe`"" }
  $Iscc = $found
}
& $Iscc "/DAppVersion=$version" packaging\windows\easyboard.iss
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
Write-Host "Done: dist\EasyBoard-$version-setup.exe"
