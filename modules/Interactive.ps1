<#
.SYNOPSIS
    Device DNA - Interactive Module
.DESCRIPTION
    Console-based interactive parameter collection.
    Prompts users for computer name when not provided via parameters.
.NOTES
    Module: Interactive.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
#>

function Get-InteractiveParameters {
    <#
    .SYNOPSIS
        Collects missing parameters interactively from the user.
    .OUTPUTS
        Hashtable with collected parameters.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$CurrentComputerName
    )

    $params = @{
        ComputerName = $CurrentComputerName
    }

    try {
        # ComputerName - default to localhost if not provided
        if ([string]::IsNullOrEmpty($params.ComputerName)) {
            Write-Host ""
            Write-Host "Target Computer" -ForegroundColor Cyan
            Write-Host "===============" -ForegroundColor Cyan
            $input = Read-Host "Enter computer name (press Enter for localhost)"

            if ([string]::IsNullOrEmpty($input)) {
                $params.ComputerName = $env:COMPUTERNAME
                Write-StatusMessage "Using local computer: $($params.ComputerName)" -Type Info
            }
            else {
                $params.ComputerName = $input.Trim()
            }
        }
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Error during interactive parameter collection: $($_.Exception.Message)" }
    }

    return $params
}

function Confirm-Parameters {
    <#
    .SYNOPSIS
        Validates the collected parameters before execution.
    .OUTPUTS
        Boolean indicating if parameters are valid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $isValid = $true

    try {
        # Validate ComputerName
        if ([string]::IsNullOrEmpty($Parameters.ComputerName)) {
            Write-StatusMessage "ComputerName is required." -Type Error
            $isValid = $false
        }

        # Validate OutputPath
        $outputDir = $Parameters.OutputPath
        if (-not [string]::IsNullOrEmpty($outputDir)) {
            if (-not (Test-Path -Path $outputDir -PathType Container -ErrorAction SilentlyContinue)) {
                try {
                    $null = New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop
                    Write-StatusMessage "Created output directory: $outputDir" -Type Info
                }
                catch {
                    Write-StatusMessage "Cannot create output directory: $outputDir" -Type Error
                    $isValid = $false
                }
            }
        }
    }
    catch {
        Write-StatusMessage "Parameter validation error: $($_.Exception.Message)" -Type Error
        $isValid = $false
    }

    return $isValid
}
