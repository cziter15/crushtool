#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sync models from OpenAI-compatible API to crush.json

.DESCRIPTION
    Fetches models from an OpenAI-compatible /v1/models endpoint and merges them
    into a named provider section in crush.json

.PARAMETER add_update
    Switch to enable add/update mode

.PARAMETER provider
    Name of the provider section to update/create

.PARAMETER url
    Full URL to the /v1/models endpoint

.EXAMPLE
    .\crushtool.ps1 -add_update -provider OmniRoute -url http://192.168.1.106:8080/v1/models
#>

param(
    [switch]$add_update,
    [string]$provider,
    [string]$url
)

if (-not $add_update) {
    Write-Host "Usage: crushtool.ps1 -add_update -provider <provider_name> -url <models_endpoint_url>"
    Write-Host "Example: crushtool.ps1 -add_update -provider OmniRoute -url http://192.168.1.106:8080/v1/models"
    exit 1
}

if (-not $provider) {
    Write-Error "Provider name is required"
    exit 1
}

if (-not $url) {
    Write-Error "URL is required"
    exit 1
}

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

function Save-Config {
    <#
    .SYNOPSIS
        Write config back to crush.json with correct UTF-8 (no BOM) and
        guaranteed JSON array serialisation for every provider's models list.
    .NOTES
        PowerShell's ConvertTo-Json silently unwraps single-element arrays
        when the value came through a pipeline (e.g. Sort-Object).
        Wrapping with @() before serialisation prevents that.
        Set-Content -Encoding utf8 on Windows PowerShell 5.x emits a BOM;
        WriteAllText with UTF8Encoding($false) never does.
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

    # BUG-FIX: ensure every provider's models property is a proper array,
    # not an unwrapped single object. ConvertTo-Json requires Object[] to
    # emit square brackets even for one-element lists.
    if ($Config.providers) {
        foreach ($prop in $Config.providers.PSObject.Properties) {
            if ($null -ne $prop.Value -and $null -ne $prop.Value.models) {
                $prop.Value | Add-Member `
                    -NotePropertyName "models" `
                    -NotePropertyValue ([object[]]@($prop.Value.models)) `
                    -Force
            }
        }
    }

    $json = $Config | ConvertTo-Json -Depth 20 -Compress   # BUG-FIX: was -Depth 10
    $json = Format-Json -Json $json
    # BUG-FIX: WriteAllText with explicit no-BOM encoding; Set-Content
    #          -Encoding utf8 emits a 3-byte BOM in Windows PowerShell 5.
    [System.IO.File]::WriteAllText(
        $Path,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# -----------------------------------------------------------------------
# Locate crush.json
# -----------------------------------------------------------------------

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path (Split-Path -Parent $scriptDir) "crush.json"

if (-not (Test-Path $configPath)) {
    Write-Error "crush.json not found at: $configPath"
    exit 1
}

# -----------------------------------------------------------------------
# Fetch models
# -----------------------------------------------------------------------

Write-Host "Fetching models from: $url"
try {
    $response = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
} catch {
    Write-Error "Failed to fetch models: $_"
    exit 1
}

if (-not $response.data) {
    Write-Error "No models found in API response"
    exit 1
}

Write-Host "Found $($response.data.Count) models"

# -----------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------

$config = Get-Content $configPath -Raw | ConvertFrom-Json

# BUG-FIX: must be PSCustomObject, not plain @{} Hashtable.
# Add-Member on a Hashtable adds to PSExtended, not to the dictionary;
# subsequent $hash.$key lookups then return $null.
if (-not $config.providers) {
    $config | Add-Member -Type NoteProperty -Name "providers" -Value ([PSCustomObject]@{})
}

# -----------------------------------------------------------------------
# Create / update provider entry
# -----------------------------------------------------------------------

$baseUrl = $url -replace '/v1/models$', ''

if (-not $config.providers.$provider) {
    $providerObj = [PSCustomObject]@{
        type     = "openai-compat"
        base_url = $baseUrl
        api_key  = ""
        models   = [object[]]@()
    }
    $config.providers | Add-Member -Type NoteProperty -Name $provider -Value $providerObj
    Write-Host "Created new provider: $provider"
} else {
    $config.providers.$provider.base_url = $baseUrl
    Write-Host "Updating existing provider: $provider"
}

# -----------------------------------------------------------------------
# Build model lookup from existing entries (preserves hand-edited costs)
# -----------------------------------------------------------------------

$existingModels = @{}
foreach ($model in $config.providers.$provider.models) {
    if ($model -and $model.id) {
        $existingModels[$model.id] = $model
    }
}

# -----------------------------------------------------------------------
# Process API response
# -----------------------------------------------------------------------

$newModels    = [System.Collections.Generic.List[object]]::new()
$updatedCount = 0
$addedCount   = 0

foreach ($apiModel in $response.data) {
    # Skip embedding / audio / rerank / etc.
    if ($apiModel.type -and $apiModel.type -ne "chat" -and $apiModel.type -ne "") { continue }
    if ($apiModel.subtype) { continue }

    $modelId = $apiModel.id

    $contextWindow = 128000
    if ($apiModel.context_length) { $contextWindow = [int]$apiModel.context_length }

    $defaultMaxTokens = 5000
    if ($contextWindow -ge 400000) { $defaultMaxTokens = 16000 }

    $modelObj = [PSCustomObject]@{
        id                    = $modelId
        name                  = $modelId
        cost_per_1m_in        = 0
        cost_per_1m_out       = 0
        cost_per_1m_in_cached = 0
        cost_per_1m_out_cached= 0
        context_window        = $contextWindow
        default_max_tokens    = $defaultMaxTokens
    }

    if ($existingModels.ContainsKey($modelId)) {
        $existing = $existingModels[$modelId]
        if ($existing.cost_per_1m_in        -gt 0) { $modelObj.cost_per_1m_in         = $existing.cost_per_1m_in }
        if ($existing.cost_per_1m_out       -gt 0) { $modelObj.cost_per_1m_out        = $existing.cost_per_1m_out }
        if ($existing.cost_per_1m_in_cached -gt 0) { $modelObj.cost_per_1m_in_cached  = $existing.cost_per_1m_in_cached }
        if ($existing.cost_per_1m_out_cached-gt 0) { $modelObj.cost_per_1m_out_cached = $existing.cost_per_1m_out_cached }
        $updatedCount++
    } else {
        $addedCount++
    }

    $newModels.Add($modelObj)
}

# -----------------------------------------------------------------------
# BUG-FIX: Sort-Object on a single item returns the item, not an array.
# [object[]]@(...) forces the result to stay a typed array so
# ConvertTo-Json emits [ ] even when there is only one model.
# -----------------------------------------------------------------------
$config.providers.$provider.models = [object[]]@($newModels | Sort-Object -Property id)

# -----------------------------------------------------------------------
# Save
# -----------------------------------------------------------------------
Save-Config -Config $config -Path $configPath

Write-Host "Sync complete:"
Write-Host "  Provider : $provider"
Write-Host "  Base URL : $baseUrl"
Write-Host "  Total    : $($newModels.Count)"
Write-Host "  Added    : $addedCount"
Write-Host "  Updated  : $updatedCount"
