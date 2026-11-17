param(
    [Parameter(Mandatory = $true)]
    [string]$ApplicationName
)

# =====================================================================
# INVENTAIRE APPLICATION INTUNE
# =====================================================================

$ExportFile = "C:\Temp\$($ApplicationName)_Inventory.csv"

$RequiredScopes = @(
    "DeviceManagementApps.Read.All",
    "DeviceManagementManagedDevices.Read.All",
    "User.Read.All"
)

# ---------------------------------------------------------------------
# CONNEXION GRAPH
# ---------------------------------------------------------------------

try {

    $Context = Get-MgContext -ErrorAction SilentlyContinue

    if (-not $Context) {

        Write-Host ""
        Write-Host "Connexion à Microsoft Graph..." -ForegroundColor Cyan

        Connect-MgGraph -Scopes $RequiredScopes -NoWelcome
    }

    $Context = Get-MgContext

    Write-Host ""
    Write-Host "Connecté avec : $($Context.Account)" -ForegroundColor Green
    Write-Host ""

}
catch {

    Write-Error $_.Exception.Message
    exit

}

# ---------------------------------------------------------------------
# GESTION DU THROTTLING
# ---------------------------------------------------------------------

function Invoke-GraphWithRetry {

    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 8
    )

    $RetryCount = 0

    while ($true) {

        try {

            return (& $ScriptBlock)

        }
        catch {

            $RetryCount++

            if ($RetryCount -gt $MaxRetries) {

                Write-Warning "Nombre maximal de tentatives atteint."
                return $null

            }

            if (
                $_.Exception.Message -match "429" -or
                $_.Exception.Message -match "TooManyRequests"
            ) {

                $Delay = [Math]::Pow(2, $RetryCount)

                Write-Warning "Throttling détecté - Attente $Delay seconde(s)"

                Start-Sleep -Seconds $Delay

            }
            else {

                Write-Warning $_.Exception.Message
                return $null

            }
        }
    }
}

# ---------------------------------------------------------------------
# RECUPERATION PRIMARY USER
# ---------------------------------------------------------------------

function Get-PrimaryUser {

    param(
        [string]$ManagedDeviceId
    )

    try {

        if (-not (Get-Command Get-MgDeviceManagementManagedDeviceUser -ErrorAction SilentlyContinue)) {
            return $null
        }

        $User = Get-MgDeviceManagementManagedDeviceUser `
            -ManagedDeviceId $ManagedDeviceId |
            Select-Object -First 1

        if ($User) {
            return $User.UserPrincipalName
        }

    }
    catch {
    }

    return $null
}

# ---------------------------------------------------------------------
# CHARGEMENT DES APPAREILS
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "Chargement des appareils Intune..." -ForegroundColor Cyan

$ManagedDevices = Invoke-GraphWithRetry {
    Get-MgDeviceManagementManagedDevice -All
}

if (-not $ManagedDevices) {

    Write-Error "Impossible de récupérer les appareils Intune."
    exit

}

Write-Host "$($ManagedDevices.Count) appareils chargés." -ForegroundColor Green

# ---------------------------------------------------------------------
# INDEXATION
# ---------------------------------------------------------------------

$DeviceIndex = @{}

foreach ($Device in $ManagedDevices) {

    $DeviceIndex[$Device.Id] = $Device

}

# ---------------------------------------------------------------------
# RECHERCHE APPLICATION
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "Recherche de $ApplicationName..." -ForegroundColor Cyan

$Apps = Invoke-GraphWithRetry {
    Get-MgDeviceManagementDetectedApp -Filter "contains(displayName,'$ApplicationName')"
}

if (-not $Apps) {

    Write-Warning "Aucune application trouvée pour : $ApplicationName"
    exit

}

Write-Host "$($Apps.Count) version(s) trouvée(s)." -ForegroundColor Green

# ---------------------------------------------------------------------
# ANALYSE
# ---------------------------------------------------------------------

$Results = @()

foreach ($App in $Apps) {

    Write-Host ""
    Write-Host "Traitement : $($App.DisplayName)" -ForegroundColor Yellow

    $Devices = Invoke-GraphWithRetry {
        Get-MgDeviceManagementDetectedAppManagedDevice -DetectedAppId $App.Id
    }

    if (-not $Devices) {
        continue
    }

    foreach ($Device in $Devices) {

        if (-not $DeviceIndex.ContainsKey($Device.Id)) {
            continue
        }

        $ManagedDevice = $DeviceIndex[$Device.Id]

        $PrimaryUser = $ManagedDevice.UserPrincipalName

        if ([string]::IsNullOrWhiteSpace($PrimaryUser)) {

            $PrimaryUser = Get-PrimaryUser -ManagedDeviceId $ManagedDevice.Id

            Start-Sleep -Milliseconds 200
        }

        $Results += [PSCustomObject]@{

            Application       = $App.DisplayName
            Version           = $App.Version
            Publisher         = $App.Publisher

            DeviceName        = $ManagedDevice.DeviceName

            UserDisplayName   = $ManagedDevice.UserDisplayName
            UserPrincipalName = $ManagedDevice.UserPrincipalName
            PrimaryUser       = $PrimaryUser

            OperatingSystem   = $ManagedDevice.OperatingSystem
            ComplianceState   = $ManagedDevice.ComplianceState
            LastSyncDateTime  = $ManagedDevice.LastSyncDateTime
        }
    }
}

# ---------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------

$Results |
Sort-Object Application, DeviceName -Unique |
Export-Csv `
    -Path $ExportFile `
    -Delimiter ";" `
    -Encoding UTF8 `
    -NoTypeInformation

# ---------------------------------------------------------------------
# AFFICHAGE
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "Export terminé" -ForegroundColor Green
Write-Host "Fichier : $ExportFile" -ForegroundColor Green
Write-Host "Lignes exportées : $($Results.Count)" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green

$Results |
Sort-Object Application, DeviceName |
Format-Table Application,
             Version,
             DeviceName,
             PrimaryUser -AutoSize