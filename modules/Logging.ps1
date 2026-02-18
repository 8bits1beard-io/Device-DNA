<#
.SYNOPSIS
    Device DNA - Logging Module
.DESCRIPTION
    CMTrace/OneTrace compatible logging infrastructure.
    Provides functions for creating, writing to, and finalizing log files.
.NOTES
    Module: Logging.ps1
    Dependencies: Core.ps1
    Version: 0.2.0
#>

function Write-DeviceDNALog {
    <#
    .SYNOPSIS
        Writes a log entry in CMTrace/OneTrace compatible format.
    .DESCRIPTION
        Creates log entries that can be opened and parsed by CMTrace or OneTrace.
        Format: <![LOG[message]LOG]!><time="HH:mm:ss.fff+000" date="MM-DD-YYYY" component="Name" context="" type="N" thread="N" file="">
    .PARAMETER Message
        The log message text.
    .PARAMETER Component
        The component/function name writing the log entry. Used for filtering in CMTrace.
    .PARAMETER Type
        Log level: 1 = Info, 2 = Warning, 3 = Error
    .PARAMETER IsDebug
        If true, only logs when -Verbose is specified and prefixes message with "DEBUG:"
    .EXAMPLE
        Write-DeviceDNALog -Message "Found Azure AD device" -Component "Find-AzureADDevice" -Type 1
    .EXAMPLE
        Write-DeviceDNALog -Message "Query response details" -Component "Get-IntuneData" -Type 1 -IsDebug
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [string]$Component = "DeviceDNA",

        [Parameter(Position = 2)]
        [ValidateSet(1, 2, 3)]
        [int]$Type = 1,

        [Parameter()]
        [switch]$IsDebug
    )

    # Skip if logging not enabled or no log file path
    if (-not $script:LoggingEnabled -or -not $script:LogFilePath) {
        return
    }

    # Skip debug messages unless verbose is enabled
    if ($IsDebug -and -not $VerbosePreference -eq 'Continue') {
        return
    }

    try {
        # Prefix debug messages
        $logMessage = if ($IsDebug) { "DEBUG: $Message" } else { $Message }

        # Sanitize message - remove any potential sensitive data patterns
        # Remove anything that looks like a token/key (long base64-like strings)
        $logMessage = $logMessage -replace '[A-Za-z0-9+/=]{50,}', '[REDACTED]'
        # Remove Bearer tokens
        $logMessage = $logMessage -replace 'Bearer\s+[^\s]+', 'Bearer [REDACTED]'

        # Build CMTrace format timestamp
        $now = Get-Date
        $time = $now.ToString("HH:mm:ss.fff") + "+000"
        $date = $now.ToString("MM-dd-yyyy")
        $threadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId

        # CMTrace format
        $logEntry = "<![LOG[$logMessage]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$threadId`" file=`"`">"

        # Append to log file
        Add-Content -Path $script:LogFilePath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Silently fail - don't break the script for logging issues
    }
}

function Initialize-DeviceDNALog {
    <#
    .SYNOPSIS
        Initializes the log file and writes the header entries.
    .PARAMETER OutputPath
        Directory where the log file will be created.
    .PARAMETER TargetDevice
        The device name being scanned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetDevice
    )

    try {
        # Generate log filename with same convention as report
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $logFileName = "DeviceDNA_${TargetDevice}_${timestamp}.log"
        $script:LogFilePath = Join-Path -Path $OutputPath -ChildPath $logFileName
        $script:LoggingEnabled = $true
        $script:CollectionStartTime = Get-Date

        # Create log file with header entries
        $null = New-Item -Path $script:LogFilePath -ItemType File -Force -ErrorAction Stop

        # Write header information
        Write-DeviceDNALog -Message "========== DeviceDNA Collection Started ==========" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "DeviceDNA Version: $($script:Version)" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "Target Device: $TargetDevice" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "PowerShell Version: $($PSVersionTable.PSVersion.ToString())" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "PowerShell Edition: $($PSVersionTable.PSEdition)" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "OS: $([System.Environment]::OSVersion.VersionString)" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "Current User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "Log File: $($script:LogFilePath)" -Component "Initialize" -Type 1
        Write-DeviceDNALog -Message "=================================================" -Component "Initialize" -Type 1

        return $script:LogFilePath
    }
    catch {
        $script:LoggingEnabled = $false
        Write-Warning "Failed to initialize log file: $($_.Exception.Message)"
        return $null
    }
}

function Complete-DeviceDNALog {
    <#
    .SYNOPSIS
        Writes the final log entries and collection summary.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:LoggingEnabled -or -not $script:LogFilePath) {
        return
    }

    try {
        $duration = if ($script:CollectionStartTime) {
            (Get-Date) - $script:CollectionStartTime
        } else {
            [TimeSpan]::Zero
        }

        Write-DeviceDNALog -Message "=================================================" -Component "Complete" -Type 1
        Write-DeviceDNALog -Message "========== DeviceDNA Collection Complete ==========" -Component "Complete" -Type 1
        Write-DeviceDNALog -Message "Total Duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Component "Complete" -Type 1
        Write-DeviceDNALog -Message "Collection Issues: $($script:CollectionIssues.Count)" -Component "Complete" -Type $(if ($script:CollectionIssues.Count -gt 0) { 2 } else { 1 })

        if ($script:CollectionIssues.Count -gt 0) {
            foreach ($issue in $script:CollectionIssues) {
                # Handle both string and hashtable formats
                if ($issue -is [hashtable]) {
                    $severity = if ($issue.severity) { $issue.severity } else { 'Info' }
                    $phase = if ($issue.phase) { $issue.phase } else { 'Unknown' }
                    $message = if ($issue.message) { $issue.message } else { 'No message' }
                    Write-DeviceDNALog -Message "Issue [$severity - $phase]: $message" -Component "Complete" -Type 2
                } else {
                    Write-DeviceDNALog -Message "Issue: $issue" -Component "Complete" -Type 2
                }
            }
        }

        Write-DeviceDNALog -Message "Log file saved to: $($script:LogFilePath)" -Component "Complete" -Type 1
    }
    catch {
        # Silently fail
    }
}
