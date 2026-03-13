param(
    [string]$Configuration = "Release",
    [string]$Platform = "x64",
    [switch]$EnablePackageVerification
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repoRoot "Virtual Display Driver (HDR)\SudoVDA\SudoVDA.vcxproj"
$registerScript = Join-Path $PSScriptRoot "Register-WDKToolset.ps1"
$msbuildPath = "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe"

if (-not (Test-Path $projectPath)) {
    throw "Driver project not found: $projectPath"
}

& powershell -ExecutionPolicy Bypass -File $registerScript
if ($LASTEXITCODE -ne 0) {
    throw "WDK toolset registration failed"
}

$msbuildArgs = @(
    $projectPath
    "/p:Configuration=$Configuration"
    "/p:Platform=$Platform"
    "/p:VisualStudioVersion=17.0"
    "/p:WindowsTargetPlatformVersion=10.0.26100.0"
    "/p:TargetPlatformVersion=10.0.26100.0"
    "/m"
    "/nologo"
)

if (-not $EnablePackageVerification) {
    $msbuildArgs += "/p:SkipPackageVerification=true"
}

& $msbuildPath @msbuildArgs
exit $LASTEXITCODE
