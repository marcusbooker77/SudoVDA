param(
    [string]$VCTargetsRoot = "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Microsoft\VC\v180",
    [string]$WdkRoot = "C:\Program Files (x86)\Windows Kits\10"
)

$ErrorActionPreference = "Stop"

function Get-LatestWdkBuildFolder {
    param(
        [string]$Root
    )

    $buildRoot = Join-Path $Root "build"
    if (-not (Test-Path $buildRoot)) {
        throw "WDK build root not found: $buildRoot"
    }

    $latest = Get-ChildItem $buildRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No WDK build folder found under $buildRoot"
    }

    return $latest.Name
}

function Ensure-Administrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return
    }

    $arguments = @(
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-VCTargetsRoot", "`"$VCTargetsRoot`"",
        "-WdkRoot", "`"$WdkRoot`""
    )

    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait | Out-Null
    exit $LASTEXITCODE
}

Ensure-Administrator

$wdkBuildFolder = Get-LatestWdkBuildFolder -Root $WdkRoot
$toolsetDir = Join-Path $VCTargetsRoot "Platforms\x64\PlatformToolsets\WindowsUserModeDriver10.0"
$importAfterDir = Join-Path $toolsetDir "ImportAfter"

New-Item -ItemType Directory -Force -Path $importAfterDir | Out-Null

$toolsetProps = @"
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <WDKContentRoot Condition="'`$(WDKContentRoot)' == ''">$($WdkRoot.TrimEnd('\'))\</WDKContentRoot>
    <WDKBuildFolder Condition="'`$(WDKBuildFolder)' == ''">$wdkBuildFolder\</WDKBuildFolder>
    <WDKBinRoot Condition="'`$(WDKBinRoot)' == ''">$($WdkRoot.TrimEnd('\'))\bin\$wdkBuildFolder\</WDKBinRoot>
    <WDKBinRoot Condition="'`$(WDKBinRoot)' == ''">`$(WDKContentRoot)bin\</WDKBinRoot>
    <VisualStudioVersion Condition="'`$(VisualStudioVersion)' == '' or '`$(VisualStudioVersion)' == '18.0'">17.0</VisualStudioVersion>
    <IsUserModeToolset>true</IsUserModeToolset>
  </PropertyGroup>

  <Import Project="`$(VCTargetsPath)\Microsoft.Cpp.MSVC.Toolset.x64.props" />
  <Import Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)WindowsDriver.Default.props" />
  <Import Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)x64\WindowsUserModeDriver\WDK.x64.WindowsUserModeDriver.props" />
  <Import Project="`$(MSBuildThisFileDirectory)ImportAfter\*.props" Condition="Exists('`$(MSBuildThisFileDirectory)ImportAfter')" />
  <Import Project="`$(_PlatformFolder)Platform.Common.props" />
</Project>
"@

$toolsetTargets = @"
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Project="`$(VCTargetsPath)\Microsoft.CppCommon.targets" />
  <Import Project="`$(VCTargetsPath)\Microsoft.Cpp.WindowsSDK.targets" />
  <Import Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)WindowsDriver.Common.targets" />
  <Import Project="`$(MSBuildThisFileDirectory)ImportAfter\*.targets" Condition="Exists('`$(MSBuildThisFileDirectory)ImportAfter')" />
</Project>
"@

$wdkImportProps = @"
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Condition="'`$(IsUserModeToolset)'=='true' and Exists('`$(WDKContentRoot)DesignTime\CommonConfiguration\Neutral\WDK\`$(TargetPlatformVersion)\WDK.props')" Project="`$(WDKContentRoot)DesignTime\CommonConfiguration\Neutral\WDK\`$(TargetPlatformVersion)\WDK.props" />
  <Import Condition="'`$(IsUserModeToolset)'=='true' and '`$(ConversionToolVersion)' == '1.0'" Project="`$(WDKBinRoot)\conversion\OverrideMacros.props" />
  <Import Condition="'`$(IsUserModeToolset)'=='true'" Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)WindowsDriver.common.props" />
  <Import Condition="'`$(IsUserModeToolset)'=='true'" Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)WindowsDriver.UserMode.Default.props" />
  <Import Condition="'`$(IsUserModeToolset)'=='true'" Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)WindowsDriver.UserMode.props" />
  <Import Condition="'`$(IsUserModeToolset)'=='true' and '`$(ConversionToolVersion)' == '1.0'" Project="`$(WDKBinRoot)\conversion\Conversion.props" />
  <Import Condition="'`$(IsUserModeToolset)'=='true'" Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)WindowsDriver.UserMode.LateEvaluation.props" />
  <Import Condition="'`$(IsUserModeToolset)'=='true'" Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)WindowsDriver.LateEvaluation.props" />
</Project>
"@

$wdkImportTargets = @"
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Project="`$(WDKContentRoot)build\`$(WDKBuildFolder)x64\ImportAfter\WDK.x64.WindowsDriverCommonToolset.Platform.Targets" />
</Project>
"@

Set-Content -Path (Join-Path $toolsetDir "Toolset.props") -Value $toolsetProps -Encoding ASCII
Set-Content -Path (Join-Path $toolsetDir "Toolset.targets") -Value $toolsetTargets -Encoding ASCII
Set-Content -Path (Join-Path $importAfterDir "WDK.WindowsUserModeDriver.Platform.props") -Value $wdkImportProps -Encoding ASCII
Set-Content -Path (Join-Path $importAfterDir "WDK.WindowsDriverCommonToolset.Platform.targets") -Value $wdkImportTargets -Encoding ASCII

Write-Host "Registered WindowsUserModeDriver10.0 toolset shim under $toolsetDir"
