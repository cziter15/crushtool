Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath   = Join-Path (Split-Path -Parent $scriptDir) "crush.json"
$crushtoolPath= Join-Path $scriptDir "crushtool.ps1"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Test-Crush {
    try {
        $result = Get-Command crush -ErrorAction SilentlyContinue
        if ($result) { return $true, $result.Source }
        return $false, "Not found in PATH"
    } catch {
        return $false, "Error: $_"
    }
}

function Get-CrushConfig {
    if (Test-Path $configPath) {
        try { return Get-Content $configPath -Raw | ConvertFrom-Json } catch { }
    }
    return $null
}

function Get-ProviderInfo {
    $config = Get-CrushConfig
    if ($config -and $config.providers) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $config.providers.PSObject.Properties) {
            $list.Add([PSCustomObject]@{
                Name       = $p.Name
                Type       = if ($p.Value.type)     { $p.Value.type }     else { "N/A" }
                BaseUrl    = if ($p.Value.base_url)  { $p.Value.base_url } else { "N/A" }
                ModelCount = if ($p.Value.models)    { @($p.Value.models).Count } else { 0 }
            })
        }
        return $list
    }
    return @()
}

function Get-Options {
    $config = Get-CrushConfig
    if ($config -and $config.options) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($o in $config.options.PSObject.Properties) {
            $list.Add([PSCustomObject]@{ Name = $o.Name; Value = $o.Value })
        }
        return $list
    }
    return @()
}

