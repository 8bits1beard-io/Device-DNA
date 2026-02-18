<#
.SYNOPSIS
    Device DNA - Windows Update Module
.DESCRIPTION
    Collects Windows Update configuration, status, and history from the target device.
    Reads 10 registry hives covering GPO/MDM update policies, runtime state, OS version,
    and Delivery Optimization settings. Queries the Windows Update Agent (WUA) COM API
    for pending updates and install history.

    Registry hives examined:
    1.  HKLM\...\Policies\...\WindowsUpdate          (GPO: update source, deferrals, active hours)
    2.  HKLM\...\Policies\...\WindowsUpdate\AU        (GPO: automatic update behavior, WSUS, restart)
    3.  HKLM\...\WindowsUpdate\UpdatePolicy\Settings   (Runtime: pause state)
    4.  HKLM\...\WindowsUpdate\UX\Settings             (User: Settings app preferences)
    5.  HKLM\...\WindowsUpdate\Auto Update             (Runtime: reboot pending)
    6.  HKLM\...\Auto Update\Results\Detect            (Last scan timestamp + error)
    7.  HKLM\...\Auto Update\Results\Install           (Last install timestamp + error)
    8.  HKLM\...\Auto Update\Results\Download          (Last download timestamp + error)
    9.  HKLM\...\Windows NT\CurrentVersion             (OS build, UBR, edition)
    10. HKLM\...\Policies\...\DeliveryOptimization     (P2P delivery mode, bandwidth, cache)

    Ref: https://learn.microsoft.com/windows/deployment/update/waas-configure-wufb
    Ref: https://learn.microsoft.com/windows/win32/wua_sdk/windows-update-agent-object-model
    Ref: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-deliveryoptimization
.NOTES
    Module: WindowsUpdate.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
#>

