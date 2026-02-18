<#
.SYNOPSIS
    Phase 3 End-to-End Test for DeviceDNA Template Migration
.DESCRIPTION
    Validates the complete DeviceDNA workflow with the new template + JSON architecture.
    Tests both the PowerShell data collection and the HTML template rendering.
.EXAMPLE
    .\Test-Phase3-EndToEnd.ps1
    .\Test-Phase3-EndToEnd.ps1 -SkipCollection  # Just test template with existing test data
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$SkipCollection,

    [Parameter()]
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Phase 3: End-to-End Test" -ForegroundColor Cyan
Write-Host "  DeviceDNA Template Migration" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$testResults = @()
$testsPassed = 0
$testsFailed = 0

function Test-Condition {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$SuccessMessage,
        [string]$FailureMessage
    )

    $script:testResults += @{
        Name = $Name
        Passed = $Condition
        Message = if ($Condition) { $SuccessMessage } else { $FailureMessage }
    }

    if ($Condition) {
        Write-Host "  ✅ $Name" -ForegroundColor Green
        if ($SuccessMessage) {
            Write-Host "     $SuccessMessage" -ForegroundColor Gray
        }
        $script:testsPassed++
    } else {
        Write-Host "  ❌ $Name" -ForegroundColor Red
        if ($FailureMessage) {
            Write-Host "     $FailureMessage" -ForegroundColor Red
        }
        $script:testsFailed++
    }
}

# Test 1: Validate File Structure
Write-Host "[1/6] Validating File Structure..." -ForegroundColor Yellow
Write-Host ""

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$templatesDir = Join-Path $scriptsRoot "templates"
$modulesDir = Join-Path $scriptsRoot "modules"

Test-Condition -Name "Templates directory exists" `
    -Condition (Test-Path $templatesDir) `
    -SuccessMessage "Found: $templatesDir" `
    -FailureMessage "Missing: $templatesDir"

$requiredTemplateFiles = @(
    "DeviceDNA-Report.html",
    "extracted-css.css",
    "extracted-javascript.js",
    "render-intune.js",
    "render-other-sections.js",
    "render-overview-device.js",
    "test-data.json"
)

foreach ($file in $requiredTemplateFiles) {
    $path = Join-Path $templatesDir $file
    Test-Condition -Name "Template file: $file" `
        -Condition (Test-Path $path) `
        -SuccessMessage "" `
        -FailureMessage "Missing: $path"
}

# Test 2: Validate PowerShell Functions
Write-Host ""
Write-Host "[2/6] Validating PowerShell Functions..." -ForegroundColor Yellow
Write-Host ""

$reportingPath = Join-Path $modulesDir "Reporting.ps1"
$orchestrationPath = Join-Path $modulesDir "Orchestration.ps1"

Test-Condition -Name "Reporting.ps1 exists" `
    -Condition (Test-Path $reportingPath) `
    -SuccessMessage "" `
    -FailureMessage "Missing: $reportingPath"

Test-Condition -Name "Orchestration.ps1 exists" `
    -Condition (Test-Path $orchestrationPath) `
    -SuccessMessage "" `
    -FailureMessage "Missing: $orchestrationPath"

# Check for new functions
$reportingContent = Get-Content $reportingPath -Raw
Test-Condition -Name "Export-DeviceDNAJson function exists" `
    -Condition ($reportingContent -match 'function Export-DeviceDNAJson') `
    -SuccessMessage "Found in Reporting.ps1" `
    -FailureMessage "Not found in Reporting.ps1"

Test-Condition -Name "Copy-DeviceDNATemplate function exists" `
    -Condition ($reportingContent -match 'function Copy-DeviceDNATemplate') `
    -SuccessMessage "Found in Reporting.ps1" `
    -FailureMessage "Not found in Reporting.ps1"

Test-Condition -Name "New-DeviceDNAReport function updated" `
    -Condition ($reportingContent -match 'function New-DeviceDNAReport' -and $reportingContent -match 'Export-DeviceDNAJson') `
    -SuccessMessage "Calls new export functions" `
    -FailureMessage "Still using old implementation"

# Test 3: Validate Template with Test Data
Write-Host ""
Write-Host "[3/6] Validating Template Rendering..." -ForegroundColor Yellow
Write-Host ""

$testDataPath = Join-Path $templatesDir "test-data.json"
if (Test-Path $testDataPath) {
    try {
        $testData = Get-Content $testDataPath -Raw | ConvertFrom-Json
        Test-Condition -Name "Test data is valid JSON" `
            -Condition ($null -ne $testData) `
            -SuccessMessage "Parsed successfully" `
            -FailureMessage "JSON parse failed"

        Test-Condition -Name "Test data has deviceInfo" `
            -Condition ($null -ne $testData.deviceInfo) `
            -SuccessMessage "deviceInfo.computerName = $($testData.deviceInfo.computerName)" `
            -FailureMessage "Missing deviceInfo section"

        Test-Condition -Name "Test data has intune section" `
            -Condition ($null -ne $testData.intune) `
            -SuccessMessage "$($testData.intune.deviceGroups.Count) device groups, $($testData.intune.configurationProfiles.Count) profiles" `
            -FailureMessage "Missing intune section"
    } catch {
        Test-Condition -Name "Test data is valid JSON" `
            -Condition $false `
            -FailureMessage "Error: $_"
    }
} else {
    Test-Condition -Name "Test data file exists" `
        -Condition $false `
        -FailureMessage "Missing: $testDataPath"
}

