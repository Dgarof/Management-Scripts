Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =====================================================================
# CONFIGURATION
# =====================================================================

$RequiredScopes = @(
    "DeviceManagementApps.Read.All",
    "DeviceManagementManagedDevices.Read.All",
    "User.Read.All"
)

$Global:Results = @()

# =====================================================================
# INTERFACE
# =====================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "Inventaire Application Intune"
$form.Size = New-Object System.Drawing.Size(1200,750)
$form.StartPosition = "CenterScreen"

# Label

$lblApp = New-Object System.Windows.Forms.Label
$lblApp.Location = New-Object System.Drawing.Point(20,20)
$lblApp.Size = New-Object System.Drawing.Size(140,20)
$lblApp.Text = "Nom application :"
$form.Controls.Add($lblApp)

# Textbox

$txtApp = New-Object System.Windows.Forms.TextBox
$txtApp.Location = New-Object System.Drawing.Point(160,18)
$txtApp.Size = New-Object System.Drawing.Size(300,23)
$form.Controls.Add($txtApp)

# Bouton recherche

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Location = New-Object System.Drawing.Point(480,15)
$btnSearch.Size = New-Object System.Drawing.Size(120,30)
$btnSearch.Text = "Rechercher"
$form.Controls.Add($btnSearch)

# Bouton export

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Location = New-Object System.Drawing.Point(620,15)
$btnExport.Size = New-Object System.Drawing.Size(120,30)
$btnExport.Text = "Exporter CSV"
$form.Controls.Add($btnExport)

# ProgressBar

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(20,60)
$progress.Size = New-Object System.Drawing.Size(1140,20)
$form.Controls.Add($progress)

# DataGrid

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(20,90)
$grid.Size = New-Object System.Drawing.Size(1140,500)
$grid.AutoSizeColumnsMode = "DisplayedCells"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$form.Controls.Add($grid)

# Log

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20,610)
$txtLog.Size = New-Object System.Drawing.Size(1140,90)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$form.Controls.Add($txtLog)

# =====================================================================
# LOG
# =====================================================================

function Write-GuiLog {

    param([string]$Message)

    $txtLog.AppendText(
        "$(Get-Date -Format 'HH:mm:ss') - $Message`r`n"
    )

    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()

    [System.Windows.Forms.Application]::DoEvents()
}

# =====================================================================
# GRAPH RETRY
# =====================================================================

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

                Write-GuiLog "Nombre maximal de tentatives atteint"
                return $null
            }

            if (
                $_.Exception.Message -match "429" -or
                $_.Exception.Message -match "TooManyRequests"
            ) {

                $Delay = [int][Math]::Pow(2, $RetryCount)

                Write-GuiLog "Throttling détecté. Attente $Delay seconde(s)"

                Start-Sleep -Seconds $Delay

            }
            else {

                Write-GuiLog $_.Exception.Message
                return $null
            }
        }
    }
}

# =====================================================================
# PRIMARY USER
# =====================================================================

function Get-PrimaryUser {

    param(
        [string]$ManagedDeviceId
    )

    try {

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

# =====================================================================
# INVENTAIRE
# =====================================================================

function Start-Inventory {

    param(
        [string]$ApplicationName
    )

    $Results = @()

    try {

        $Context = Get-MgContext -ErrorAction SilentlyContinue

        if (-not $Context) {

            Write-GuiLog "Connexion Microsoft Graph..."

            Connect-MgGraph `
                -Scopes $RequiredScopes `
                -NoWelcome
        }

        $Context = Get-MgContext

        Write-GuiLog "Connecté : $($Context.Account)"

    }
    catch {

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Erreur Graph"
        )

        return
    }

    Write-GuiLog "Chargement des appareils Intune..."

    $ManagedDevices = Invoke-GraphWithRetry {

        Get-MgDeviceManagementManagedDevice -All
    }

    if (-not $ManagedDevices) {

        Write-GuiLog "Impossible de charger les appareils"

        return
    }

    Write-GuiLog "$($ManagedDevices.Count) appareils chargés"

    $DeviceIndex = @{}

    foreach ($Device in $ManagedDevices) {

        $DeviceIndex[$Device.Id] = $Device
    }

    Write-GuiLog "Recherche de $ApplicationName"

    $Apps = Invoke-GraphWithRetry {

        Get-MgDeviceManagementDetectedApp `
            -Filter "contains(displayName,'$ApplicationName')"
    }

    if (-not $Apps) {

        Write-GuiLog "Aucune application trouvée"

        return
    }

    Write-GuiLog "$($Apps.Count) version(s) trouvée(s)"

    $Current = 0
    $Total = $Apps.Count

    foreach ($App in $Apps) {

        $Current++

        $Percent = ($Current / $Total * 100)

        if ($Percent -gt 100) {
            $Percent = 100
        }

        $progress.Value = $Percent

        [System.Windows.Forms.Application]::DoEvents()

        Write-GuiLog "Traitement : $($App.DisplayName) $($App.Version)"

        $Devices = Invoke-GraphWithRetry {

            Get-MgDeviceManagementDetectedAppManagedDevice `
                -DetectedAppId $App.Id
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

                $PrimaryUser = Get-PrimaryUser `
                    -ManagedDeviceId $ManagedDevice.Id
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

    $progress.Value = 100

    return $Results |
           Sort-Object Application,DeviceName -Unique
}

# =====================================================================
# EVENEMENTS
# =====================================================================

$btnSearch.Add_Click({

    if ([string]::IsNullOrWhiteSpace($txtApp.Text)) {

        [System.Windows.Forms.MessageBox]::Show(
            "Veuillez saisir un nom d'application."
        )

        return
    }

    $txtLog.Clear()
    $grid.DataSource = $null
    $progress.Value = 0

    $Global:Results = Start-Inventory `
        -ApplicationName $txtApp.Text

    if ($Global:Results) {

        $grid.DataSource = $Global:Results

        Write-GuiLog "$($Global:Results.Count) lignes chargées"
    }
})

$btnExport.Add_Click({

    if (-not $Global:Results) {

        [System.Windows.Forms.MessageBox]::Show(
            "Aucun résultat à exporter."
        )

        return
    }

    $SaveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $SaveDialog.Filter = "CSV (*.csv)|*.csv"

    $SaveDialog.FileName = "$($txtApp.Text)_Inventory.csv"

    if ($SaveDialog.ShowDialog() -eq "OK") {

        $Global:Results |
        Export-Csv `
            -Path $SaveDialog.FileName `
            -Delimiter ";" `
            -NoTypeInformation `
            -Encoding UTF8

        Write-GuiLog "Export terminé : $($SaveDialog.FileName)"

        [System.Windows.Forms.MessageBox]::Show(
            "Export terminé."
        )
    }
})

$grid.Add_CellDoubleClick({

    param($sender,$event)

    if ($event.RowIndex -ge 0) {

        $DeviceName = $grid.Rows[$event.RowIndex].Cells["DeviceName"].Value

        [System.Windows.Forms.Clipboard]::SetText($DeviceName)

        [System.Windows.Forms.MessageBox]::Show(
            "Nom du poste copié : $DeviceName"
        )
    }
})

# =====================================================================
# DEMARRAGE
# =====================================================================

[void]$form.ShowDialog()