#region Registry Hive Definitions
$script:WURegistryHives = @(
    @{
        # Ref: https://learn.microsoft.com/windows/deployment/update/waas-configure-wufb
        # Ref: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-update
        Name = 'WindowsUpdate Policy'
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        Description = 'GPO/MDM-controlled update source, deferrals, and active hours'
        IgnoreExtra = $false
        KnownKeys = @{
            'WUServer'                               = @{ Type = 'REG_SZ';    Meaning = 'WSUS server URL'; Description = 'URL of the intranet WSUS server used for scanning and downloading updates instead of Windows Update.' }
            'WUStatusServer'                         = @{ Type = 'REG_SZ';    Meaning = 'WSUS status reporting URL'; Description = 'URL of the intranet server to which update status and statistics are uploaded. Typically the same as WUServer.' }
            'DoNotConnectToWindowsUpdateInternetLocations' = @{ Type = 'REG_DWORD'; Meaning = '1=Block WU internet (WSUS only)'; Description = 'Prevents connecting to public Windows Update, Microsoft Update, or Store services. Only applies when an intranet WSUS server is configured.' }
            'DisableWindowsUpdateAccess'             = @{ Type = 'REG_DWORD'; Meaning = '1=Disable WU access entirely'; Description = 'Removes access to scan, download, and install from Windows Update in the Settings UI. Background updates configured by policy still work.' }
            'SetActiveHours'                         = @{ Type = 'REG_DWORD'; Meaning = '0=Disabled, 1=Enabled'; Description = 'Enables the active hours policy, which prevents automatic restart after updates during the specified time window.' }
            'ActiveHoursStart'                       = @{ Type = 'REG_DWORD'; Meaning = '0-23 (hour)'; Description = 'Beginning of the active hours window (0-23). During active hours, the device will not automatically restart for updates.' }
            'ActiveHoursEnd'                         = @{ Type = 'REG_DWORD'; Meaning = '0-23 (hour)'; Description = 'End of the active hours window (0-23). Automatic restarts for updates can occur outside this range.' }
            'BranchReadinessLevel'                   = @{ Type = 'REG_DWORD'; Meaning = '2=Fast, 4=Slow, 8=Preview, 32=GA'; Description = 'Selects the Windows Insider or release channel for feature updates (2=Fast, 4=Slow, 8=Release Preview, 32=GA Channel).' }
            'DeferFeatureUpdates'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Defer feature updates'; Description = 'Enables deferral of feature updates for the number of days specified by DeferFeatureUpdatesPeriodinDays.' }
            'DeferFeatureUpdatesPeriodinDays'        = @{ Type = 'REG_DWORD'; Meaning = '0-365 days deferral'; Description = 'Number of days to defer feature updates after release (0-365). Device will not be offered feature updates until deferral expires.' }
            'DeferQualityUpdates'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Defer quality updates'; Description = 'Enables deferral of quality (cumulative/security) updates for the days specified by DeferQualityUpdatesPeriodinDays.' }
            'DeferQualityUpdatesPeriodinDays'        = @{ Type = 'REG_DWORD'; Meaning = '0-30 days deferral'; Description = 'Number of days to defer quality updates after release (0-30). Device will not be offered quality updates until deferral expires.' }
            'PauseFeatureUpdatesStartTime'           = @{ Type = 'REG_SZ';    Meaning = 'Date or 1=paused'; Description = 'Pauses feature updates from the specified date (yyyy-mm-dd). Pause lasts 35 days from start date or until cleared.' }
            'PauseQualityUpdatesStartTime'           = @{ Type = 'REG_SZ';    Meaning = 'Date or 1=paused'; Description = 'Pauses quality updates from the specified date (yyyy-mm-dd). Pause lasts 35 days from start date or until cleared.' }
            'ExcludeWUDriversInQualityUpdate'        = @{ Type = 'REG_DWORD'; Meaning = '1=Exclude drivers from updates'; Description = 'Excludes driver updates from Windows quality updates. Drivers must be managed separately when enabled.' }
            'AllowOptionalContent'                   = @{ Type = 'REG_DWORD'; Meaning = '0=None, 1=Auto+CFRs, 2=Auto, 3=User selects'; Description = 'Controls optional updates including non-security previews and controlled feature rollouts (CFRs). Respects quality deferral.' }
            'AllowTemporaryEnterpriseFeatureControl' = @{ Type = 'REG_DWORD'; Meaning = '1=Enable features behind enterprise control'; Description = 'Controls whether new features shipped via monthly quality updates (behind commercial control) are turned on.' }
            'TargetGroup'                            = @{ Type = 'REG_SZ';    Meaning = 'WSUS target group name'; Description = 'WSUS computer group name(s) for client-side targeting. Multiple groups separated by semicolons. Requires TargetGroupEnabled=1.' }
            'TargetGroupEnabled'                     = @{ Type = 'REG_DWORD'; Meaning = '1=Client-side targeting enabled'; Description = 'Enables client-side targeting. When enabled, the TargetGroup value is sent to WSUS to determine deployed updates.' }
            'ElevateNonAdmins'                       = @{ Type = 'REG_DWORD'; Meaning = '1=Non-admins receive notifications'; Description = 'Controls whether non-admin users receive update notifications and can install updates without UAC elevation.' }
            'SetProxyBehaviorForUpdateDetection'     = @{ Type = 'REG_DWORD'; Meaning = '0=System proxy only, 1=Allow user proxy'; Description = 'Controls proxy behavior for WSUS update detection. Setting to 1 allows user proxy as fallback but reduces security.' }
            'AcceptTrustedPublisherCerts'            = @{ Type = 'REG_DWORD'; Meaning = '1=Accept third-party certs from WSUS'; Description = 'Accepts updates signed by entities other than Microsoft when found on an intranet WSUS server.' }
            'DoNotEnforceEnterpriseTLSCertPinningForUpdateDetection' = @{ Type = 'REG_DWORD'; Meaning = '0=Enforce TLS pinning, 1=Disable'; Description = 'Disables TLS certificate pinning for WSUS communication when enabled. Microsoft recommends keeping this disabled (0).' }
            'UseUpdateClassPolicySource'             = @{ Type = 'REG_DWORD'; Meaning = '1=Use class-based policy source'; Description = 'Required companion for SetPolicyDrivenUpdateSource* policies when configuring scan sources via direct registry edits.' }
            'SetPolicyDrivenUpdateSourceForOtherUpdates' = @{ Type = 'REG_DWORD'; Meaning = '0=Windows Update, 1=WSUS'; Description = 'Specifies whether "Other Updates" (non-feature, non-quality, non-driver) come from Windows Update or WSUS.' }
            'UpdateServiceUrlAlternate'              = @{ Type = 'REG_SZ';    Meaning = 'Alternate update download URL'; Description = 'Alternate intranet download server URL. WUA can download update files from this server instead of the primary WSUS server.' }
            'FillEmptyContentUrls'                   = @{ Type = 'REG_DWORD'; Meaning = '1=Allow WUA to determine download URL'; Description = 'Allows WUA to determine the download URL when missing from update metadata. Only use with alternate download URL configured.' }
            'AUPowerManagement'                      = @{ Type = 'REG_DWORD'; Meaning = '1=Wake to install updates'; Description = 'Enables Windows Update Power Management to automatically wake the computer from hibernation to install scheduled updates.' }
        }
    },
    @{
        # Ref: https://learn.microsoft.com/windows/deployment/update/waas-wu-settings
        # Ref: https://learn.microsoft.com/windows-server/administration/windows-server-update-services/deploy/4-configure-group-policy-settings-for-automatic-updates
        Name = 'Automatic Updates (AU)'
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        Description = 'GPO/MDM-controlled automatic update behavior, WSUS, restart'
        IgnoreExtra = $false
        KnownKeys = @{
            'NoAutoUpdate'                          = @{ Type = 'REG_DWORD'; Meaning = '1=Disable automatic updates'; Description = 'Disables Automatic Updates entirely. Users must manually check, download, and install updates.' }
            'AUOptions'                             = @{ Type = 'REG_DWORD'; Meaning = '2=Notify, 3=Auto DL, 4=Schedule, 5=Local admin'; Description = 'Controls how Automatic Updates downloads and installs updates (2=Notify, 3=Auto DL+Notify, 4=Auto schedule, 5=Local admin).' }
            'UseWUServer'                           = @{ Type = 'REG_DWORD'; Meaning = '1=Use WSUS server'; Description = 'Enables use of the WSUS server specified in WUServer/WUStatusServer instead of Windows Update. Must be 1 for WSUS.' }
            'ScheduledInstallDay'                   = @{ Type = 'REG_DWORD'; Meaning = '0=Every day, 1=Sun..7=Sat'; Description = 'Day of the week for scheduled installations. Only effective when AUOptions=4 (auto download and schedule).' }
            'ScheduledInstallTime'                  = @{ Type = 'REG_DWORD'; Meaning = '0-23 (hour)'; Description = 'Hour of the day (0-23, 24h format) for scheduled installations. Only effective when AUOptions=4.' }
            'AlwaysAutoRebootAtScheduledTime'       = @{ Type = 'REG_DWORD'; Meaning = '1=Force restart at scheduled time'; Description = 'Forces automatic restart at scheduled time after update installation, even if users are signed in.' }
            'AlwaysAutoRebootAtScheduledTimeMinutes'= @{ Type = 'REG_DWORD'; Meaning = '15-180 minutes warning'; Description = 'Warning timer duration (15-180 min) before forced restart. Only effective when AlwaysAutoRebootAtScheduledTime=1.' }
            'NoAutoRebootWithLoggedOnUsers'         = @{ Type = 'REG_DWORD'; Meaning = '1=No restart if user signed in'; Description = 'Prevents automatic restart when a user is signed in. User is notified instead. Only applies when AUOptions=4.' }
            'IncludeRecommendedUpdates'             = @{ Type = 'REG_DWORD'; Meaning = '1=Include recommended updates'; Description = 'Delivers recommended updates in addition to important updates from WSUS via Automatic Updates.' }
            'AutoInstallMinorUpdates'               = @{ Type = 'REG_DWORD'; Meaning = '1=Silently install minor updates'; Description = 'Allows minor non-disruptive updates to install immediately without restart or service interruption.' }
            'AUPowerManagement'                     = @{ Type = 'REG_DWORD'; Meaning = '1=Wake to install updates'; Description = 'Enables Windows Update Power Management to wake the device from sleep/hibernation for scheduled updates.' }
        }
    },
    @{
        Name = 'Update Policy State'
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings'
        Description = 'Runtime pause/deferral state (not policy - reflects current state)'
        IgnoreExtra = $false
        KnownKeys = @{
            'PausedFeatureDate'    = @{ Type = 'REG_SZ';    Meaning = 'Date feature updates were paused'; Description = 'Timestamp when feature updates were paused. Runtime state set by the WU agent.' }
            'PausedFeatureStatus'  = @{ Type = 'REG_DWORD'; Meaning = '0=Not paused, 1=Paused, 2=Auto-resumed'; Description = 'Current feature update pause status. Runtime state set by the WU agent.' }
            'PausedQualityDate'    = @{ Type = 'REG_SZ';    Meaning = 'Date quality updates were paused'; Description = 'Timestamp when quality updates were paused. Runtime state set by the WU agent.' }
            'PausedQualityStatus'  = @{ Type = 'REG_DWORD'; Meaning = '0=Not paused, 1=Paused, 2=Auto-resumed'; Description = 'Current quality update pause status. Runtime state set by the WU agent.' }
        }
    },
    @{
        # Ref: https://learn.microsoft.com/windows/deployment/update/update-policies#device-activity-policies
        Name = 'UX Settings (User Preferences)'
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        Description = 'User preferences from Settings app and WU orchestrator state (not admin-configurable policy)'
        IgnoreExtra = $false
        KnownKeys = @{
            'IsContinuousInnovationOptedIn'                   = @{ Type = 'REG_DWORD'; Meaning = '1=Get latest updates ASAP'; Description = 'User opted in to "Get the latest updates as soon as they are available" in Settings.' }
            'AllowMUUpdateService'                            = @{ Type = 'REG_DWORD'; Meaning = '1=Receive updates for other MS products'; Description = 'User enabled "Receive updates for other Microsoft products" in Settings.' }
            'IsExpedited'                                     = @{ Type = 'REG_DWORD'; Meaning = '1=Restart 15 min after install'; Description = 'User preference for expedited restart timing after update installation.' }
            'RestartNotificationsAllowed2'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Show restart notifications'; Description = 'User preference to receive restart notification reminders in Settings.' }
            'ActiveHoursStart'                                = @{ Type = 'REG_DWORD'; Meaning = '0-23 (user-set start)'; Description = 'User-configured active hours start time from Settings > Windows Update > Advanced Options.' }
            'ActiveHoursEnd'                                  = @{ Type = 'REG_DWORD'; Meaning = '0-23 (user-set end)'; Description = 'User-configured active hours end time from Settings > Windows Update > Advanced Options.' }
            'PendingRebootStartTime'                          = @{ Type = 'REG_SZ';    Meaning = 'Timestamp when reboot became pending'; Description = 'Records when the pending reboot state began after update installation.' }
            'SmartActiveHoursStart'                           = @{ Type = 'REG_DWORD'; Meaning = '0-23 (auto-detected start)'; Description = 'Start of intelligent active hours window automatically calculated from device usage patterns. Not admin-configurable.' }
            'SmartActiveHoursEnd'                             = @{ Type = 'REG_DWORD'; Meaning = '0-23 (auto-detected end)'; Description = 'End of intelligent active hours window automatically calculated from device usage patterns. Not admin-configurable.' }
            'SmartActiveHoursSuggestionState'                 = @{ Type = 'REG_DWORD'; Meaning = 'Internal WU state'; Description = 'Internal WU orchestrator value tracking whether the system has enough usage data to suggest active hours.' }
            'LastToastAction'                                 = @{ Type = 'REG_DWORD'; Meaning = 'Internal WU state'; Description = 'Records the user''s last response to a Windows Update notification toast (dismissed, snoozed, or acted upon).' }
            'UxOption'                                        = @{ Type = 'REG_DWORD'; Meaning = 'Internal UX preference'; Description = 'Stores the user''s selected update behavior preference from Settings > Windows Update > Advanced Options.' }
            'FlightCommitted'                                 = @{ Type = 'REG_DWORD'; Meaning = '0/1 flight enrollment'; Description = 'Internal flag indicating whether the device has committed to a Windows Insider flight ring.' }
            'AllowAutoWindowsUpdateDownloadOverMeteredNetwork'= @{ Type = 'REG_DWORD'; Meaning = '1=Allow WU over metered'; Description = 'User toggle allowing Windows Update to download over metered (cellular) connections. Charges may apply.' }
            'ExcludeWUDriversInQualityUpdate'                 = @{ Type = 'REG_DWORD'; Meaning = '1=Exclude drivers'; Description = 'User-facing mirror of the driver exclusion preference. Reflects user/Intune choice to exclude drivers from quality updates.' }
        }
    },
    @{
        Name = 'Auto Update Runtime'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
        Description = 'Runtime auto-update state written by Windows Update Agent (not admin-configurable)'
        IgnoreExtra = $false
        KnownKeys = @{
            'RebootRequired'          = @{ Type = 'REG_DWORD'; Meaning = 'Key presence = reboot pending'; Description = 'Presence of this key indicates a reboot is pending for Windows Update. Set by the WU agent after update installation.' }
            'LastOnline'              = @{ Type = 'REG_SZ';    Meaning = 'Last WU online check'; Description = 'Timestamp of the last time Windows Update checked for updates online.' }
            'AcceleratedInstallRequired' = @{ Type = 'REG_DWORD'; Meaning = 'Internal WU state'; Description = 'Internal flag indicating an expedited/accelerated update installation has been requested (e.g., via WUfB expedite).' }
            'IsOOBEInProgress'        = @{ Type = 'REG_DWORD'; Meaning = 'Internal WU state'; Description = 'Internal flag indicating the device is in OOBE (Out of Box Experience). WU delays updates until OOBE completes.' }
        }
    },
    @{
        Name = 'Last Scan Result'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect'
        Description = 'Last successful update scan timestamp and error code'
        IgnoreExtra = $false
        KnownKeys = @{
            'LastSuccessTime' = @{ Type = 'REG_SZ';    Meaning = 'Last successful scan time'; Description = 'Timestamp of the last successful Windows Update scan.' }
            'LastError'       = @{ Type = 'REG_DWORD'; Meaning = 'HRESULT of last scan'; Description = 'HRESULT error code from the last scan attempt. 0 means success.' }
        }
    },
    @{
        Name = 'Last Install Result'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install'
        Description = 'Last successful update install timestamp and error code'
        IgnoreExtra = $false
        KnownKeys = @{
            'LastSuccessTime' = @{ Type = 'REG_SZ';    Meaning = 'Last successful install time'; Description = 'Timestamp of the last successful Windows Update installation.' }
            'LastError'       = @{ Type = 'REG_DWORD'; Meaning = 'HRESULT of last install'; Description = 'HRESULT error code from the last install attempt. 0 means success.' }
        }
    },
    @{
        Name = 'Last Download Result'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Download'
        Description = 'Last successful update download timestamp and error code'
        IgnoreExtra = $false
        KnownKeys = @{
            'LastSuccessTime' = @{ Type = 'REG_SZ';    Meaning = 'Last successful download time'; Description = 'Timestamp of the last successful Windows Update download.' }
            'LastError'       = @{ Type = 'REG_DWORD'; Meaning = 'HRESULT of last download'; Description = 'HRESULT error code from the last download attempt. 0 means success.' }
        }
    },
    @{
        Name = 'OS Version'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Description = 'Current OS build, feature update version, and edition'
        IgnoreExtra = $true
        KnownKeys = @{
            'CurrentBuild'       = @{ Type = 'REG_SZ';    Meaning = 'OS build number (e.g. 26100)'; Description = 'Current Windows build number.' }
            'CurrentBuildNumber' = @{ Type = 'REG_SZ';    Meaning = 'OS build number (alias)'; Description = 'Alias for CurrentBuild.' }
            'UBR'                = @{ Type = 'REG_DWORD'; Meaning = 'Update Build Revision'; Description = 'Update Build Revision — the cumulative update patch level appended to the build number (e.g., 26100.7623).' }
            'DisplayVersion'     = @{ Type = 'REG_SZ';    Meaning = 'Feature update version (e.g. 24H2)'; Description = 'Marketing version name for the current Windows feature update.' }
            'ProductName'        = @{ Type = 'REG_SZ';    Meaning = 'OS product name'; Description = 'Full Windows product name (e.g., Windows 10 Enterprise).' }
            'EditionID'          = @{ Type = 'REG_SZ';    Meaning = 'OS edition'; Description = 'Windows edition identifier (Enterprise, Professional, Education, etc.).' }
            'InstallDate'        = @{ Type = 'REG_DWORD'; Meaning = 'Unix timestamp of OS install'; Description = 'Unix epoch timestamp of when this Windows installation was performed.' }
            'ReleaseId'          = @{ Type = 'REG_SZ';    Meaning = 'Release ID (deprecated)'; Description = 'Legacy release ID. Deprecated — always reads 2009 on Windows 10 21H1+ and Windows 11.' }
            'InstallationType'   = @{ Type = 'REG_SZ';    Meaning = 'Client or Server'; Description = 'Installation type: Client (desktop) or Server.' }
            'BuildBranch'        = @{ Type = 'REG_SZ';    Meaning = 'Build branch (e.g. ge_release)'; Description = 'Internal Windows build branch name.' }
        }
    },
    @{
        # Ref: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-deliveryoptimization
        Name = 'Delivery Optimization'
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
        Description = 'P2P content delivery and bandwidth policies for updates'
        IgnoreExtra = $false
        KnownKeys = @{
            'DODownloadMode'                           = @{ Type = 'REG_DWORD'; Meaning = '0=HTTP, 1=LAN, 2=Group, 3=Internet, 99=Simple, 100=Bypass'; Description = 'Controls whether peer-to-peer sharing is enabled and its scope for downloading updates and apps.' }
            'DOGroupId'                                = @{ Type = 'REG_SZ';    Meaning = 'Custom peer group GUID'; Description = 'Custom group ID (GUID) for Delivery Optimization peer grouping. Devices with same ID share content in mode 2.' }
            'DOGroupIdSource'                          = @{ Type = 'REG_DWORD'; Meaning = '1=AD Site, 2=SID, 3=DHCP, 4=DNS, 5=AAD'; Description = 'How the DO group ID is determined (1=AD Site, 2=Domain SID, 3=DHCP, 4=DNS suffix, 5=Entra Tenant).' }
            'DORestrictPeerSelectionBy'                = @{ Type = 'REG_DWORD'; Meaning = '0=None, 1=Subnet, 2=DNS-SD'; Description = 'Restricts peer selection to a specific network scope in addition to the DownloadMode setting.' }
            'DOMaxCacheSize'                           = @{ Type = 'REG_DWORD'; Meaning = 'Max cache (% of disk)'; Description = 'Maximum cache size as a percentage of available disk space for Delivery Optimization content.' }
            'DOAbsoluteMaxCacheSize'                   = @{ Type = 'REG_DWORD'; Meaning = 'Max cache (GB, absolute)'; Description = 'Maximum cache size in GB. This absolute limit overrides the percentage-based DOMaxCacheSize setting.' }
            'DOMaxCacheAge'                            = @{ Type = 'REG_DWORD'; Meaning = 'Max cache age (seconds)'; Description = 'Maximum time in seconds each file is held in the DO cache after download. Common: 1209600 = 14 days.' }
            'DOMaxBackgroundDownloadBandwidth'         = @{ Type = 'REG_DWORD'; Meaning = 'Max background BW (KB/s)'; Description = 'Maximum background download bandwidth in KB/s across all concurrent DO activities. 0 = no limit.' }
            'DOMaxForegroundDownloadBandwidth'         = @{ Type = 'REG_DWORD'; Meaning = 'Max foreground BW (KB/s)'; Description = 'Maximum foreground download bandwidth in KB/s across all concurrent DO activities. 0 = no limit.' }
            'DOAllowVPNPeerCaching'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Allow peer caching over VPN'; Description = 'Controls whether a device connected via VPN can participate in peer-to-peer caching. Disabled by default.' }
            'DOMinRAMAllowedToPeer'                    = @{ Type = 'REG_DWORD'; Meaning = 'Min RAM (GB) for peering'; Description = 'Minimum RAM in GB required for the device to participate in peer caching uploads.' }
            'DOMinDiskSizeAllowedToPeer'               = @{ Type = 'REG_DWORD'; Meaning = 'Min disk (GB) for peering'; Description = 'Minimum disk size in GB required for the device to participate in peer caching.' }
            'DOMinFileSizeToCache'                     = @{ Type = 'REG_DWORD'; Meaning = 'Min file size (MB) to cache'; Description = 'Minimum content file size in MB for Delivery Optimization to cache for peer sharing.' }
            'DOMinBatteryPercentageAllowedToUpload'    = @{ Type = 'REG_DWORD'; Meaning = 'Min battery % to upload'; Description = 'Minimum battery percentage required to allow the device to upload (share) content to peers.' }
            'DOCacheHost'                              = @{ Type = 'REG_SZ';    Meaning = 'Connected Cache server'; Description = 'Microsoft Connected Cache server hostname(s). Comma-separated FQDNs or IPs for downloading content.' }
            'DOCacheHostSource'                        = @{ Type = 'REG_DWORD'; Meaning = '1=DHCP 235, 2=Force DHCP 235'; Description = 'How clients discover Connected Cache servers. 1=DHCP Option 235, 2=DHCP Option 235 Force.' }
            'DODelayBackgroundDownloadFromHttp'        = @{ Type = 'REG_DWORD'; Meaning = 'Delay bg HTTP download (sec)'; Description = 'Seconds to delay background HTTP download to allow peer-to-peer sources to be found first.' }
            'DODelayForegroundDownloadFromHttp'        = @{ Type = 'REG_DWORD'; Meaning = 'Delay fg HTTP download (sec)'; Description = 'Seconds to delay foreground HTTP download to allow peer-to-peer sources to be found first.' }
            'DODelayCacheServerFallbackBackground'     = @{ Type = 'REG_DWORD'; Meaning = 'Delay cache fallback bg (sec)'; Description = 'Seconds to delay falling back from cache server to HTTP source for background downloads.' }
            'DODelayCacheServerFallbackForeground'     = @{ Type = 'REG_DWORD'; Meaning = 'Delay cache fallback fg (sec)'; Description = 'Seconds to delay falling back from cache server to HTTP source for foreground downloads.' }
        }
    }
)
#endregion Registry Hive Definitions

