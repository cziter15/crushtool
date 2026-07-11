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

.PARAMETER config
    Optional path to the crush.json or .crush.json configuration file

.EXAMPLE
    .\crushtool.ps1 -add_update -provider OmniRoute -url http://192.168.1.106:8080/v1/models
#>

param(
    [switch]$add_update,
    [string]$provider,
    [string]$url,
    [string]$config
)

if (-not $add_update) {
    Write-Host "Usage: crushtool.ps1 -add_update -provider <provider_name> -url <models_endpoint_url> [-config <path>]"
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

    # Ensure parent directory exists before writing
    $parentDir = Split-Path -Parent $Path
    if ($parentDir -and -not (Test-Path $parentDir)) {
        [void](New-Item -ItemType Directory -Path $parentDir -Force)
    }

    # FIX: Add null check on $Config itself, and robustly ensure models arrays
    if ($null -ne $Config -and $null -ne $Config.providers) {
        foreach ($prop in $Config.providers.PSObject.Properties) {
            if ($null -ne $prop.Value -and $prop.Value -is [PSCustomObject]) {
                $modelsVal = if ($null -ne $prop.Value.models) {
                    [object[]]@($prop.Value.models)
                } else {
                    [object[]]@()
                }
                $prop.Value | Add-Member -NotePropertyName "models" -NotePropertyValue $modelsVal -Force
            }
        }
    }

    $json = $Config | ConvertTo-Json -Depth 20 -Compress
    $json = Format-Json -Json $json
    [System.IO.File]::WriteAllText(
        $Path,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# -----------------------------------------------------------------------
# Locate crush.json
# -----------------------------------------------------------------------

 $configPath = $null

if ($config) {
    $configPath = $config
    Write-Host "Using explicitly provided configuration path: $configPath"
} else {
    $cwd = Get-Location
    $searchPaths = [System.Collections.Generic.List[string]]::new()

    # Determine global paths first to use as standard fallback
    $globalPath = $null
    $isWin = $IsWindows -or ($env:OS -like "*Windows*")
    if ($isWin) {
        if ($env:LOCALAPPDATA) {
            $globalPath = Join-Path $env:LOCALAPPDATA "crush\crush.json"
        } elseif ($env:USERPROFILE) {
            $globalPath = Join-Path $env:USERPROFILE "AppData\Local\crush\crush.json"
        } else {
            $globalPath = Join-Path $env:HOMEDRIVE (Join-Path $env:HOMEPATH "AppData\Local\crush\crush.json")
        }
    } else {
        $xdgConfig = $env:XDG_CONFIG_HOME
        if ([string]::IsNullOrEmpty($xdgConfig) -and $env:HOME) {
            $xdgConfig = Join-Path $env:HOME ".config"
        }
        if ($xdgConfig) {
            $globalPath = Join-Path $xdgConfig "crush/crush.json"
        }
    }

    # Search order (highest priority to lowest priority, matching Crush's priority spec):
    # 1. Project-local configurations (Current Working Directory)
    $searchPaths.Add((Join-Path $cwd ".crush.json"))
    $searchPaths.Add((Join-Path $cwd "crush.json"))

    # 2. Script directory and parent folder (fallback if run from or placed in a scripts subfolder)
    if ($PSScriptRoot) {
        $searchPaths.Add((Join-Path $PSScriptRoot ".crush.json"))
        $searchPaths.Add((Join-Path $PSScriptRoot "crush.json"))
        $searchPaths.Add((Join-Path (Split-Path -Parent $PSScriptRoot) ".crush.json"))
        $searchPaths.Add((Join-Path (Split-Path -Parent $PSScriptRoot) "crush.json"))
    }

    # 3. Environment override
    if ($env:CRUSH_GLOBAL_CONFIG) {
        $searchPaths.Add((Join-Path $env:CRUSH_GLOBAL_CONFIG "crush.json"))
    }

    # 4. Standard global configuration path
    if ($globalPath) {
        $searchPaths.Add($globalPath)
    }

    # 5. Secondary Windows fallback (~/.config/crush/crush.json)
    if ($isWin -and $env:USERPROFILE) {
        $searchPaths.Add((Join-Path $env:USERPROFILE ".config\crush\crush.json"))
    }

    # Find the first path that actually exists on disk
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            $configPath = $path
            break
        }
    }

    # Fallback: Default to the global configuration path if no existing file is found anywhere
    if ($null -eq $configPath) {
        if ($globalPath) {
            $configPath = $globalPath
            Write-Host "No existing crush.json or .crush.json found. Defaulting to global path."
        } else {
            $configPath = Join-Path $cwd "crush.json"
            Write-Host "No global configuration path resolved. Defaulting to local path."
        }
        Write-Host "Will initialize a new configuration file at: $configPath"
    } else {
        Write-Host "Located configuration file at: $configPath"
    }
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

# Dynamic parsing: support standard OpenAI '.data' key or custom '.models' key
 $modelsList = @()
if ($response.data) {
    $modelsList = @($response.data)
} elseif ($response.models) {
    $modelsList = @($response.models)
} else {
    Write-Error "No models found in API response. Expected a 'data' or 'models' property in the JSON."
    exit 1
}

Write-Host "Found $($modelsList.Count) models"

# -----------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------

# FIX: Use $crushConfig instead of $config for the parsed object.
# The [string]$config parameter type-constrains the variable, so assigning
# a PSCustomObject to $config would silently convert it to a string,
# causing $config.providers to always be $null.

if (Test-Path $configPath) {
    $rawContent = Get-Content $configPath -Raw
    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        $crushConfig = [PSCustomObject]@{
            '$schema' = "https://charm.land/crush.json"
        }
    } else {
        $crushConfig = $rawContent | ConvertFrom-Json
    }
} else {
    $crushConfig = [PSCustomObject]@{
        '$schema' = "https://charm.land/crush.json"
    }
}

