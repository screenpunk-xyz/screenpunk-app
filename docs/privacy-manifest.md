# iOS required-reason API manifest

The device app includes `apps/device/PrivacyInfo.xcprivacy` in its Resources build
phase. It declares required-reason API access by the app and its first-party Swift
packages. Apple's [required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
and [API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
are the source for these declarations, reviewed on October 29, 2026.

| Category | Approved reason | Actual iOS use |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Read/write the app's own brightness schedule, public-read and map approvals, Google TV configuration, connection port draft and permissions. See `DeviceDisplaySettings.swift`, `DeviceModel.swift`, `AppleMapPreview.swift`, `GoogleTVConnection.swift`, `GoogleTVADBConnection.swift` and `DeviceGoogleTVSettings.swift`. These iOS paths use `UserDefaults.standard`. |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `HomeAssistantWebBridge.swift` checks elapsed time since an explicit tap. `GoogleTVSession.swift` measures voice-operation and stream durations. Only differences between in-app events are used; raw uptime is not returned. Apple's reason permits elapsed in-app event durations to be sent off-device. |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | `AuthoringPinnedPackage.swift` uses `fstat` to verify a pinned package asset is a regular file of the expected size before reading and hashing it. `ScreenLibrary.swift` supplies revision directories within the app's Application Support `ScreenpunkScreens` storage. Apple's category includes `fstat`, and this reason covers size and other metadata inside the app container, even when timestamps themselves are unused. |

`MacHomeAssistantConnection.swift` is enclosed in `#if os(macOS)`.
`AppleMapPreview.swift` uses its named defaults suite only in its macOS branch;
the iOS branch uses the app's standard defaults. These macOS paths do not justify
an iOS shared-container or cross-app defaults reason.

The manifest contains only the required-reason API declarations. Data collection,
tracking declarations and App Store privacy labels require separate review of the
complete product and its services. The Cloud service stores account information
and user content; this manifest makes no claim that the app collects no data.
Existing purpose strings and permission prompts are independent of these reasons.

For release validation, lint the manifest and Xcode project, build the device app,
and confirm the built `.app/PrivacyInfo.xcprivacy` has the same three category/reason
pairs as the source. Review this table whenever required-reason API use changes;
Xcode packaging success alone does not establish that a reason matches actual use.