#region Internal Functions
function Read-WURegistryHive {
    <#
    .SYNOPSIS
        Reads all values from a Windows Update registry hive path.
    .DESCRIPTION
        Reads a registry hive, decodes known keys, flags unknown keys,
        and returns a structured hashtable of results.
    .PARAMETER HiveDef
        Hashtable defining the hive (Name, Path, KnownKeys, IgnoreExtra).
    .PARAMETER ComputerName
        Remote computer name, or empty for local.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$HiveDef,

        [Parameter()]
        [string]$ComputerName
    )

    $component = 'Read-WURegistryHive'
    $hiveName = $HiveDef.Name
    $hivePath = $HiveDef.Path
    $knownKeys = $HiveDef.KnownKeys
    $ignoreExtra = if ($HiveDef.ContainsKey('IgnoreExtra')) { $HiveDef.IgnoreExtra } else { $false }

    Write-DeviceDNALog -Message "Reading WU hive: $hiveName ($hivePath)" -Component $component -Type 1

    $result = @{
        Name        = $hiveName
        Path        = $hivePath
        Description = $HiveDef.Description
        Exists      = $false
        Values      = @{}
        UnknownKeys = @{}
        Error       = $null
    }

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        if (-not $isLocal) {
            $regData = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                param($path)
                $out = @{ Exists = $false; Properties = @{} }
                if (Test-Path $path) {
                    $out.Exists = $true
                    $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                    if ($item) {
                        $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                            $out.Properties[$_.Name] = $_.Value
                        }
                    }
                }
                return $out
            } -ArgumentList $hivePath -ErrorAction Stop

            $result.Exists = $regData.Exists
            $properties = $regData.Properties
        }
        else {
            if (Test-Path $hivePath) {
                $result.Exists = $true
                $item = Get-ItemProperty -Path $hivePath -ErrorAction SilentlyContinue
                $properties = @{}
                if ($item) {
                    $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                        $properties[$_.Name] = $_.Value
                    }
                }
            }
            else {
                $result.Exists = $false
                $properties = @{}
            }
        }

        if (-not $result.Exists) {
            Write-DeviceDNALog -Message "  $hiveName`: Key not present (not configured)" -Component $component -Type 1
            return $result
        }

        if ($properties.Count -eq 0) {
            Write-DeviceDNALog -Message "  $hiveName`: Key exists but empty" -Component $component -Type 1
            return $result
        }

        foreach ($propName in $properties.Keys) {
            $propValue = $properties[$propName]

            if ($knownKeys.ContainsKey($propName)) {
                $keyInfo = $knownKeys[$propName]
                $decoded = Get-WUDecodedValue -KeyName $propName -Value $propValue
                $result.Values[$propName] = @{
                    Value       = $propValue
                    Meaning     = $keyInfo.Meaning
                    Decoded     = $decoded
                    Description = if ($keyInfo.ContainsKey('Description')) { $keyInfo.Description } else { '' }
                    Known       = $true
                }
                Write-DeviceDNALog -Message "  [KNOWN] $propName = $propValue ($decoded)" -Component $component -Type 1
            }
            else {
                if ($ignoreExtra) { continue }
                $result.UnknownKeys[$propName] = $propValue
                $result.Values[$propName] = @{
                    Value   = $propValue
                    Meaning = '(not in known key list)'
                    Decoded = "$propValue"
                    Known   = $false
                }
                Write-DeviceDNALog -Message "  [EXTRA] $propName = $propValue" -Component $component -Type 2
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-DeviceDNALog -Message "ERROR reading $hiveName`: $($_.Exception.Message)" -Component $component -Type 3
    }

    return $result
}