function Save-Config {
    <#
    .SYNOPSIS
        Write crush.json back with correct UTF-8 (no BOM) and guaranteed
        JSON array brackets around every provider's models list.
    .NOTES
        BUG-FIX: @() wrapping prevents single-model providers from being
        serialised as {} instead of [{}].
        BUG-FIX: WriteAllText never emits the BOM that Set-Content -utf8 adds
        on Windows PowerShell 5.x.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    function Format-Json {
        param(
            [Parameter(Mandatory)][string]$Json,
            [int]$IndentSize = 2
        )

        $builder = New-Object System.Text.StringBuilder
        $indentLevel = 0
        $inString = $false
        $isEscaped = $false

        for ($i = 0; $i -lt $Json.Length; $i++) {
            $char = $Json[$i]

            if ($isEscaped) {
                [void]$builder.Append($char)
                $isEscaped = $false
                continue
            }

            if ($char -eq '\') {
                [void]$builder.Append($char)
                if ($inString) { $isEscaped = $true }
                continue
            }

            if ($char -eq '"') {
                [void]$builder.Append($char)
                $inString = -not $inString
                continue
            }

            if ($inString) {
                [void]$builder.Append($char)
                continue
            }

            switch ($char) {
                '{' {
                    [void]$builder.Append($char)
                    if (($i + 1) -lt $Json.Length -and $Json[$i + 1] -ne '}') {
                        $indentLevel++
                        [void]$builder.AppendLine()
                        [void]$builder.Append((' ' * ($indentLevel * $IndentSize)))
                    }
                }
                '[' {
                    [void]$builder.Append($char)
                    if (($i + 1) -lt $Json.Length -and $Json[$i + 1] -ne ']') {
                        $indentLevel++
                        [void]$builder.AppendLine()
                        [void]$builder.Append((' ' * ($indentLevel * $IndentSize)))
                    }
                }
                '}' {
                    if ($i -gt 0 -and $Json[$i - 1] -ne '{') {
                        $indentLevel--
                        [void]$builder.AppendLine()
                        [void]$builder.Append((' ' * ($indentLevel * $IndentSize)))
                    }
                    [void]$builder.Append($char)
                }
                ']' {
                    if ($i -gt 0 -and $Json[$i - 1] -ne '[') {
                        $indentLevel--
                        [void]$builder.AppendLine()
                        [void]$builder.Append((' ' * ($indentLevel * $IndentSize)))
                    }
                    [void]$builder.Append($char)
                }
                ',' {
                    [void]$builder.Append($char)
                    [void]$builder.AppendLine()
                    [void]$builder.Append((' ' * ($indentLevel * $IndentSize)))
                }
                ':' {
                    [void]$builder.Append(': ')
                }
                default {
                    [void]$builder.Append($char)
                }
            }
        }

        return $builder.ToString()
    }
    if ($Config.providers) {
        foreach ($p in $Config.providers.PSObject.Properties) {
            if ($null -ne $p.Value -and $null -ne $p.Value.models) {
                $p.Value | Add-Member `
                    -NotePropertyName "models" `
                    -NotePropertyValue ([object[]]@($p.Value.models)) `
                    -Force
            }
        }
    }
    $json = $Config | ConvertTo-Json -Depth 20 -Compress
    $json = Format-Json -Json $json
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Build UI
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text            = "Crush Configuration Manager"
$form.Size            = New-Object System.Drawing.Size(920, 680)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)

$tabControl          = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(10, 10)
$tabControl.Size     = New-Object System.Drawing.Size(882, 618)
$form.Controls.Add($tabControl)

# ---- Tab 1 : Overview --------------------------------------------------

$tabOverview      = New-Object System.Windows.Forms.TabPage
$tabOverview.Text = "Overview"
$tabControl.Controls.Add($tabOverview)

# Status group
$statusGroup          = New-Object System.Windows.Forms.GroupBox
$statusGroup.Text     = "Status"
$statusGroup.Location = New-Object System.Drawing.Point(10, 10)
$statusGroup.Size     = New-Object System.Drawing.Size(845, 110)
$tabOverview.Controls.Add($statusGroup)

$crushStatusLabel           = New-Object System.Windows.Forms.Label
$crushStatusLabel.Location  = New-Object System.Drawing.Point(10, 20)
$crushStatusLabel.Size      = New-Object System.Drawing.Size(420, 20)
$crushStatusLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$statusGroup.Controls.Add($crushStatusLabel)

$crushPathLabel          = New-Object System.Windows.Forms.Label
$crushPathLabel.Location = New-Object System.Drawing.Point(10, 44)
$crushPathLabel.Size     = New-Object System.Drawing.Size(820, 18)
$crushPathLabel.Font     = New-Object System.Drawing.Font("Consolas", 8)
$statusGroup.Controls.Add($crushPathLabel)

$configPathLabel          = New-Object System.Windows.Forms.Label
$configPathLabel.Location = New-Object System.Drawing.Point(10, 64)
$configPathLabel.Size     = New-Object System.Drawing.Size(820, 18)
$configPathLabel.Font     = New-Object System.Drawing.Font("Consolas", 8)
$statusGroup.Controls.Add($configPathLabel)

$configExistsLabel          = New-Object System.Windows.Forms.Label
$configExistsLabel.Location = New-Object System.Drawing.Point(10, 86)
$configExistsLabel.Size     = New-Object System.Drawing.Size(420, 18)
$configExistsLabel.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$statusGroup.Controls.Add($configExistsLabel)

# Providers summary
$providersGroup          = New-Object System.Windows.Forms.GroupBox
$providersGroup.Text     = "Providers"
$providersGroup.Location = New-Object System.Drawing.Point(10, 130)
$providersGroup.Size     = New-Object System.Drawing.Size(845, 210)
$tabOverview.Controls.Add($providersGroup)

$providersListView                  = New-Object System.Windows.Forms.ListView
$providersListView.Location         = New-Object System.Drawing.Point(8, 20)
$providersListView.Size             = New-Object System.Drawing.Size(826, 178)
$providersListView.View             = "Details"
$providersListView.FullRowSelect    = $true
$providersListView.GridLines        = $true
$providersListView.HideSelection    = $false
[void]$providersListView.Columns.Add("Provider", 160)
[void]$providersListView.Columns.Add("Type",     120)
[void]$providersListView.Columns.Add("Base URL", 400)
[void]$providersListView.Columns.Add("Models",    80)
$providersGroup.Controls.Add($providersListView)

# Options group
$optionsGroup          = New-Object System.Windows.Forms.GroupBox
$optionsGroup.Text     = "Options"
$optionsGroup.Location = New-Object System.Drawing.Point(10, 350)
$optionsGroup.Size     = New-Object System.Drawing.Size(845, 160)
$tabOverview.Controls.Add($optionsGroup)

$optionsListView               = New-Object System.Windows.Forms.ListView
$optionsListView.Location      = New-Object System.Drawing.Point(8, 20)
$optionsListView.Size          = New-Object System.Drawing.Size(826, 128)
$optionsListView.View          = "Details"
$optionsListView.FullRowSelect = $true
$optionsListView.GridLines     = $true
[void]$optionsListView.Columns.Add("Option", 220)
[void]$optionsListView.Columns.Add("Value",  590)
$optionsGroup.Controls.Add($optionsListView)

# Buttons row
$refreshButton          = New-Object System.Windows.Forms.Button
$refreshButton.Text     = "Refresh"
$refreshButton.Location = New-Object System.Drawing.Point(10, 522)
$refreshButton.Size     = New-Object System.Drawing.Size(90, 30)
$tabOverview.Controls.Add($refreshButton)

$removeProviderButton           = New-Object System.Windows.Forms.Button
$removeProviderButton.Text      = "Remove Provider"
$removeProviderButton.Location  = New-Object System.Drawing.Point(110, 522)
$removeProviderButton.Size      = New-Object System.Drawing.Size(130, 30)
$removeProviderButton.BackColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
$removeProviderButton.ForeColor = [System.Drawing.Color]::White
$removeProviderButton.FlatStyle = "Flat"
$tabOverview.Controls.Add($removeProviderButton)

$openConfigButton          = New-Object System.Windows.Forms.Button
$openConfigButton.Text     = "Open Config"
$openConfigButton.Location = New-Object System.Drawing.Point(250, 522)
$openConfigButton.Size     = New-Object System.Drawing.Size(100, 30)
$tabOverview.Controls.Add($openConfigButton)

$openDirButton          = New-Object System.Windows.Forms.Button
$openDirButton.Text     = "Open Directory"
$openDirButton.Location = New-Object System.Drawing.Point(360, 522)
$openDirButton.Size     = New-Object System.Drawing.Size(120, 30)
$tabOverview.Controls.Add($openDirButton)

# ---- Tab 2 : Sync Models -----------------------------------------------

$tabSync      = New-Object System.Windows.Forms.TabPage
$tabSync.Text = "Sync Models"
$tabControl.Controls.Add($tabSync)

$providerLabel          = New-Object System.Windows.Forms.Label
$providerLabel.Text     = "Provider Name:"
$providerLabel.Location = New-Object System.Drawing.Point(20, 22)
$providerLabel.Size     = New-Object System.Drawing.Size(120, 20)
$tabSync.Controls.Add($providerLabel)

$providerComboBox                = New-Object System.Windows.Forms.ComboBox
$providerComboBox.Location       = New-Object System.Drawing.Point(148, 20)
$providerComboBox.Size           = New-Object System.Drawing.Size(300, 22)
$providerComboBox.DropDownStyle  = "DropDown"
$tabSync.Controls.Add($providerComboBox)

$urlLabel          = New-Object System.Windows.Forms.Label
$urlLabel.Text     = "Models URL:"
$urlLabel.Location = New-Object System.Drawing.Point(20, 54)
$urlLabel.Size     = New-Object System.Drawing.Size(120, 20)
$tabSync.Controls.Add($urlLabel)

$urlTextBox          = New-Object System.Windows.Forms.TextBox
$urlTextBox.Location = New-Object System.Drawing.Point(148, 52)
$urlTextBox.Size     = New-Object System.Drawing.Size(560, 22)
$tabSync.Controls.Add($urlTextBox)

$syncButton          = New-Object System.Windows.Forms.Button
$syncButton.Text     = "Sync Models"
$syncButton.Location = New-Object System.Drawing.Point(148, 88)
$syncButton.Size     = New-Object System.Drawing.Size(130, 34)
$syncButton.BackColor= [System.Drawing.Color]::FromArgb(0, 120, 212)
$syncButton.ForeColor= [System.Drawing.Color]::White
$syncButton.FlatStyle= "Flat"
$tabSync.Controls.Add($syncButton)

$outputLabel          = New-Object System.Windows.Forms.Label
$outputLabel.Text     = "Output:"
$outputLabel.Location = New-Object System.Drawing.Point(20, 136)
$outputLabel.Size     = New-Object System.Drawing.Size(80, 20)
$tabSync.Controls.Add($outputLabel)

$outputTextBox             = New-Object System.Windows.Forms.TextBox
$outputTextBox.Location    = New-Object System.Drawing.Point(20, 158)
$outputTextBox.Size        = New-Object System.Drawing.Size(836, 360)
$outputTextBox.Multiline   = $true
$outputTextBox.ScrollBars  = "Vertical"
$outputTextBox.ReadOnly    = $true
$outputTextBox.Font        = New-Object System.Drawing.Font("Consolas", 9)
$outputTextBox.BackColor   = [System.Drawing.Color]::FromArgb(30, 30, 30)
$outputTextBox.ForeColor   = [System.Drawing.Color]::FromArgb(220, 220, 220)
$tabSync.Controls.Add($outputTextBox)

$progressBar          = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 530)
$progressBar.Size     = New-Object System.Drawing.Size(836, 18)
$progressBar.Style    = "Marquee"
$progressBar.Visible  = $false
$tabSync.Controls.Add($progressBar)

$statusLabel          = New-Object System.Windows.Forms.Label
$statusLabel.Text     = "Ready"
$statusLabel.Location = New-Object System.Drawing.Point(20, 554)
$statusLabel.Size     = New-Object System.Drawing.Size(836, 20)
$statusLabel.ForeColor= [System.Drawing.Color]::Gray
$tabSync.Controls.Add($statusLabel)

# ---- Tab 3 : Models ----------------------------------------------------

$tabModels      = New-Object System.Windows.Forms.TabPage
$tabModels.Text = "Models"
$tabControl.Controls.Add($tabModels)

$providerFilterLabel          = New-Object System.Windows.Forms.Label
$providerFilterLabel.Text     = "Filter by Provider:"
$providerFilterLabel.Location = New-Object System.Drawing.Point(20, 22)
$providerFilterLabel.Size     = New-Object System.Drawing.Size(140, 20)
$tabModels.Controls.Add($providerFilterLabel)

$providerFilterComboBox               = New-Object System.Windows.Forms.ComboBox
$providerFilterComboBox.Location      = New-Object System.Drawing.Point(168, 20)
$providerFilterComboBox.Size          = New-Object System.Drawing.Size(220, 22)
$providerFilterComboBox.DropDownStyle = "DropDownList"
$tabModels.Controls.Add($providerFilterComboBox)

$modelsListView               = New-Object System.Windows.Forms.ListView
$modelsListView.Location      = New-Object System.Drawing.Point(20, 52)
$modelsListView.Size          = New-Object System.Drawing.Size(836, 500)
$modelsListView.View          = "Details"
$modelsListView.FullRowSelect = $true
$modelsListView.GridLines     = $true
[void]$modelsListView.Columns.Add("Model ID",       260)
[void]$modelsListView.Columns.Add("Context Window", 130)
[void]$modelsListView.Columns.Add("Max Tokens",     110)
[void]$modelsListView.Columns.Add("Provider",       310)
$tabModels.Controls.Add($modelsListView)

$modelCountLabel          = New-Object System.Windows.Forms.Label
$modelCountLabel.Text     = "Total Models: 0"
$modelCountLabel.Location = New-Object System.Drawing.Point(20, 558)
$modelCountLabel.Size     = New-Object System.Drawing.Size(836, 20)
$modelCountLabel.ForeColor= [System.Drawing.Color]::Gray
$tabModels.Controls.Add($modelCountLabel)

# ---------------------------------------------------------------------------
# Logic functions
# ---------------------------------------------------------------------------

function Refresh-Overview {
    # Crush status
    $found, $path = Test-Crush
    $crushStatusLabel.Text     = "Crush: $(if ($found) { 'Installed [OK]' } else { 'Not Found [X]' })"
    $crushStatusLabel.ForeColor= if ($found) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::Red }
    $crushPathLabel.Text       = "Path: $path"
    $configPathLabel.Text      = "Config: $configPath"

    $exists = Test-Path $configPath
    $configExistsLabel.Text     = "Config file: $(if ($exists) { 'Found [OK]' } else { 'Not Found [X]' })"
    $configExistsLabel.ForeColor= if ($exists) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::Red }

    $providersListView.Items.Clear()
    $optionsListView.Items.Clear()

    $providers = Get-ProviderInfo
    foreach ($p in $providers) {
        $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
        [void]$item.SubItems.Add($p.Type)
        [void]$item.SubItems.Add($p.BaseUrl)
        [void]$item.SubItems.Add($p.ModelCount.ToString())
        [void]$providersListView.Items.Add($item)
    }

    $options = Get-Options
    foreach ($o in $options) {
        $item = New-Object System.Windows.Forms.ListViewItem($o.Name)
        [void]$item.SubItems.Add($o.Value.ToString())
        [void]$optionsListView.Items.Add($item)
    }

    # Sync-tab combo: preserve typed text, don't fire URL auto-fill
    $prevProvider = $providerComboBox.Text
    $providerComboBox.Items.Clear()
    foreach ($p in $providers) { [void]$providerComboBox.Items.Add($p.Name) }
    # Restore previous text without triggering SelectionChangeCommitted
    $providerComboBox.Text = $prevProvider
    Try-AutofillModelsUrl -OnlyWhenEmpty

    # Models-tab filter combo
    $prevFilter = $providerFilterComboBox.Text
    $providerFilterComboBox.Items.Clear()
    [void]$providerFilterComboBox.Items.Add("All Providers")
    foreach ($p in $providers) { [void]$providerFilterComboBox.Items.Add($p.Name) }
    if ($providerFilterComboBox.Items.Contains($prevFilter)) {
        $providerFilterComboBox.Text = $prevFilter
    } else {
        $providerFilterComboBox.SelectedIndex = 0
    }
}

function Load-Models {
    $modelsListView.Items.Clear()
    $config = Get-CrushConfig
    if (-not $config -or -not $config.providers) {
        $modelCountLabel.Text = "Total Models: 0"
        return
    }

    $filter = $providerFilterComboBox.Text
    $total  = 0

    foreach ($prop in $config.providers.PSObject.Properties) {
        $pName = $prop.Name
        if ($filter -ne "All Providers" -and $filter -ne $pName) { continue }
        if ($prop.Value.models) {
            foreach ($m in $prop.Value.models) {
                $item = New-Object System.Windows.Forms.ListViewItem($m.id)
                [void]$item.SubItems.Add($m.context_window.ToString())
                [void]$item.SubItems.Add($m.default_max_tokens.ToString())
                [void]$item.SubItems.Add($pName)
                [void]$modelsListView.Items.Add($item)
                $total++
            }
        }
    }
    $modelCountLabel.Text = "Total Models: $total"
}

function Get-ModelsUrlFromBaseUrl {
    param([string]$BaseUrl)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return "" }

    $normalizedBaseUrl = $BaseUrl.TrimEnd('/')
    if ($normalizedBaseUrl -match '/v1$') {
        return "$normalizedBaseUrl/models"
    }

    return "$normalizedBaseUrl/v1/models"
}

function Try-AutofillModelsUrl {
    param([switch]$OnlyWhenEmpty)

    $providerName = $providerComboBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($providerName)) { return }
    if ($OnlyWhenEmpty -and -not [string]::IsNullOrWhiteSpace($urlTextBox.Text)) { return }

    $config = Get-CrushConfig
    if (-not $config -or -not $config.providers) { return }

    $providerConfig = $config.providers.($providerName)
    if ($providerConfig -and $providerConfig.base_url) {
        $urlTextBox.Text = Get-ModelsUrlFromBaseUrl -BaseUrl $providerConfig.base_url
    }
}

function Sync-Models {
    $pName = $providerComboBox.Text.Trim()
    $pUrl  = $urlTextBox.Text.Trim()

    if ([string]::IsNullOrEmpty($pName)) {
        [void][System.Windows.Forms.MessageBox]::Show("Please enter a provider name.", "Validation", "OK", "Warning")
        return
    }
    if ([string]::IsNullOrEmpty($pUrl)) {
        [void][System.Windows.Forms.MessageBox]::Show("Please enter a models URL.", "Validation", "OK", "Warning")
        return
    }

    $syncButton.Enabled  = $false
    $progressBar.Visible = $true
    $statusLabel.Text    = "Syncing..."
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $outputTextBox.Clear()

    # BUG-FIX: Start-Job spawns a new PowerShell.exe - 3-5 s overhead.
    # A Runspace reuses the current process; overhead is ~10-50 ms.
    # A WinForms Timer polls completion without blocking the UI thread.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($toolPath, $prov, $u)
        & $toolPath -add_update -provider $prov -url $u 2>&1 | Out-String
    }).AddArgument($crushtoolPath).AddArgument($pName).AddArgument($pUrl)

    $script:syncAsyncResult = $ps.BeginInvoke()
    $script:syncPs          = $ps
    $script:syncRs          = $rs

    $script:syncTimer          = New-Object System.Windows.Forms.Timer
    $script:syncTimer.Interval = 150
    $script:syncTimer.Add_Tick({
        if (-not $script:syncAsyncResult.IsCompleted) { return }

        $script:syncTimer.Stop()
        $script:syncTimer.Dispose()

        $output = ($script:syncPs.EndInvoke($script:syncAsyncResult) -join "").TrimEnd()
        $script:syncPs.Dispose()
        $script:syncRs.Dispose()

        $outputTextBox.Text = $output

        if ($script:syncPs.HadErrors -or $output -match "^Error") {
            $statusLabel.Text     = "Sync failed - see output above."
            $statusLabel.ForeColor= [System.Drawing.Color]::Red
        } else {
            $statusLabel.Text     = "Sync complete!"
            $statusLabel.ForeColor= [System.Drawing.Color]::Green
            Refresh-Overview
            Load-Models
        }

        $syncButton.Enabled  = $true
        $progressBar.Visible = $false
    })
    $script:syncTimer.Start()
}

function Remove-Provider {
    if ($providersListView.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Select a provider in the list first.", "Nothing selected", "OK", "Warning")
        return
    }

    $providerName = $providersListView.SelectedItems[0].Text
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Remove provider '$providerName'?`n`nThis cannot be undone.",
        "Confirm Removal", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    try {
        $config = Get-CrushConfig
        if ($config -and $config.providers) {
            # BUG-FIX: remove the provider, then save with the shared
            # Save-Config helper that guarantees correct JSON arrays.
            $config.providers.PSObject.Properties.Remove($providerName)
            Save-Config -Config $config -Path $configPath
            [void][System.Windows.Forms.MessageBox]::Show(
                "Provider '$providerName' removed.", "Done", "OK", "Information")
            Refresh-Overview
            Load-Models
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Failed to remove provider:`n$_", "Error", "OK", "Error")
    }
}

function Open-ConfigFile {
    if (Test-Path $configPath) { Start-Process $configPath }
    else {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Config file not found:`n$configPath", "Not Found", "OK", "Error")
    }
}

function Open-ConfigDirectory {
    try { Start-Process (Split-Path -Parent $configPath) }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Could not open directory:`n$_", "Error", "OK", "Error")
    }
}

# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------

$refreshButton.Add_Click({ Refresh-Overview; Load-Models })

$removeProviderButton.Add_Click({ Remove-Provider })

$openConfigButton.Add_Click({ Open-ConfigFile })

$openDirButton.Add_Click({ Open-ConfigDirectory })

$syncButton.Add_Click({ Sync-Models })

$providerComboBox.Add_SelectionChangeCommitted({
    Try-AutofillModelsUrl
})

$providerComboBox.Add_TextUpdate({
    Try-AutofillModelsUrl
})

$providerFilterComboBox.Add_SelectedIndexChanged({ Load-Models })

# ---------------------------------------------------------------------------
# Initialise - BUG-FIX: was called BEFORE ShowDialog(), causing the window
# to appear blank/frozen for 1-2 s while data loaded. Add_Shown fires after
# the form is first painted, so the user sees the window immediately.
# ---------------------------------------------------------------------------
$form.Add_Shown({
    Refresh-Overview
    Load-Models
})

[void]$form.ShowDialog()
