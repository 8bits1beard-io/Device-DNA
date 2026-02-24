<#
.SYNOPSIS
    Device DNA - Comprehensive Group Policy and Intune Configuration Analyzer
.DESCRIPTION
    Collects Group Policy and Intune management data from Windows devices
    and generates a self-contained interactive HTML report.

    Device-only scope: collects device configuration, device groups, and device-targeted policies.
.PARAMETER ComputerName
    Target computer name (default: localhost)
.PARAMETER OutputPath
    Output directory for the HTML report (default: current directory)
.PARAMETER Credential
    Optional credentials to use for remote collection (e.g., domain credentials).
.PARAMETER AutoOpen
    Automatically open the generated report in default browser
.PARAMETER SkipGPUpdate
    Skip running gpupdate /force before collection
.EXAMPLE
    .\DeviceDNA.ps1 -ComputerName "PC001"
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ComputerName,

    [Parameter()]
    [string]$OutputPath = ".",

    [Parameter()]
    [pscredential]$Credential,

    [Parameter()]
    [switch]$AutoOpen,

    [Parameter()]
    [switch]$SkipGPUpdate,

    [Parameter()]
    [ValidateSet(
        'GroupPolicy',
        'Intune',
        'SCCM',
        'WindowsUpdate',
        'ConfigProfiles',
        'ConfigProfileSettings',
        'IntuneApps',
        'CompliancePolicies',
        'GroupMemberships',
        'InstalledApps',
        'SCCMApps',
        'SCCMBaselines',
        'SCCMUpdates',
        'SCCMSettings'
    )]
    [string[]]$Skip = @()
)

# Determine script root for module loading
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition

# Dot-source modules in dependency order
# Core must be first (defines all script-level variables)
. (Join-Path $PSScriptRoot 'modules\Core.ps1')

# Logging before Helpers (Write-StatusMessage depends on Write-DeviceDNALog)
. (Join-Path $PSScriptRoot 'modules\Logging.ps1')

# Helpers before domain modules (most functions use helper utilities)
. (Join-Path $PSScriptRoot 'modules\Helpers.ps1')

# Domain modules (independent of each other, depend on Core/Logging/Helpers)
. (Join-Path $PSScriptRoot 'modules\DeviceInfo.ps1')
. (Join-Path $PSScriptRoot 'modules\GroupPolicy.ps1')
. (Join-Path $PSScriptRoot 'modules\Intune.ps1')
. (Join-Path $PSScriptRoot 'modules\LocalIntune.ps1')
. (Join-Path $PSScriptRoot 'modules\SCCM.ps1')
. (Join-Path $PSScriptRoot 'modules\WindowsUpdate.ps1')

# Supporting modules
. (Join-Path $PSScriptRoot 'modules\Reporting.ps1')
. (Join-Path $PSScriptRoot 'modules\Interactive.ps1')
. (Join-Path $PSScriptRoot 'modules\Runspace.ps1')

# Orchestration must be last (depends on all modules)
. (Join-Path $PSScriptRoot 'modules\Orchestration.ps1')

# Main execution
try {
    # Stash credential for modules and set default credentials for remoting calls
    $script:Credential = $Credential
    if ($script:Credential) {
        $PSDefaultParameterValues['Invoke-Command:Credential'] = $script:Credential
        $PSDefaultParameterValues['New-CimSession:Credential'] = $script:Credential
        $PSDefaultParameterValues['Get-WmiObject:Credential'] = $script:Credential
    }

    $result = Invoke-DeviceDNACollection

    if (-not $result.Success) {
        Write-StatusMessage "Collection completed with errors. Check the report for details." -Type Warning
        exit 1
    }

    # Show appreciation call-to-action
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "   Found Device DNA helpful?" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "If this tool saved you time or made your work easier," -ForegroundColor White
    Write-Host "consider giving a " -NoNewline -ForegroundColor White
    Write-Host "Badge " -NoNewline -ForegroundColor Green
    Write-Host "to recognize the effort!" -ForegroundColor White
    Write-Host ""
    Write-Host "Author: " -NoNewline -ForegroundColor Gray
    Write-Host "Joshua Walderbach (j0w03ow)" -ForegroundColor White
    Write-Host "Badgify: " -NoNewline -ForegroundColor Gray
    Write-Host "https://internal.walmart.com/content/badgify/home/badgify.html" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Thank you for using Device DNA! " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    exit 0
}
catch {
    Write-StatusMessage "Unhandled exception: $($_.Exception.Message)" -Type Error
    Write-StatusMessage "Stack trace: $($_.ScriptStackTrace)" -Type Error
    exit 1
}