function Get-WUDecodedValue {
    <#
    .SYNOPSIS
        Decodes a Windows Update registry value into a human-readable description.
    .PARAMETER KeyName
        The registry value name.
    .PARAMETER Value
        The raw registry value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$KeyName,

        [Parameter()]
        $Value
    )

    switch ($KeyName) {
        'AUOptions' {
            switch ($Value) {
                2 { return 'Notify download + install' }
                3 { return 'Auto download, notify install' }
                4 { return 'Auto download + schedule install' }
                5 { return 'Local admin decides' }
                default { return "Unknown ($Value)" }
            }
        }
        'ScheduledInstallDay' {
            switch ($Value) {
                0 { return 'Every day' }
                1 { return 'Sunday' }
                2 { return 'Monday' }
                3 { return 'Tuesday' }
                4 { return 'Wednesday' }
                5 { return 'Thursday' }
                6 { return 'Friday' }
                7 { return 'Saturday' }
                default { return "Unknown ($Value)" }
            }
        }
        'ScheduledInstallTime' {
            if ($Value -ge 0 -and $Value -le 23) {
                if ($Value -eq 0) { return '12:00 AM' }
                elseif ($Value -lt 12) { return "$Value`:00 AM" }
                elseif ($Value -eq 12) { return '12:00 PM' }
                else { return "$($Value - 12)`:00 PM" }
            }
            return "Invalid ($Value)"
        }
        'ActiveHoursStart' {
            if ($Value -ge 0 -and $Value -le 23) {
                if ($Value -eq 0) { return '12:00 AM' }
                elseif ($Value -lt 12) { return "$Value`:00 AM" }
                elseif ($Value -eq 12) { return '12:00 PM' }
                else { return "$($Value - 12)`:00 PM" }
            }
            return "Invalid ($Value)"
        }
        'ActiveHoursEnd' {
            if ($Value -ge 0 -and $Value -le 23) {
                if ($Value -eq 0) { return '12:00 AM' }
                elseif ($Value -lt 12) { return "$Value`:00 AM" }
                elseif ($Value -eq 12) { return '12:00 PM' }
                else { return "$($Value - 12)`:00 PM" }
            }
            return "Invalid ($Value)"
        }
        'SmartActiveHoursStart' {
            if ($Value -ge 0 -and $Value -le 23) {
                if ($Value -eq 0) { return '12:00 AM' }
                elseif ($Value -lt 12) { return "$Value`:00 AM" }
                elseif ($Value -eq 12) { return '12:00 PM' }
                else { return "$($Value - 12)`:00 PM" }
            }
            return "Invalid ($Value)"
        }
        'SmartActiveHoursEnd' {
            if ($Value -ge 0 -and $Value -le 23) {
                if ($Value -eq 0) { return '12:00 AM' }
                elseif ($Value -lt 12) { return "$Value`:00 AM" }
                elseif ($Value -eq 12) { return '12:00 PM' }
                else { return "$($Value - 12)`:00 PM" }
            }
            return "Invalid ($Value)"
        }
        'BranchReadinessLevel' {
            switch ($Value) {
                2  { return 'Windows Insider - Fast' }
                4  { return 'Windows Insider - Slow' }
                8  { return 'Release Preview' }
                32 { return 'General Availability Channel' }
                default { return "Unknown ($Value)" }
            }
        }
        'PausedFeatureStatus' {
            switch ($Value) {
                0 { return 'Not paused' }
                1 { return 'Paused' }
                2 { return 'Auto-resumed after pause' }
                default { return "Unknown ($Value)" }
            }
        }
        'PausedQualityStatus' {
            switch ($Value) {
                0 { return 'Not paused' }
                1 { return 'Paused' }
                2 { return 'Auto-resumed after pause' }
                default { return "Unknown ($Value)" }
            }
        }
        'AllowOptionalContent' {
            switch ($Value) {
                1 { return 'Auto optional + CFRs' }
                2 { return 'Auto optional only' }
                3 { return 'User selects' }
                default { return "Not configured ($Value)" }
            }
        }
        # Ref: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-deliveryoptimization#dodownloadmode
        'DODownloadMode' {
            switch ($Value) {
                0   { return 'HTTP only (no peering)' }
                1   { return 'LAN (peers behind same NAT)' }
                2   { return 'Group (private group peering)' }
                3   { return 'Internet (internet peering)' }
                99  { return 'Simple (HTTP only, no DO cloud)' }
                100 { return 'Bypass (BITS, deprecated Win11)' }
                default { return "Unknown ($Value)" }
            }
        }
        'DOGroupIdSource' {
            switch ($Value) {
                1 { return 'AD Site' }
                2 { return 'Authenticated domain SID' }
                3 { return 'DHCP option ID' }
                4 { return 'DNS suffix' }
                5 { return 'AAD tenant ID' }
                default { return "Unknown ($Value)" }
            }
        }
        'DORestrictPeerSelectionBy' {
            switch ($Value) {
                0 { return 'None' }
                1 { return 'Subnet mask' }
                2 { return 'Local discovery (DNS-SD)' }
                default { return "Unknown ($Value)" }
            }
        }
        'DOCacheHostSource' {
            switch ($Value) {
                1 { return 'DHCP option 235' }
                2 { return 'Group Policy' }
                default { return "Unknown ($Value)" }
            }
        }
        'LastError' {
            if ($Value -eq 0) { return 'Success (0x00000000)' }
            return ('0x{0:X8}' -f $Value)
        }
        'InstallDate' {
            try {
                $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
                $date = $epoch.AddSeconds($Value).ToLocalTime()
                return $date.ToString('yyyy-MM-dd HH:mm:ss')
            }
            catch { return "$Value" }
        }
        default {
            # Boolean-style DWORD keys
            if ($Value -is [int] -and $Value -le 1) {
                $boolKeys = @(
                    'NoAutoUpdate', 'UseWUServer', 'SetActiveHours',
                    'DoNotConnectToWindowsUpdateInternetLocations', 'DisableWindowsUpdateAccess',
                    'DeferFeatureUpdates', 'DeferQualityUpdates',
                    'ExcludeWUDriversInQualityUpdate', 'NoAutoRebootWithLoggedOnUsers',
                    'AlwaysAutoRebootAtScheduledTime', 'IsContinuousInnovationOptedIn',
                    'AllowMUUpdateService', 'IsExpedited', 'RestartNotificationsAllowed2',
                    'AllowTemporaryEnterpriseFeatureControl', 'TargetGroupEnabled',
                    'ElevateNonAdmins', 'IncludeRecommendedUpdates', 'AutoInstallMinorUpdates',
                    'SetProxyBehaviorForUpdateDetection', 'AcceptTrustedPublisherCerts',
                    'DoNotEnforceEnterpriseTLSCertPinningForUpdateDetection',
                    'UseUpdateClassPolicySource', 'FillEmptyContentUrls', 'AUPowerManagement',
                    'DOAllowVPNPeerCaching', 'FlightCommitted',
                    'AllowAutoWindowsUpdateDownloadOverMeteredNetwork',
                    'SetPolicyDrivenUpdateSourceForOtherUpdates',
                    'AcceleratedInstallRequired', 'IsOOBEInProgress'
                )
                if ($KeyName -in $boolKeys) {
                    if ($Value -eq 1) { return 'Enabled' } else { return 'Disabled' }
                }
            }
            return "$Value"
        }
    }
}

