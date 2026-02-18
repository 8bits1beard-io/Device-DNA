<#
.SYNOPSIS
    Device DNA - Runspace Module
.DESCRIPTION
    Parallel execution helpers using PowerShell runspaces.
    Currently unused but reserved for future parallelization of collection operations.
.NOTES
    Module: Runspace.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
#>

function Initialize-RunspacePool {
    <#
    .SYNOPSIS
        Creates a runspace pool for parallel execution.
    .PARAMETER MaxThreads
        Maximum number of concurrent threads (default: 5).
    .OUTPUTS
        RunspacePool object.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$MaxThreads = 5
    )

    try {
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

        # Add script-level variables to the session state
        $sessionState.Variables.Add(
            (New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('CollectionIssues', @(), $null))
        )

        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
            1,          # Min runspaces
            $MaxThreads, # Max runspaces
            $sessionState,
            $Host
        )

        $runspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
        $runspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspacePool.Open()

        Write-StatusMessage "Runspace pool initialized with $MaxThreads threads" -Type Info

        return $runspacePool
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Failed to initialize runspace pool: $($_.Exception.Message)" }
        Write-StatusMessage "Failed to initialize runspace pool: $($_.Exception.Message)" -Type Error
        return $null
    }
}

function Invoke-Parallel {
    <#
    .SYNOPSIS
        Executes scriptblocks in parallel using runspaces.
    .PARAMETER ScriptBlocks
        Array of scriptblocks to execute.
    .PARAMETER Parameters
        Array of parameter hashtables corresponding to each scriptblock.
    .PARAMETER RunspacePool
        The runspace pool to use.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for all jobs (default: 300).
    .OUTPUTS
        Array of results from each scriptblock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock[]]$ScriptBlocks,

        [Parameter()]
        [hashtable[]]$Parameters,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.RunspacePool]$RunspacePool,

        [Parameter()]
        [int]$TimeoutSeconds = 300
    )

    $results = @()
    $jobs = @()

    try {
        # Create and start all jobs
        for ($i = 0; $i -lt $ScriptBlocks.Count; $i++) {
            $powerShell = [System.Management.Automation.PowerShell]::Create()
            $powerShell.RunspacePool = $RunspacePool

            $null = $powerShell.AddScript($ScriptBlocks[$i])

            # Add parameters if provided
            if ($Parameters -and $Parameters.Count -gt $i -and $Parameters[$i]) {
                foreach ($key in $Parameters[$i].Keys) {
                    $null = $powerShell.AddParameter($key, $Parameters[$i][$key])
                }
            }

            $job = @{
                PowerShell = $powerShell
                Handle     = $powerShell.BeginInvoke()
                Index      = $i
            }

            $jobs += $job
        }

        Write-StatusMessage "Started $($jobs.Count) parallel tasks" -Type Progress

        # Wait for all jobs to complete
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $completedCount = 0

        while ($jobs.Where({ -not $_.Handle.IsCompleted }).Count -gt 0) {
            if ($stopwatch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                Write-StatusMessage "Parallel execution timeout reached ($TimeoutSeconds seconds)" -Type Warning
                $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Parallel execution timeout after $TimeoutSeconds seconds" }
                break
            }

            $newlyCompleted = $jobs.Where({ $_.Handle.IsCompleted -and -not $_.Collected })
            foreach ($job in $newlyCompleted) {
                $completedCount++
                $job.Collected = $true
            }

            Start-Sleep -Milliseconds 100
        }

        $stopwatch.Stop()

        # Collect results
        foreach ($job in $jobs | Sort-Object Index) {
            try {
                if ($job.Handle.IsCompleted) {
                    $result = $job.PowerShell.EndInvoke($job.Handle)
                    $results += @{
                        Index  = $job.Index
                        Result = $result
                        Errors = $job.PowerShell.Streams.Error
                    }

                    if ($job.PowerShell.Streams.Error.Count -gt 0) {
                        foreach ($err in $job.PowerShell.Streams.Error) {
                            $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Task $($job.Index) error: $($err.Exception.Message)" }
                        }
                    }
                }
                else {
                    $results += @{
                        Index  = $job.Index
                        Result = $null
                        Errors = @("Task did not complete within timeout")
                    }
                    $script:CollectionIssues += @{ severity = "Warning"; phase = "Setup"; message = "Task $($job.Index) did not complete within timeout" }
                }
            }
            catch {
                $results += @{
                    Index  = $job.Index
                    Result = $null
                    Errors = @($_.Exception.Message)
                }
                $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Failed to collect result from task $($job.Index): $($_.Exception.Message)" }
            }
            finally {
                $job.PowerShell.Dispose()
            }
        }

        Write-StatusMessage "Completed $($results.Count) parallel tasks in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 2)) seconds" -Type Success
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Setup"; message = "Error in Invoke-Parallel: $($_.Exception.Message)" }
        Write-StatusMessage "Parallel execution error: $($_.Exception.Message)" -Type Error
    }

    return $results
}

function Close-RunspacePool {
    <#
    .SYNOPSIS
        Closes and disposes a runspace pool.
    .PARAMETER RunspacePool
        The runspace pool to close.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.RunspacePool]$RunspacePool
    )

    try {
        if ($RunspacePool) {
            $RunspacePool.Close()
            $RunspacePool.Dispose()
            Write-StatusMessage "Runspace pool closed" -Type Info
        }
    }
    catch {
        $script:CollectionIssues += @{ severity = "Warning"; phase = "Setup"; message = "Error closing runspace pool: $($_.Exception.Message)" }
    }
}
