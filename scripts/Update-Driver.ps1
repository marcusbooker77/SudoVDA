param(
    [string]$Configuration = "Release",
    [string]$Platform = "x64",
    [switch]$SkipBuild,
    [switch]$KeepOldPackages,
    [switch]$RunSmokeTest,
    [switch]$EnablePackageVerification
)

$ErrorActionPreference = "Stop"

function Ensure-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return
    }

    $arguments = @(
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Configuration", "`"$Configuration`"",
        "-Platform", "`"$Platform`""
    )

    if ($SkipBuild) {
        $arguments += "-SkipBuild"
    }
    if ($KeepOldPackages) {
        $arguments += "-KeepOldPackages"
    }
    if ($RunSmokeTest) {
        $arguments += "-RunSmokeTest"
    }
    if ($EnablePackageVerification) {
        $arguments += "-EnablePackageVerification"
    }

    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait | Out-Null
    exit $LASTEXITCODE
}

function Get-SudoVdaPublishedNames {
    $driverOutput = pnputil /enum-drivers /class Display
    $publishedNames = New-Object System.Collections.Generic.List[string]
    $currentPublishedName = $null
    $isSudoVdaBlock = $false

    foreach ($line in $driverOutput) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($isSudoVdaBlock -and $currentPublishedName) {
                $publishedNames.Add($currentPublishedName)
            }
            $currentPublishedName = $null
            $isSudoVdaBlock = $false
            continue
        }

        if ($line -match '^\s*Published Name:\s+(oem\d+\.inf)\s*$') {
            $currentPublishedName = $matches[1]
            continue
        }

        if ($line -match '^\s*Original Name:\s+sudovda\.inf\s*$') {
            $isSudoVdaBlock = $true
        }
    }

    if ($isSudoVdaBlock -and $currentPublishedName) {
        $publishedNames.Add($currentPublishedName)
    }

    return $publishedNames
}

function Get-ActiveSudoVdaPublishedName {
    $deviceOutput = pnputil /enum-devices /class Display /deviceids
    $inSudoVdaBlock = $false

    foreach ($line in $deviceOutput) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $inSudoVdaBlock = $false
            continue
        }

        if ($line -match '^\s*Device Description:\s+SudoMaker Virtual Display Adapter\s*$') {
            $inSudoVdaBlock = $true
            continue
        }

        if ($inSudoVdaBlock -and $line -match '^\s*Driver Name:\s+(oem\d+\.inf)\s*$') {
            return $matches[1]
        }
    }

    return $null
}

function Get-SudoVdaDriverVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PublishedName
    )

    $driverOutput = pnputil /enum-drivers /class Display
    $currentPublishedName = $null
    $isTargetBlock = $false

    foreach ($line in $driverOutput) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $currentPublishedName = $null
            $isTargetBlock = $false
            continue
        }

        if ($line -match '^\s*Published Name:\s+(oem\d+\.inf)\s*$') {
            $currentPublishedName = $matches[1]
            $isTargetBlock = $currentPublishedName -ieq $PublishedName
            continue
        }

        if ($isTargetBlock -and $line -match '^\s*Driver Version:\s+(.+?)\s*$') {
            return $matches[1]
        }
    }

    return $null
}

function Get-InfDriverVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $match = Select-String -Path $Path -Pattern '^\s*DriverVer\s*=\s*(.+?)\s*$' | Select-Object -First 1
    if (-not $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

Ensure-Administrator

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot "Build-Driver.ps1"
$releaseRoot = Join-Path $repoRoot "Virtual Display Driver (HDR)\SudoVDA\$Platform\$Configuration"
$packageDir = Join-Path $releaseRoot "SudoVDA"
$packageInf = Join-Path $packageDir "SudoVDA.inf"
$certPath = Join-Path $releaseRoot "SudoVDA.cer"

if (-not $SkipBuild) {
    $buildArguments = @(
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$buildScript`"",
        "-Configuration", "`"$Configuration`"",
        "-Platform", "`"$Platform`""
    )
    if ($EnablePackageVerification) {
        $buildArguments += "-EnablePackageVerification"
    }

    & powershell @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Driver build failed"
    }
}

if (-not (Test-Path $packageInf)) {
    throw "Built driver INF not found: $packageInf"
}

if (-not (Test-Path $certPath)) {
    throw "Built driver certificate not found: $certPath"
}

Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

$expectedDriverVersion = Get-InfDriverVersion -Path $packageInf
pnputil /add-driver $packageInf /install

$activePublishedName = Get-ActiveSudoVdaPublishedName
if (-not $activePublishedName) {
    throw "Unable to determine the active SudoVDA driver package"
}

$activeDriverVersion = Get-SudoVdaDriverVersion -PublishedName $activePublishedName
if ($expectedDriverVersion -and $activeDriverVersion -and $activeDriverVersion -ne $expectedDriverVersion) {
    Write-Host "Refreshing active SudoVDA package $activePublishedName to pick up built version $expectedDriverVersion"
    pnputil /delete-driver $activePublishedName /uninstall /force
    pnputil /add-driver $packageInf /install

    $activePublishedName = Get-ActiveSudoVdaPublishedName
    if (-not $activePublishedName) {
        throw "Unable to determine the active SudoVDA driver package after refresh"
    }

    $activeDriverVersion = Get-SudoVdaDriverVersion -PublishedName $activePublishedName
}

if (-not $KeepOldPackages) {
    $publishedNames = Get-SudoVdaPublishedNames
    foreach ($publishedName in $publishedNames) {
        if ($publishedName -eq $activePublishedName) {
            continue
        }

        Write-Host "Removing stale SudoVDA package $publishedName"
        pnputil /delete-driver $publishedName /uninstall /force
    }
}

if ($RunSmokeTest) {
    $controllerSmoke = Join-Path (Split-Path -Parent $repoRoot) "SudoVdaController\scripts\ControllerSmoke.ps1"
    if (-not (Test-Path $controllerSmoke)) {
        throw "Controller smoke script not found: $controllerSmoke"
    }

    & powershell -ExecutionPolicy Bypass -File $controllerSmoke -SkipBuild
    if ($LASTEXITCODE -ne 0) {
        throw "Controller smoke test failed"
    }
}

if ($activeDriverVersion) {
    Write-Host "Active SudoVDA driver version: $activeDriverVersion"
}
Write-Host "Active SudoVDA driver package: $activePublishedName"
