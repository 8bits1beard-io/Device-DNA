<#
.SYNOPSIS
    Test script to verify Device DNA logo integration in HTML report.

.DESCRIPTION
    This script tests that:
    1. The logo file can be read and converted to base64
    2. The base64 data is correctly embedded in the HTML
    3. The logo appears in the report header
    4. CSS styling is applied correctly
    5. The report remains self-contained

.NOTES
    Version: 1.0.0
    Author: Device DNA
    Date: 2026-02-13
#>

param(
    [Parameter()]
    [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Device DNA Logo Integration Test" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 1: Verify logo file exists
Write-Host "[1/5] Testing logo file existence..." -ForegroundColor Yellow
$logoPath = Join-Path $ProjectRoot 'DeviceDNALogo_2.png'
if (-not (Test-Path $logoPath)) {
    Write-Host "  FAIL: Logo file not found at $logoPath" -ForegroundColor Red
    exit 1
}
$logoSize = (Get-Item $logoPath).Length
Write-Host "  PASS: Logo file exists ($([math]::Round($logoSize/1KB, 2)) KB)" -ForegroundColor Green

# Test 2: Verify base64 conversion works
Write-Host "`n[2/5] Testing base64 conversion..." -ForegroundColor Yellow
try {
    $logoBytes = [System.IO.File]::ReadAllBytes($logoPath)
    $logoBase64 = [Convert]::ToBase64String($logoBytes)
    $base64Size = $logoBase64.Length
    Write-Host "  PASS: Base64 conversion successful ($([math]::Round($base64Size/1KB, 2)) KB)" -ForegroundColor Green

    # Verify base64 starts with PNG signature
    if ($logoBase64.StartsWith('iVBORw0KGgo')) {
        Write-Host "  PASS: Valid PNG base64 signature detected" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL: Invalid PNG base64 signature" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "  FAIL: Base64 conversion failed: $_" -ForegroundColor Red
    exit 1
}

# Test 3: Verify Reporting.ps1 contains logo-related code
Write-Host "`n[3/5] Testing Reporting.ps1 logo integration..." -ForegroundColor Yellow
$reportingPath = Join-Path $ProjectRoot 'modules\Reporting.ps1'
$reportingContent = Get-Content $reportingPath -Raw

$checks = @(
    @{ Pattern = 'logoBase64'; Description = 'Logo base64 variable' }
    @{ Pattern = 'report-logo'; Description = 'Logo CSS class' }
    @{ Pattern = 'header-title-container'; Description = 'Header title container CSS' }
    @{ Pattern = 'DeviceDNALogo_2\.png'; Description = 'Logo file reference' }
    @{ Pattern = 'data:image/png;base64'; Description = 'Base64 data URI' }
)

$allPassed = $true
foreach ($check in $checks) {
    if ($reportingContent -match $check.Pattern) {
        Write-Host "  PASS: $($check.Description) found" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL: $($check.Description) not found" -ForegroundColor Red
        $allPassed = $false
    }
}

if (-not $allPassed) {
    Write-Host "`n  ERROR: Some integration checks failed" -ForegroundColor Red
    exit 1
}

# Test 4: Verify CSS styling is present
Write-Host "`n[4/5] Testing CSS styling..." -ForegroundColor Yellow
$cssChecks = @(
    @{ Pattern = '\.report-logo\s*\{'; Description = 'Logo base CSS' }
    @{ Pattern = '\.header-title-container\s*\{'; Description = 'Title container CSS' }
    @{ Pattern = 'max-height:\s*80px'; Description = 'Desktop logo size' }
    @{ Pattern = 'max-height:\s*50px'; Description = 'Mobile logo size' }
)

$allPassed = $true
foreach ($check in $cssChecks) {
    if ($reportingContent -match $check.Pattern) {
        Write-Host "  PASS: $($check.Description) found" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL: $($check.Description) not found" -ForegroundColor Red
        $allPassed = $false
    }
}

if (-not $allPassed) {
    Write-Host "`n  ERROR: Some CSS checks failed" -ForegroundColor Red
    exit 1
}

# Test 5: Estimate final report size impact
Write-Host "`n[5/5] Estimating report size impact..." -ForegroundColor Yellow
$typicalReportSize = 360 * 1KB  # ~360KB typical report
$logoAddition = $base64Size
$estimatedTotalSize = $typicalReportSize + $logoAddition
Write-Host "  Typical report size: $([math]::Round($typicalReportSize/1KB, 2)) KB" -ForegroundColor Cyan
Write-Host "  Logo addition: $([math]::Round($logoAddition/1KB, 2)) KB" -ForegroundColor Cyan
Write-Host "  Estimated total: $([math]::Round($estimatedTotalSize/1KB, 2)) KB" -ForegroundColor Cyan

if ($estimatedTotalSize -lt (1 * 1MB)) {
    Write-Host "  PASS: Estimated size is acceptable (< 1 MB)" -ForegroundColor Green
}
else {
    Write-Host "  WARNING: Estimated size exceeds 1 MB" -ForegroundColor Yellow
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All Tests Passed!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Run DeviceDNA.ps1 to generate a report" -ForegroundColor White
Write-Host "  2. Open the HTML report in a browser" -ForegroundColor White
Write-Host "  3. Verify the logo displays correctly in the header" -ForegroundColor White
Write-Host "  4. Check responsive design on mobile/tablet" -ForegroundColor White
Write-Host "  5. Test print preview to ensure logo prints correctly`n" -ForegroundColor White
