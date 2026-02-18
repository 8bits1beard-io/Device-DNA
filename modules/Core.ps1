<#
.SYNOPSIS
    Device DNA - Core Module
.DESCRIPTION
    Defines shared script-level variables and constants used across all modules.
    This module must be loaded first to ensure all modules have access to shared state.
.NOTES
    Module: Core.ps1
    Dependencies: None
    Version: 0.2.0
#>

# Script version
$script:Version = "0.2.0"

# Collection state tracking
$script:CollectionIssues = @()
$script:CollectionStartTime = $null

# Logging configuration
$script:LogFilePath = $null
$script:LoggingEnabled = $false

# Microsoft Graph API state
$script:GraphConnected = $false
$script:RequiredGraphScopes = @(
    'DeviceManagementConfiguration.Read.All',
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementApps.Read.All',
    'Directory.Read.All',
    'Device.Read.All'
)

# Target configuration (set during orchestration)
$script:TargetComputer = $null

# Group name cache for resolving group IDs to display names
$script:GroupNameCache = @{}

# Execution timing
$script:StartTime = $null
$script:EndTime = $null