# Test 4: Run DeviceDNA Collection (if not skipped)
Write-Host ""
if ($SkipCollection) {
    Write-Host "[4/6] Skipping DeviceDNA Collection (use -SkipCollection:$false to test)" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "[4/6] Running DeviceDNA Collection..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This will run a real collection on the local device." -ForegroundColor Gray
    Write-Host "  Press Ctrl+C to cancel within 5 seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds 5

    $deviceDnaPath = Join-Path $scriptsRoot "DeviceDNA.ps1"

    if (Test-Path $deviceDnaPath) {
        try {
            Write-Host ""
            Write-Host "  Starting collection..." -ForegroundColor Cyan

            # Run DeviceDNA (no AutoOpen yet)
            & $deviceDnaPath -Verbose -ErrorAction Continue

            Test-Condition -Name "DeviceDNA collection completed" `
                -Condition ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) `
                -SuccessMessage "Collection successful" `
                -FailureMessage "Collection failed with exit code: $LASTEXITCODE"

            # Find the most recent output directory
            $outputDir = Join-Path $scriptsRoot "output"
            if (Test-Path $outputDir) {
                $latestDevice = Get-ChildItem $outputDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1

                if ($latestDevice) {
                    Write-Host ""
                    Write-Host "  Output directory: $($latestDevice.FullName)" -ForegroundColor Cyan

                    # Check for required output files
                    $jsonFile = Get-ChildItem $latestDevice.FullName -Filter "*.json" | Select-Object -First 1
                    $templateFile = Get-ChildItem $latestDevice.FullName -Filter "DeviceDNA-Report.html" | Select-Object -First 1

                    Test-Condition -Name "JSON data file created" `
                        -Condition ($null -ne $jsonFile) `
                        -SuccessMessage "Found: $($jsonFile.Name) ($([math]::Round($jsonFile.Length/1KB, 2)) KB)" `
                        -FailureMessage "No JSON file found in output directory"

                    Test-Condition -Name "Template file copied" `
                        -Condition ($null -ne $templateFile) `
                        -SuccessMessage "Found: $($templateFile.Name)" `
                        -FailureMessage "Template not copied to output directory"

                    # Check for render modules
                    $renderFiles = Get-ChildItem $latestDevice.FullName -Filter "render-*.js"
                    Test-Condition -Name "Render modules copied" `
                        -Condition ($renderFiles.Count -eq 3) `
                        -SuccessMessage "Found 3 render modules" `
                        -FailureMessage "Expected 3 render modules, found $($renderFiles.Count)"

                    # If OpenReport is specified, open the report
                    if ($OpenReport -and $templateFile -and $jsonFile) {
                        Write-Host ""
                        Write-Host "  Opening report in browser..." -ForegroundColor Cyan
                        $reportUrl = "file:///$($templateFile.FullName.Replace('\', '/'))?data=$($jsonFile.Name)"
                        Start-Process $reportUrl
                    }
                }
            }
        } catch {
            Test-Condition -Name "DeviceDNA collection completed" `
                -Condition $false `
                -FailureMessage "Error: $_"
        }
    } else {
        Test-Condition -Name "DeviceDNA.ps1 exists" `
            -Condition $false `
            -FailureMessage "Not found: $deviceDnaPath"
    }
}

# Test 5: Verify Code Reduction
Write-Host ""
Write-Host "[5/6] Verifying Code Reduction..." -ForegroundColor Yellow
Write-Host ""

$reportingLines = (Get-Content $reportingPath).Count
Test-Condition -Name "Reporting.ps1 reduced to ~5300 lines" `
    -Condition ($reportingLines -lt 5500 -and $reportingLines -gt 5000) `
    -SuccessMessage "$reportingLines lines (down from 7207)" `
    -FailureMessage "$reportingLines lines (expected 5000-5500)"

# Test 6: Critical Alignment Test
Write-Host ""
Write-Host "[6/6] Template Alignment Test Instructions..." -ForegroundColor Yellow
Write-Host ""
Write-Host "  To verify column alignment is fixed:" -ForegroundColor Cyan
Write-Host "  1. Open the generated report in a browser" -ForegroundColor Gray
Write-Host "  2. Navigate to Intune > Entra ID - Device Groups" -ForegroundColor Gray
Write-Host "  3. Open browser DevTools (F12)" -ForegroundColor Gray
Write-Host "  4. Paste this into the console:" -ForegroundColor Gray
Write-Host ""
Write-Host @"
const table = document.querySelector('#device-groups-content table');
if (table) {
    const firstHeader = table.querySelector('thead th');
    const firstCell = table.querySelector('tbody tr td');
    const offset = Math.round(firstHeader.getBoundingClientRect().left - firstCell.getBoundingClientRect().left);
    console.log('Offset:', offset, offset === 0 ? '✅ ALIGNED' : '❌ MISALIGNED');
} else {
    console.log('❌ Table not found');
}
"@ -ForegroundColor Yellow
Write-Host ""
Write-Host "  Expected: 'Offset: 0 ✅ ALIGNED'" -ForegroundColor Green
Write-Host ""

# Summary
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Test Summary" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed: $testsPassed" -ForegroundColor Green
Write-Host "  Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

if ($testsFailed -eq 0) {
    Write-Host "✅ All tests passed! Phase 3 looks good." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Test the report in a browser" -ForegroundColor Gray
    Write-Host "  2. Verify column alignment (see instructions above)" -ForegroundColor Gray
    Write-Host "  3. Test all interactive features (sorting, filtering, expanding)" -ForegroundColor Gray
    Write-Host "  4. Test AutoOpen: .\DeviceDNA.ps1 -AutoOpen" -ForegroundColor Gray
} else {
    Write-Host "❌ Some tests failed. Review errors above." -ForegroundColor Red
}
Write-Host ""

# Return test results
return @{
    Passed = $testsPassed
    Failed = $testsFailed
    Results = $testResults
}
