# Configuration Profile Settings Collection Test

## Purpose
This test script demonstrates how to collect the specific settings configured in Intune configuration profiles, answering the question: "What is each profile actually configuring?"

## What It Does

### 1. Legacy Device Configuration Profiles (v1.0)
- Retrieves all `deviceConfiguration` profiles from `/deviceManagement/deviceConfigurations`
- For each profile, fetches the full details including all configured settings
- Examples of profile types:
  - `windows10GeneralConfiguration` - General Windows 10 settings
  - `androidWorkProfileGeneralDeviceConfiguration` - Android Work Profile settings
  - `iosGeneralDeviceConfiguration` - iOS general settings
  - Email profiles, VPN profiles, Wi-Fi profiles, etc.

### 2. Settings Catalog Configuration Policies (beta)
- Retrieves all `configurationPolicies` from `/deviceManagement/configurationPolicies`
- For each policy, fetches the settings collection
- Settings are structured as instances with specific value types:
  - Choice settings (dropdowns)
  - Simple settings (strings, integers)
  - Group settings (collections)

## How Settings Are Structured

### Legacy Profiles
Settings are direct properties on the profile object:
```json
{
  "@odata.type": "#microsoft.graph.windows10GeneralConfiguration",
  "displayName": "Corporate Security Settings",
  "passwordRequired": true,
  "passwordMinimumLength": 8,
  "passwordRequiredType": "alphanumeric",
  "bluetoothBlocked": false,
  "cameraBlocked": false,
  "startMenuHideFrequentlyUsedApps": true
}
```

### Settings Catalog
Settings are a collection with definition IDs and typed values:
```json
{
  "settingInstance": {
    "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
    "settingDefinitionId": "device_vendor_msft_policy_config_bitlocker_...",
    "choiceSettingValue": {
      "value": "device_vendor_msft_policy_config_bitlocker_..._1"
    }
  }
}
```

## Usage

### Basic Usage
```powershell
.\tests\Test-ConfigProfileSettings.ps1 -DeviceName "PC001"
```

### Custom Output Path
```powershell
.\tests\Test-ConfigProfileSettings.ps1 -DeviceName "PC001" -OutputPath "C:\temp\profile-settings"
```

**Note:**
- The script requires a device name and only collects configuration profiles assigned to that specific device (avoiding 1000+ tenant profiles)
- Both legacy profiles AND Settings Catalog policies are collected automatically - no switches needed

## Output

The script creates JSON files for each profile in the output directory:

```
tests/output/
  Corporate_Security_Settings_Settings.json
  Android_Work_Profile_Settings.json
  BitLocker_Policy_Settings.json
  ...
```

Each JSON file contains:
- Profile name and type
- Collection timestamp
- All configured settings with friendly values

## Example Output

### Console
```
[2026-02-13 14:30:15] [Info] === Configuration Profile Settings Collection Test ===
[2026-02-13 14:30:15] [Info] Checking Microsoft Graph connection...
[2026-02-13 14:30:15] [Success]   Connected as: admin@contoso.com
[2026-02-13 14:30:15] [Success]   Tenant: 12345678-1234-1234-1234-123456789012

[2026-02-13 14:30:16] [Info] === Collecting Device Configuration Profiles Assigned to PC001 ===
[2026-02-13 14:30:16] [Info] API Call: GET https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/.../deviceConfigurationStates
[2026-02-13 14:30:17] [Success]   Found 5 assigned configuration profiles

[2026-02-13 14:30:17] [Info] Profile: Corporate Security Settings
[2026-02-13 14:30:17] [Info]   Type: #microsoft.graph.windows10GeneralConfiguration
[2026-02-13 14:30:17] [Info]   ID: abc123...
[2026-02-13 14:30:18] [Info]     passwordRequired = Enabled
[2026-02-13 14:30:18] [Info]     passwordMinimumLength = 8
[2026-02-13 14:30:18] [Info]     passwordRequiredType = alphanumeric
[2026-02-13 14:30:18] [Info]     bluetoothBlocked = Disabled
[2026-02-13 14:30:18] [Info]     cameraBlocked = Disabled
[2026-02-13 14:30:18] [Info]     ... and 47 more settings
[2026-02-13 14:30:18] [Success]   Total configured settings: 52
[2026-02-13 14:30:18] [Success]   Exported to: ./tests/output/Corporate_Security_Settings_Settings.json
```

### JSON File
```json
{
  "ProfileName": "Corporate Security Settings",
  "ProfileType": "#microsoft.graph.windows10GeneralConfiguration",
  "CollectedAt": "2026-02-13 14:30:18",
  "Settings": {
    "passwordRequired": "Enabled",
    "passwordMinimumLength": 8,
    "passwordRequiredType": "alphanumeric",
    "passwordMinimumCharacterSetCount": 3,
    "passwordPreviousPasswordBlockCount": 5,
    "passwordExpirationDays": 90,
    "bluetoothBlocked": "Disabled",
    "cameraBlocked": "Disabled",
    "startMenuHideFrequentlyUsedApps": "Enabled",
    "...": "..."
  }
}
```

## Requirements

- PowerShell 5.1 or higher
- Microsoft.Graph.Authentication module
- Graph API permissions: `DeviceManagementConfiguration.Read.All`

## How This Relates to Device DNA

This test script demonstrates the approach that should be used in the main Device DNA script to:

1. Collect what settings each configuration profile is configuring
2. Display those settings in the HTML report
3. Allow admins to understand not just "which profiles are assigned" but "what each profile is actually doing"

## Microsoft Documentation References

- [deviceConfiguration GET](https://learn.microsoft.com/graph/api/intune-deviceconfig-deviceconfiguration-get?view=graph-rest-1.0)
- [windows10GeneralConfiguration](https://learn.microsoft.com/graph/api/resources/intune-deviceconfig-windows10generalconfiguration?view=graph-rest-1.0)
- [deviceManagementConfigurationPolicy](https://learn.microsoft.com/graph/api/resources/intune-deviceconfigv2-devicemanagementconfigurationpolicy?view=graph-rest-beta)
- [deviceManagementConfigurationSetting](https://learn.microsoft.com/graph/api/resources/intune-deviceconfigv2-devicemanagementconfigurationsetting?view=graph-rest-beta)
