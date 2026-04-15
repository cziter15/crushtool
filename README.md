# Crush Tool - Model Sync Utility

A PowerShell script to sync models from OpenAI-compatible APIs to crush.json configuration.

## Usage

```powershell
.\crushtool.ps1 -add_update -provider <provider_name> -url <models_endpoint_url>
```

## Parameters

- `-add_update`: Switch to enable add/update mode (required)
- `-provider`: Name of the provider section to update/create in crush.json
- `-url`: Full URL to the `/v1/models` endpoint

## Examples

### Create or update a provider:

```powershell
.\crushtool.ps1 -add_update -provider OmniRoute -url http://192.168.1.106:8080/v1/models
```

### Sync models from a different endpoint:

```powershell
.\crushtool.ps1 -add_update -provider MyProvider -url https://api.example.com/v1/models
```

## Features

- **Fetches models** from OpenAI-compatible `/v1/models` endpoint
- **Creates new provider** if it doesn't exist
- **Updates existing provider** while preserving custom cost settings
- **Filters non-chat models** (embeddings, audio, rerank models are skipped)
- **Auto-detects context window** from API response
- **Sets appropriate default_max_tokens** based on context window size
- **Sorts models** alphabetically by ID
- **Preserves existing cost values** when updating models

## Model Properties

Each model synced will have these properties:

```json
{
  "id": "model-id",
  "name": "model-id",
  "cost_per_1m_in": 0,
  "cost_per_1m_out": 0,
  "cost_per_1m_in_cached": 0,
  "cost_per_1m_out_cached": 0,
  "context_window": 128000,
  "default_max_tokens": 5000
}
```

## Context Window Defaults

- Models with `context_length >= 400000`: `default_max_tokens = 16000`
- All other models: `default_max_tokens = 5000`

## Requirements

- PowerShell 5.1 or later
- Internet access to the models endpoint
- Write permissions to crush.json

## Output

The script displays:
- Total models found in API
- Number of models added
- Number of models updated
- Provider name and base URL
