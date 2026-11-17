# =====================================================================
# INVENTAIRE ZALO - INTUNE
# Version : 1.0
# Auteur : D. Garofoli
# =====================================================================

# ---------------------------------------------------------------------
# VARIABLES
# ---------------------------------------------------------------------



$ExportFile = "C:\Temp\Zalo_Inventory.csv"

$RequiredScopes = @(
    "DeviceManagementApps.Read.All",
    "DeviceManagementManagedDevices.Read.All",
    "User.Read.All"
)

# ---------------------------------------------------------------------
# CONNEXION MICROSOFT GRAPH
# ---------------------------------------------------------------------

try {

    $Context = Get-MgContext -ErrorAction SilentlyContinue

    if (-not $Context) {

        Write-Host ""
        Write-Host "Connexion à Microsoft Graph..." -ForegroundColor Cyan

        Connect-MgGraph `
            -Scopes $RequiredScopes `
            -NoWelcome
    }

    $Context = Get-MgContext

    Write-Host ""
    Write-Host "Connecté avec : $($Context.Account)" -ForegroundColor Green
    Write-Host ""

}
catch {

    Write-Error $_.Exception.Message
    Break

}

# ---------------------------------------------------------------------
# GESTION DU THROTTLING GRAPH
# ---------------------------------------------------------------------

function Invoke-GraphWithRetry {

    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 8
    )

    $RetryCount = 0

    while ($true) {

        try {

            return & $ScriptBlock

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

                $Delay = [Math]::Pow(2,$RetryCount)

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
# FONCTION PRIMARY USER
# ---------------------------------------------------------------------

function Get-PrimaryUser {

    param(
        [string]$ManagedDeviceId
    )

    try {

        $User = Get-MgDeviceManagementManagedDeviceUser `
            -ManagedDeviceId $ManagedDeviceId `
            -ErrorAction Stop |
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
# CHARGEMENT DES APPAREILS INTUNE
# ---------------------------------------------------------------------

Write-Host "Chargement des appareils Intune..." -ForegroundColor Cyan

$ManagedDevices = Invoke-GraphWithRetry {

    Get-MgDeviceManagementManagedDevice -All

}

if (-not $ManagedDevices) {

    Write-Error "Impossible de récupérer les appareils Intune."
    Break

}

Write-Host "$($ManagedDevices.Count) appareils chargés." -ForegroundColor Green

# ---------------------------------------------------------------------
# INDEXATION DES APPAREILS
# ---------------------------------------------------------------------

$DeviceIndex = @{}

foreach ($Device in $ManagedDevices) {

    $DeviceIndex[$Device.Id] = $Device

}

# ---------------------------------------------------------------------
# RECHERCHE DES APPLICATIONS ZALO
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "Recherche des applications Zalo..." -ForegroundColor Cyan

$Apps = Invoke-GraphWithRetry {

    Get-MgDeviceManagementDetectedApp `
        -Filter "contains(displayName,'Zalo')"

}

if (-not $Apps) {

    Write-Warning "Aucune application Zalo trouvée."
    Break

}

Write-Host "$($Apps.Count) version(s) trouvée(s)." -ForegroundColor Green

# ---------------------------------------------------------------------
# ANALYSE
# ---------------------------------------------------------------------

$Results = foreach ($App in $Apps) {

    Write-Host ""
    Write-Host "Traitement : $($App.DisplayName)" -ForegroundColor Yellow

    $Devices = Invoke-GraphWithRetry {

        Get-MgDeviceManagementDetectedAppManagedDevice `
            -DetectedAppId $App.Id

    }

    foreach ($Device in $Devices) {

        if (-not $DeviceIndex.ContainsKey($Device.Id)) {
            continue
        }

        $ManagedDevice = $DeviceIndex[$Device.Id]

        # ---------------------------------
        # PRIMARY USER
        # ---------------------------------

        $PrimaryUser = $ManagedDevice.UserPrincipalName

        if ([string]::IsNullOrWhiteSpace($PrimaryUser)) {

            $PrimaryUser = Get-PrimaryUser `
                -ManagedDeviceId $ManagedDevice.Id

            Start-Sleep -Milliseconds 200

        }

        # ---------------------------------
        # RESULTAT
        # ---------------------------------

        [PSCustomObject]@{

            Application          = $App.DisplayName
            Version              = $App.Version
            Publisher            = $App.Publisher

            DeviceName           = $ManagedDevice.DeviceName

            UserPrincipalName    = $ManagedDevice.UserPrincipalName
            UserDisplayName      = $ManagedDevice.UserDisplayName

            PrimaryUser          = $PrimaryUser

            OperatingSystem      = $ManagedDevice.OperatingSystem
            ComplianceState      = $ManagedDevice.ComplianceState

            LastSyncDateTime     = $ManagedDevice.LastSyncDateTime
        }
    }
}

# ---------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------

$Results |
Sort-Object Application,DeviceName -Unique |
Export-Csv `
    -Path $ExportFile `
    -Encoding UTF8 `
    -Delimiter ";" `
    -NoTypeInformation

# ---------------------------------------------------------------------
# RESUME
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "==========================" -ForegroundColor Green
Write-Host "Export terminé" -ForegroundColor Green
Write-Host "Fichier : $ExportFile" -ForegroundColor Green
Write-Host "==========================" -ForegroundColor Green
Write-Host ""

$Results |
Group-Object Application |
Sort-Object Count -Descending |
Format-Table Count,Name -AutoSize