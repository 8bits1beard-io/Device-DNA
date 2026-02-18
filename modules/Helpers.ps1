<#
.SYNOPSIS
    Device DNA - Helpers Module
.DESCRIPTION
    General utility functions used across multiple modules.
    Includes status messaging, admin checks, tenant ID discovery, etc.
.NOTES
    Module: Helpers.ps1
    Dependencies: Core.ps1, Logging.ps1
    Version: 0.2.0
#>

function Test-IsLocalComputer {
    param([string]$ComputerName)

    return [string]::IsNullOrEmpty($ComputerName) -or
           $ComputerName -eq 'localhost' -or
           $ComputerName -eq '127.0.0.1' -or
           $ComputerName -eq '.' -or
           $ComputerName -eq $env:COMPUTERNAME -or
           $ComputerName -ieq $env:COMPUTERNAME  # Case-insensitive compare
}

function Write-StatusMessage {
    <#
    .SYNOPSIS
        Writes formatted status messages to the console with visual indicators.
        Also logs to the CMTrace-compatible log file if logging is enabled.
    .PARAMETER Message
        The message to display.
    .PARAMETER Type
        The type of message: Info, Success, Warning, Error, Progress.
    .PARAMETER NoNewline
        Do not append a newline character.
    .PARAMETER Component
        Optional component name for CMTrace logging. If not specified, attempts to detect from call stack.
    .PARAMETER SkipLog
        If specified, do not write to the log file (console only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Progress')]
        [string]$Type = 'Info',

        [Parameter()]
        [switch]$NoNewline,

        [Parameter()]
        [string]$Component,

        [Parameter()]
        [switch]$SkipLog
    )

    try {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $prefix = ""
        $color = [System.ConsoleColor]::White
        $logType = 1  # Default to Info

        switch ($Type) {
            'Info' {
                $prefix = "[i]"
                $color = [System.ConsoleColor]::Cyan
                $logType = 1
            }
            'Success' {
                $prefix = "[+]"
                $color = [System.ConsoleColor]::Green
                $logType = 1
            }
            'Warning' {
                $prefix = "[!]"
                $color = [System.ConsoleColor]::Yellow
                $logType = 2
            }
            'Error' {
                $prefix = "[X]"
                $color = [System.ConsoleColor]::Red
                $logType = 3
            }
            'Progress' {
                $prefix = "[>]"
                $color = [System.ConsoleColor]::Magenta
                $logType = 1
            }
        }

        $formattedMessage = "[$timestamp] $prefix $Message"

        if ($NoNewline) {
            Write-Host $formattedMessage -ForegroundColor $color -NoNewline
        }
        else {
            Write-Host $formattedMessage -ForegroundColor $color
        }

        # Also write to verbose stream if enabled
        Write-Verbose $formattedMessage

        # Write to CMTrace log file if logging is enabled
        if (-not $SkipLog -and $script:LoggingEnabled) {
            # Determine component from call stack if not provided
            $logComponent = $Component
            if (-not $logComponent) {
                $callStack = Get-PSCallStack
                if ($callStack.Count -gt 1) {
                    # Get the immediate caller's function name
                    $caller = $callStack[1]
                    $logComponent = if ($caller.FunctionName -and $caller.FunctionName -ne '<ScriptBlock>') {
                        $caller.FunctionName
                    } else {
                        "DeviceDNA"
                    }
                } else {
                    $logComponent = "DeviceDNA"
                }
            }

            Write-DeviceDNALog -Message $Message -Component $logComponent -Type $logType
        }
    }
    catch {
        # Fallback to basic Write-Host if anything fails
        Write-Host $Message
    }
}

function Test-AdminRights {
    <#
    .SYNOPSIS
        Checks if the current session has administrator privileges.
    .PARAMETER ComputerName
        Optional computer name for remote admin check.
    .OUTPUTS
        Boolean indicating admin status.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    try {
        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            # Local admin check - no WinRM overhead
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
            return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        else {
            # Remote admin check using CIM
            try {
                $cimSession = New-CimSession -ComputerName $ComputerName -ErrorAction Stop
                $null = Get-CimInstance -CimSession $cimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
                Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
                return $true
            }
            catch {
                # Try WMI as fallback
                try {
                    $null = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction Stop
                    return $true
                }
                catch {
                    $script:CollectionIssues += @{ severity = "Warning"; phase = "Setup"; message = "Failed to verify admin rights on $ComputerName : $($_.Exception.Message)" }
                    return $false
                }
            }
        }
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Error checking admin rights: $($_.Exception.Message)" }
        return $false
    }
}

function Get-TenantId {
    <#
    .SYNOPSIS
        Discovers the Azure AD tenant ID from device registration or OpenID discovery.
    .PARAMETER DsregOutput
        Optional dsregcmd output to parse. If not provided, will execute dsregcmd.
    .PARAMETER Domain
        Optional domain for OpenID discovery fallback.
    .OUTPUTS
        Tenant ID string or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DsregOutput,

        [Parameter()]
        [string]$Domain
    )

    try {
        # First, try to parse from dsregcmd output
        if (-not [string]::IsNullOrEmpty($DsregOutput)) {
            if ($DsregOutput -match 'TenantId\s*:\s*([\w-]+)') {
                return $Matches[1]
            }
        }
        else {
            # Execute dsregcmd to get tenant info
            try {
                $dsregOutput = & dsregcmd /status 2>&1
                if ($dsregOutput -match 'TenantId\s*:\s*([\w-]+)') {
                    return $Matches[1]
                }
            }
            catch {
                Write-StatusMessage "Could not execute dsregcmd: $($_.Exception.Message)" -Type Warning
            }
        }

        # Fallback: OpenID discovery endpoint
        if (-not [string]::IsNullOrEmpty($Domain)) {
            try {
                $openIdUrl = "https://login.microsoftonline.com/$Domain/.well-known/openid-configuration"

                # Use TLS 1.2
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

                $response = Invoke-RestMethod -Uri $openIdUrl -Method Get -TimeoutSec 10 -ErrorAction Stop

                if ($response.issuer -match '/([a-f0-9-]{36})/?') {
                    return $Matches[1]
                }
            }
            catch {
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Setup"; message = "OpenID discovery failed for $Domain : $($_.Exception.Message)" }
            }
        }

        return $null
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Error in Get-TenantId: $($_.Exception.Message)" }
        return $null
    }
}
