$app = Get-MgDeviceManagementDetectedApp -Filter "contains(displayName,'Zalo')" | Export-Csv -Delimiter "," -Path "c:\temp\ZaloAppList.csv" -notypeinformation

# Import du fichier des applications Zalo
$apps = Import-Csv "C:\Temp\ZaloAppList.csv"

# Fonction de gestion du throttling Graph
function Invoke-GraphWithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 8
    )

    $RetryCount = 0

    do {
        try {
            return & $ScriptBlock
        }
        catch {

            $ErrorMessage = $_.Exception.Message

            if ($ErrorMessage -match "TooManyRequests|429") {

                $RetryCount++

                if ($RetryCount -gt $MaxRetries) {
                    Write-Warning "Nombre maximum de tentatives atteint."
                    return $null
                }

                # Backoff exponentiel
                $Delay = [math]::Pow(2, $RetryCount)

                Write-Warning "Throttling détecté. Tentative $RetryCount/$MaxRetries. Pause de $Delay secondes..."

                Start-Sleep -Seconds $Delay
            }
            else {
                Write-Warning "Erreur : $ErrorMessage"
                return $null
            }
        }
    }
    while ($true)
}

# Collecte des données
$result = foreach ($app in $apps) {

    Write-Host "Traitement : $($app.DisplayName)" -ForegroundColor Cyan

    $devices = Invoke-GraphWithRetry {
        Get-MgDeviceManagementDetectedAppManagedDevice `
            -DetectedAppId $app.Id
    }

    foreach ($device in $devices) {

        Start-Sleep -Milliseconds 250

        $managedDevice = Invoke-GraphWithRetry {
            Get-MgDeviceManagementManagedDevice `
                -ManagedDeviceId $device.Id
        }

        if ($managedDevice) {

            [PSCustomObject]@{
                Application       = $app.DisplayName
                Version           = $app.Version
                DeviceName        = $managedDevice.DeviceName
                UserPrincipalName = $managedDevice.UserPrincipalName
                UserDisplayName   = $managedDevice.UserDisplayName
                OperatingSystem   = $managedDevice.OperatingSystem
            }
        }
    }
}

# Suppression des doublons
$result |
Sort-Object Application, DeviceName -Unique |
Export-Csv "C:\Temp\Zalo_Users_Devices.csv" `
-NoTypeInformation `
-Encoding UTF8

Write-Host ""
Write-Host "Export terminé : C:\Temp\Zalo_Users_Devices.csv" -ForegroundColor Green