function Test-WURebootRequired {
    <#
    .SYNOPSIS
        Checks multiple indicators for pending reboot from Windows Update.
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Hashtable with RebootPending (bool) and Indicators (array of strings).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $component = 'Test-WURebootRequired'
    $rebootPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )

    $results = @{
        RebootPending = $false
        Indicators    = @()
    }

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        if (-not $isLocal) {
            $remoteResult = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                param($paths)
                $out = @{ Indicators = @() }
                foreach ($p in $paths) {
                    if (Test-Path $p) {
                        $out.Indicators += $p
                    }
                }
                $sfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                if ($sfr -and $sfr.PendingFileRenameOperations) {
                    $out.Indicators += 'PendingFileRenameOperations'
                }
                return $out
            } -ArgumentList (,$rebootPaths) -ErrorAction Stop

            $results.Indicators = @($remoteResult.Indicators)
        }
        else {
            foreach ($path in $rebootPaths) {
                if (Test-Path $path) {
                    $results.Indicators += $path
                }
            }
            $sfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($sfr -and $sfr.PendingFileRenameOperations) {
                $results.Indicators += 'PendingFileRenameOperations'
            }
        }

        $results.RebootPending = ($results.Indicators.Count -gt 0)
    }
    catch {
        Write-DeviceDNALog -Message "Error checking reboot status: $($_.Exception.Message)" -Component $component -Type 3
    }

    return $results
}