# FIX: Ensure $crushConfig is a valid PSCustomObject
if ($null -eq $crushConfig -or $crushConfig -isnot [PSCustomObject]) {
    $crushConfig = [PSCustomObject]@{
        '$schema' = "https://charm.land/crush.json"
    }
}

# Safely verify/add the 'providers' node
if ($null -eq $crushConfig.providers -or $crushConfig.providers -isnot [PSCustomObject]) {
    $crushConfig | Add-Member -NotePropertyName "providers" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# FIX: Verify providers was actually added
if ($null -eq $crushConfig.providers) {
    Write-Error "Failed to initialize providers section in config"
    exit 1
}

# -----------------------------------------------------------------------
# Create / update provider entry
# -----------------------------------------------------------------------

 $baseUrl = $url -replace '/v1/models$', ''

# FIX: Use PSObject.Properties for robust property existence check
 $providerProp = $null
try { $providerProp = $crushConfig.providers.PSObject.Properties[$provider] } catch { }

if ($null -eq $providerProp -or $null -eq $providerProp.Value) {
    $providerObj = [PSCustomObject]@{
        type     = "openai-compat"
        base_url = $baseUrl
        api_key  = ""
        models   = [object[]]@()
    }
    $crushConfig.providers | Add-Member -NotePropertyName $provider -NotePropertyValue $providerObj -Force
    Write-Host "Created new provider: $provider"
} else {
    # FIX: Ensure all required properties exist on the existing provider
    $providerObj = $crushConfig.providers.$provider

    if ($providerObj.PSObject.Properties['base_url']) {
        $providerObj.base_url = $baseUrl
    } else {
        $providerObj | Add-Member -NotePropertyName "base_url" -NotePropertyValue $baseUrl -Force
    }

    if (-not $providerObj.PSObject.Properties['models'] -or $null -eq $providerObj.models) {
        $providerObj | Add-Member -NotePropertyName "models" -NotePropertyValue ([object[]]@()) -Force
    }

    Write-Host "Updating existing provider: $provider"
}

# -----------------------------------------------------------------------
# Build model lookup from existing entries (preserves hand-edited costs)
# -----------------------------------------------------------------------

 $existingModels = @{}
if ($crushConfig.providers.$provider.models) {
    foreach ($model in $crushConfig.providers.$provider.models) {
        if ($model -and $model.id) {
            $existingModels[$model.id] = $model
        }
    }
}

# -----------------------------------------------------------------------
# Process API response
# -----------------------------------------------------------------------

 $newModels    = [System.Collections.Generic.List[object]]::new()
 $updatedCount = 0
 $addedCount   = 0

foreach ($apiModel in $modelsList) {
    # Skip embedding / audio / rerank / etc.
    if ($apiModel.type -and $apiModel.type -ne "chat" -and $apiModel.type -ne "") { continue }
    if ($apiModel.subtype) { continue }

    # Resolve Model ID dynamically depending on the schema structure
    $modelId = $null
    if ($apiModel.fullModel) {
        $modelId = $apiModel.fullModel
    } elseif ($apiModel.model) {
        $modelId = $apiModel.model
    } elseif ($apiModel.id) {
        $modelId = $apiModel.id
    }

    if ([string]::IsNullOrEmpty($modelId)) {
        continue
    }

    # Resolve Display Name dynamically
    $modelName = $modelId
    if ($apiModel.name) {
        $modelName = $apiModel.name
    }

    $contextWindow = 128000
    if ($apiModel.context_length) { $contextWindow = [int]$apiModel.context_length }

    $defaultMaxTokens = 5000
    if ($contextWindow -ge 400000) { $defaultMaxTokens = 16000 }

    $modelObj = [PSCustomObject]@{
        id                    = $modelId
        name                  = $modelName
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
# FIX: Use Add-Member -Force instead of direct property assignment.
# Direct assignment fails with "property not found" if the property
# doesn't exist on the object. Add-Member -Force handles both add and update.
# -----------------------------------------------------------------------
 $sortedModels = [object[]]@($newModels | Sort-Object -Property id)
 $crushConfig.providers.$provider | Add-Member -NotePropertyName "models" -NotePropertyValue $sortedModels -Force

# -----------------------------------------------------------------------
# Save
# -----------------------------------------------------------------------
Save-Config -Config $crushConfig -Path $configPath

Write-Host "Sync complete:"
Write-Host "  Provider : $provider"
Write-Host "  Base URL : $baseUrl"
Write-Host "  Total    : $($newModels.Count)"
Write-Host "  Added    : $addedCount"
Write-Host "  Updated  : $updatedCount"