function Get-WUAUpdateStatus {
    <#
    .SYNOPSIS
        Queries WUA COM API for service state, pending updates, and install history.
    .DESCRIPTION
        Uses Microsoft.Update.Session and Microsoft.Update.AutoUpdate COM objects.
        Ref: https://learn.microsoft.com/windows/win32/wua_sdk/windows-update-agent-object-model
        Ref: https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iupdatehistoryentry
        Ref: https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iautomaticupdatesresults
    .PARAMETER ComputerName
        Target computer name.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $component = 'Get-WUAUpdateStatus'
    Write-DeviceDNALog -Message "Querying WUA COM API..." -Component $component -Type 1

    $wuaScript = {
        $result = @{
            ServiceStatus      = 'Unknown'
            ServiceStartType   = 'Unknown'
            LastSearchSuccess  = $null
            LastInstallSuccess = $null
            PendingUpdates     = @()
            PendingCount       = 0
            RecentHistory      = @()
            TotalHistoryCount  = 0
            Error              = $null
        }

        try {
            # Service state
            $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
            if ($svc) {
                $result.ServiceStatus = $svc.Status.ToString()
                $result.ServiceStartType = $svc.StartType.ToString()
            }

            # AutomaticUpdates results (last scan/install dates)
            # Ref: IAutomaticUpdatesResults interface
            try {
                $au = New-Object -ComObject Microsoft.Update.AutoUpdate
                $auResults = $au.Results
                if ($auResults.LastSearchSuccessDate) {
                    $result.LastSearchSuccess = $auResults.LastSearchSuccessDate.ToString('yyyy-MM-dd HH:mm:ss')
                }
                if ($auResults.LastInstallationSuccessDate) {
                    $result.LastInstallSuccess = $auResults.LastInstallationSuccessDate.ToString('yyyy-MM-dd HH:mm:ss')
                }
            }
            catch { }

            # WUA Session: pending updates + history
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()

            # Pending updates (not installed, not hidden)
            try {
                $searchResult = $searcher.Search("IsInstalled=0 AND IsHidden=0")
                $result.PendingCount = $searchResult.Updates.Count
                for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
                    $update = $searchResult.Updates.Item($i)
                    $kbs = @()
                    for ($k = 0; $k -lt $update.KBArticleIDs.Count; $k++) {
                        $kbs += "KB$($update.KBArticleIDs.Item($k))"
                    }
                    $severity = $update.MsrcSeverity
                    if (-not $severity) { $severity = 'Unspecified' }
                    $result.PendingUpdates += @{
                        Title        = $update.Title
                        KBArticleIDs = ($kbs -join ', ')
                        IsDownloaded = [bool]$update.IsDownloaded
                        IsMandatory  = [bool]$update.IsMandatory
                        MsrcSeverity = $severity
                    }
                }
            }
            catch {
                $result.Error = "Pending search failed: $($_.Exception.Message)"
            }

            # Recent history (last 50)
            # Ref: IUpdateHistoryEntry - Operation: 1=Install, 2=Uninstall
            # Ref: OperationResultCode: 0=NotStarted, 1=InProgress, 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted
            try {
                $totalHistory = $searcher.GetTotalHistoryCount()
                $result.TotalHistoryCount = $totalHistory
                if ($totalHistory -gt 0) {
                    $count = $totalHistory
                    if ($count -gt 50) { $count = 50 }
                    $history = $searcher.QueryHistory(0, $count)
                    for ($i = 0; $i -lt $history.Count; $i++) {
                        $entry = $history.Item($i)
                        $rc = switch ([int]$entry.ResultCode) {
                            0 { 'Not Started' }
                            1 { 'In Progress' }
                            2 { 'Succeeded' }
                            3 { 'Succeeded with Errors' }
                            4 { 'Failed' }
                            5 { 'Aborted' }
                            default { "Unknown ($([int]$entry.ResultCode))" }
                        }
                        $op = switch ([int]$entry.Operation) {
                            1 { 'Install' }
                            2 { 'Uninstall' }
                            default { "Unknown ($([int]$entry.Operation))" }
                        }
                        $dateStr = $null
                        if ($entry.Date) {
                            try { $dateStr = $entry.Date.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
                        }
                        $hresult = $null
                        if ($entry.HResult -and $entry.HResult -ne 0) {
                            $hresult = '0x{0:X8}' -f $entry.HResult
                        }
                        $result.RecentHistory += @{
                            Title     = $entry.Title
                            Date      = $dateStr
                            Operation = $op
                            Result    = $rc
                            HResult   = $hresult
                        }
                    }
                }
            }
            catch {
                if (-not $result.Error) {
                    $result.Error = "History query failed: $($_.Exception.Message)"
                }
            }
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        if (-not $isLocal) {
            return Invoke-Command -ComputerName $ComputerName -ScriptBlock $wuaScript -ErrorAction Stop
        }
        else {
            return & $wuaScript
        }
    }
    catch {
        Write-DeviceDNALog -Message "WUA COM query failed: $($_.Exception.Message)" -Component $component -Type 3
        return @{
            ServiceStatus      = 'Unknown'
            ServiceStartType   = 'Unknown'
            LastSearchSuccess  = $null
            LastInstallSuccess = $null
            PendingUpdates     = @()
            PendingCount       = 0
            RecentHistory      = @()
            TotalHistoryCount  = 0
            Error              = $_.Exception.Message
        }
    }
}
#endregion Internal Functions

#region Main Entry Point
function Get-WindowsUpdateData {
    <#
    .SYNOPSIS
        Main Windows Update collection function. Aggregates registry, reboot, and WUA data.
    .PARAMETER ComputerName
        Target computer name.
    .PARAMETER Skip
        Array of collection categories to skip. 'WindowsUpdate' disables entire collection.
    .OUTPUTS
        Hashtable with summary, registryPolicy, pendingUpdates, updateHistory,
        deliveryOptimization, and duration. Returns $null if skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [string[]]$Skip = @()
    )

    $component = 'Get-WindowsUpdateData'
    $startTime = Get-Date

    Write-StatusMessage "Starting Windows Update data collection..." -Type Progress
    Write-DeviceDNALog -Message "Starting Windows Update collection for $(if ($ComputerName) { $ComputerName } else { 'localhost' })" -Component $component -Type 1

    # Read all registry hives
    $allHiveResults = @{}
    $hiveIndex = 0

    foreach ($hive in $script:WURegistryHives) {
        $hiveIndex++
        Write-StatusMessage "  [$hiveIndex/$($script:WURegistryHives.Count)] $($hive.Name)..." -Type Progress
        $hiveResult = Read-WURegistryHive -HiveDef $hive -ComputerName $ComputerName
        $allHiveResults[$hive.Name] = $hiveResult
    }

    # Check reboot status
    Write-StatusMessage "  Checking reboot indicators..." -Type Progress
    $rebootStatus = Test-WURebootRequired -ComputerName $ComputerName

    if ($rebootStatus.RebootPending) {
        Write-StatusMessage "  Reboot PENDING ($($rebootStatus.Indicators.Count) indicator(s))" -Type Warning
        Write-DeviceDNALog -Message "Reboot pending: $($rebootStatus.Indicators -join ', ')" -Component $component -Type 2
    }
    else {
        Write-DeviceDNALog -Message "No reboot indicators found" -Component $component -Type 1
    }

    # Query WUA COM API
    Write-StatusMessage "  Querying Windows Update Agent (COM API)..." -Type Progress
    $wuaStatus = Get-WUAUpdateStatus -ComputerName $ComputerName

    if ($wuaStatus.Error) {
        Write-StatusMessage "  WUA warning: $($wuaStatus.Error)" -Type Warning
        $script:CollectionIssues += @{ severity = "Warning"; phase = "WindowsUpdate"; message = "WUA COM: $($wuaStatus.Error)" }
    }

    # Extract summary values from hive results
    $wuPolicy = $allHiveResults['WindowsUpdate Policy']
    $auPolicy = $allHiveResults['Automatic Updates (AU)']
    $osVersion = $allHiveResults['OS Version']
    $doPolicy = $allHiveResults['Delivery Optimization']
    $lastScan = $allHiveResults['Last Scan Result']
    $lastInstall = $allHiveResults['Last Install Result']

    # Determine update source (WUFB, ESUS, WSUS, or Windows Update)
    # Ref: https://learn.microsoft.com/windows/deployment/update/waas-integrate-wufb
    # Ref: https://learn.microsoft.com/mem/configmgr/sum/understand/software-updates-introduction
    $updateSource = 'Windows Update (direct)'
    $updateManagement = 'None'

    # Check for WSUS/ESUS configuration (UseWUServer = 1)
    if ($auPolicy.Exists -and $auPolicy.Values.ContainsKey('UseWUServer') -and $auPolicy.Values['UseWUServer'].Value -eq 1) {
        $wsusUrl = if ($wuPolicy.Values.ContainsKey('WUServer')) { $wuPolicy.Values['WUServer'].Value } else { '(URL not set)' }

        # Detect ESUS (Endpoint Update Service - cloud-based WSUS endpoints used by Intune)
        # ESUS endpoints: *.mp.microsoft.com, *.windowsupdate.com with specific paths
        if ($wsusUrl -match '\.mp\.microsoft\.com' -or $wsusUrl -match 'eus\.wu\.manage\.microsoft\.com') {
            $updateSource = "ESUS (Endpoint Update Service)"
            $updateManagement = 'Intune (ESUS)'
        }
        else {
            $updateSource = "WSUS: $wsusUrl"
            $updateManagement = 'WSUS'
        }
    }

    # Check for Windows Update for Business (WUFB) policies
    # WUFB is indicated by deferral policies being configured
    $wufbIndicators = @(
        'DeferFeatureUpdates',
        'DeferQualityUpdates',
        'BranchReadinessLevel',
        'PauseFeatureUpdatesStartTime',
        'PauseQualityUpdatesStartTime'
    )
    $wufbConfigured = $false
    if ($wuPolicy.Exists) {
        foreach ($indicator in $wufbIndicators) {
            if ($wuPolicy.Values.ContainsKey($indicator)) {
                $wufbConfigured = $true
                break
            }
        }
    }

    # If WUFB policies are present but no WSUS, it's WUFB (Intune-managed)
    if ($wufbConfigured -and $updateManagement -eq 'None') {
        $updateSource = "Windows Update for Business (WUFB)"
        $updateManagement = 'Intune (WUFB)'
    }
    # If WUFB policies + WSUS, indicate co-management
    elseif ($wufbConfigured -and $updateManagement -ne 'None') {
        $updateManagement = "$updateManagement + WUFB"
    }

    # Extract OS info
    $osBuild = ''
    $osVersionStr = ''
    $osEdition = ''
    if ($osVersion -and $osVersion.Exists) {
        $build = if ($osVersion.Values.ContainsKey('CurrentBuild')) { $osVersion.Values['CurrentBuild'].Value } else { '' }
        $ubr = if ($osVersion.Values.ContainsKey('UBR')) { ".$($osVersion.Values['UBR'].Value)" } else { '' }
        $osBuild = "$build$ubr"
        $osVersionStr = if ($osVersion.Values.ContainsKey('DisplayVersion')) { $osVersion.Values['DisplayVersion'].Value } else { '' }
        $osEdition = if ($osVersion.Values.ContainsKey('EditionID')) { $osVersion.Values['EditionID'].Value } else { '' }
    }

    # Best available scan/install times (prefer COM API, fall back to registry)
    $lastScanTime = $wuaStatus.LastSearchSuccess
    if (-not $lastScanTime -and $lastScan -and $lastScan.Exists -and $lastScan.Values.ContainsKey('LastSuccessTime')) {
        $lastScanTime = $lastScan.Values['LastSuccessTime'].Value
    }

    $lastInstallTime = $wuaStatus.LastInstallSuccess
    if (-not $lastInstallTime -and $lastInstall -and $lastInstall.Exists -and $lastInstall.Values.ContainsKey('LastSuccessTime')) {
        $lastInstallTime = $lastInstall.Values['LastSuccessTime'].Value
    }

    # Build flat registry policy for report (all hives except OS Version and DO)
    $registryPolicy = @{}
    foreach ($hiveName in $allHiveResults.Keys) {
        $hive = $allHiveResults[$hiveName]
        if (-not $hive.Exists) { continue }
        if ($hiveName -eq 'OS Version' -or $hiveName -eq 'Delivery Optimization') { continue }

        foreach ($entry in $hive.Values.GetEnumerator()) {
            $registryPolicy["$hiveName|$($entry.Key)"] = @{
                Hive        = $hiveName
                Setting     = $entry.Key
                Value       = $entry.Value.Value
                Decoded     = $entry.Value.Decoded
                Meaning     = $entry.Value.Meaning
                Description = if ($entry.Value.ContainsKey('Description')) { $entry.Value.Description } else { '' }
                Known       = $entry.Value.Known
            }
        }
    }

    # Build Delivery Optimization data
    $deliveryOptimization = @{}
    if ($doPolicy -and $doPolicy.Exists) {
        foreach ($entry in $doPolicy.Values.GetEnumerator()) {
            $deliveryOptimization[$entry.Key] = @{
                Value   = $entry.Value.Value
                Decoded = $entry.Value.Decoded
                Meaning = $entry.Value.Meaning
            }
        }
    }

    $duration = (Get-Date) - $startTime

    Write-StatusMessage "Windows Update collection completed ($($wuaStatus.PendingCount) pending, $($wuaStatus.RecentHistory.Count) history)" -Type Info
    Write-DeviceDNALog -Message "WU collection complete in $($duration.TotalSeconds.ToString('F1'))s: $($wuaStatus.PendingCount) pending, $($wuaStatus.RecentHistory.Count) history entries" -Component $component -Type 1

    return @{
        summary = @{
            updateSource      = $updateSource
            updateManagement  = $updateManagement
            osBuild           = $osBuild
            osVersion         = $osVersionStr
            osEdition         = $osEdition
            lastScanTime      = $lastScanTime
            lastInstallTime   = $lastInstallTime
            rebootPending     = $rebootStatus.RebootPending
            rebootIndicators  = $rebootStatus.Indicators
            serviceState      = $wuaStatus.ServiceStatus
            serviceStartType  = $wuaStatus.ServiceStartType
            pendingCount      = $wuaStatus.PendingCount
            historyCount      = $wuaStatus.TotalHistoryCount
        }
        registryPolicy       = $registryPolicy
        pendingUpdates       = @($wuaStatus.PendingUpdates)
        updateHistory        = @($wuaStatus.RecentHistory)
        deliveryOptimization = $deliveryOptimization
        duration             = $duration.ToString('hh\:mm\:ss')
    }
}
#endregion Main Entry Point
