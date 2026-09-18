# Changelog

All notable changes to the scripts in this repo are documented here, grouped by folder. Each script tracks its own version in a `$ScriptVersion` variable in SECTION 1 (CONFIG) of the file — bump it whenever the script's logic changes, and add an entry below.

## ninjaone/

### 1.0.3 — 2026-09-18

**Critical bugfix:** same em-dash/no-BOM parsing bug as `intune/` 1.0.3 below. This file had no BOM and contained em dashes (`—`) in several live `Write-Log` strings (not just comments). Windows PowerShell 5.1 reads a BOM-less `.ps1` using the system ANSI code page, which misdecodes an em dash's UTF-8 bytes into a curly right double-quote (U+201D) — a character PowerShell's parser accepts as an alternate string delimiter — corrupting string/brace parsing from that point forward and failing the whole script at the parse stage before a single line executed. Fixed by replacing every em dash with an ASCII hyphen, removing the encoding dependency entirely. Found by auditing every near-duplicate script after diagnosing the same bug in `intune-acium-remediation.ps1`/`intune-acium-detection.ps1` from a real device's `AgentExecutor.log`.

### 1.0.2 — 2026-09-17

**Security fix:** the Authenticode publisher check compared the expected CN against the MSI signer's full X.509 Subject using `-notlike "*$ExpectedPublisherCN*"` — a wildcard substring match, not an exact CN comparison. With enforcement enabled, a different, unrelated valid certificate whose Subject merely contained the configured text (or wildcard characters) could pass. The script now extracts the actual CN via `GetNameInfo(SimpleName)` and compares it exactly against `$ExpectedPublisherCN`.

**Bugfix:** the no-op path that refreshes the stored ETag (when the package hash is unchanged but the server's ETag has) was overwriting `last-installed.json` with only `Etag`/`Sha256`/`InstalledAt`, silently dropping `ProductCode`/`Version`/`ScriptVersion` and bumping `InstalledAt` even though no install occurred. It now preserves the rest of the saved state and only refreshes the ETag. Both issues flagged by automated PR review comments (GitHub Copilot / CodeRabbit) on `Acium-Inc/rmm-scripts` PR #1.

### 1.0.1 — 2026-09-16

**Security fix:** if hardening the ACL on `$LogDir`/`$WorkDir` (SECTION 2) failed, the script previously logged a warning and continued anyway — proceeding to stage and execute a privileged MSI, and recursively delete, inside a directory that may still have been writable by non-admins (the ProgramData-inherited-DACL/junction attack the hardening step exists to close off). It now fails closed: an ACL-hardening failure logs an error and exits with a new code `2` instead of proceeding. Flagged by a GitHub Copilot PR review comment; see `CLAUDE.md`'s exit-code table and this folder's readme for the new code.

### 1.0.0 — 2026-09-16

Initial version of `ninjaone-acium.ps1`, adapted from `generic-acium.ps1`/`dattormm-acium.ps1` (both at 1.1.0) for NinjaOne. Reads its configuration (`AgentDownloadUrl`, `AgentOrganization`, `ExpectedPublisherCN`) from NinjaOne Automation Script Variables, injected into the script's environment for the run — the same shape as Datto RMM's Component Variables. Install/change-check/prerequisite/logging logic is otherwise identical to the other platform scripts.

## connectwise-rmm/

### 1.0.3 — 2026-09-18

**Critical bugfix:** same em-dash/no-BOM parsing bug as `intune/` 1.0.3 below and `ninjaone/` 1.0.3 above — this file had no BOM and em dashes in live `Write-Log` strings, which Windows PowerShell 5.1 can misdecode (absent a BOM) into a curly quote character that breaks string/brace parsing before the script runs at all. Fixed by replacing every em dash with an ASCII hyphen.

### 1.0.2 — 2026-09-17

**Security fix + bugfix:** same two fixes as `ninjaone/` 1.0.2 above — the Authenticode CN check now does an exact comparison against the certificate's extracted CN instead of a wildcard substring match against the full Subject, and the no-op ETag-refresh path now preserves the rest of the saved state instead of dropping `ProductCode`/`Version`/`ScriptVersion` and touching `InstalledAt`. Both flagged by automated PR review comments on `Acium-Inc/rmm-scripts` PR #1.

### 1.0.1 — 2026-09-16

**Security fix:** same ACL-hardening fail-closed fix as `ninjaone/` 1.0.1 above — if `Protect-Directory` (SECTION 2) failed on `$LogDir`/`$WorkDir`, the script now exits `2` instead of warning and continuing with a privileged install against a directory that may still be writable by non-admins. Flagged by a GitHub Copilot PR review comment on this file specifically.

### 1.0.0 — 2026-09-16

Initial version of `connectwise-rmm-acium.ps1`, adapted from `generic-acium.ps1`/`dattormm-acium.ps1` (both at 1.1.0) for ConnectWise RMM (the Asio-based SaaS product, not ConnectWise Automate/LabTech, which uses a different scripting engine). ConnectWise RMM's exact mechanism for injecting a named script variable into a PowerShell script's environment could not be confirmed from public documentation at the time of writing, so configuration is **hardcoded** in SECTION 1 (same pattern as `generic-acium.ps1`) — see the `UNVERIFIED` note in the script's `.NOTES` header and the readme's opening section for what was and wasn't confirmed, and how to switch to variable-based config if you confirm the mechanism in your own tenant. Install/change-check/prerequisite/logging logic is otherwise identical to the other platform scripts.

## syncro/

### 1.0.3 — 2026-09-18

**Critical bugfix:** same em-dash/no-BOM parsing bug as `intune/` 1.0.3 below and `ninjaone/` 1.0.3 above — this file had no BOM and em dashes in live `Write-Log` strings, which Windows PowerShell 5.1 can misdecode (absent a BOM) into a curly quote character that breaks string/brace parsing before the script runs at all. Fixed by replacing every em dash with an ASCII hyphen.

### 1.0.2 — 2026-09-17

**Security fix + bugfix:** same two fixes as `ninjaone/` 1.0.2 above — the Authenticode CN check now does an exact comparison against the certificate's extracted CN instead of a wildcard substring match against the full Subject, and the no-op ETag-refresh path now preserves the rest of the saved state instead of dropping `ProductCode`/`Version`/`ScriptVersion` and touching `InstalledAt`. Both flagged by automated PR review comments on `Acium-Inc/rmm-scripts` PR #1.

### 1.0.1 — 2026-09-16

**Security fix:** same ACL-hardening fail-closed fix as `ninjaone/` 1.0.1 above — if `Protect-Directory` (SECTION 2) failed on `$LogDir`/`$WorkDir`, the script now exits `2` instead of warning and continuing with a privileged install against a directory that may still be writable by non-admins.

### 1.0.0 — 2026-09-16

Initial version of `syncro-acium.ps1`, adapted from `generic-acium.ps1`/`dattormm-acium.ps1` (both at 1.1.0) for Syncro. Reads its configuration (`AgentDownloadUrl`, `AgentOrganization`, `ExpectedPublisherCN`) from Syncro Script Variables — confirmed via Syncro's own documentation to be injected as bare top-level PowerShell variables (e.g. `$AgentDownloadUrl`), not `$env:`-prefixed environment variables like Datto RMM/NinjaOne use; `Agent`-prefixed variable names avoid colliding with this script's own internal `$DownloadUrl`/`$Organization` variables. Install/change-check/prerequisite/logging logic is otherwise identical to the other platform scripts.

## n-able/

### 1.0.3 — 2026-09-18

**Critical bugfix:** same em-dash/no-BOM parsing bug as `intune/` 1.0.3 below and `ninjaone/` 1.0.3 above — this file had no BOM and em dashes in live `Write-Log` strings, which Windows PowerShell 5.1 can misdecode (absent a BOM) into a curly quote character that breaks string/brace parsing before the script runs at all. Fixed by replacing every em dash with an ASCII hyphen.

### 1.0.2 — 2026-09-17

**Security fix + bugfix:** same two fixes as `ninjaone/` 1.0.2 above — the Authenticode CN check now does an exact comparison against the certificate's extracted CN instead of a wildcard substring match against the full Subject, and the no-op ETag-refresh path now preserves the rest of the saved state instead of dropping `ProductCode`/`Version`/`ScriptVersion` and touching `InstalledAt`. Both flagged by automated PR review comments on `Acium-Inc/rmm-scripts` PR #1.

### 1.0.1 — 2026-09-16

**Security fix:** same ACL-hardening fail-closed fix as `ninjaone/` 1.0.1 above — if `Protect-Directory` (SECTION 2) failed on `$LogDir`/`$WorkDir`, the script now exits `2` instead of warning and continuing with a privileged install against a directory that may still be writable by non-admins.

### 1.0.0 — 2026-09-16

Initial version of `n-able-acium.ps1`, adapted from `generic-acium.ps1`/`dattormm-acium.ps1` (both at 1.1.0), targeting **N-central** (Automation Manager's "Run PowerShell Script" Object) rather than N-sight RMM — N-central has documented Input/Output Parameters built specifically for PowerShell, while N-sight RMM's custom-script docs only show argument passing for batch/bash/VBScript. N-central's exact parameter-injection mechanism and default execution context could not be confirmed from public documentation, so the script reads its configuration via a standard `param()` block (the safest documented option) and flags both points as `UNVERIFIED` in the script's `.NOTES` header and the readme, with a test procedure to confirm SYSTEM context and parameter delivery before trusting it in production. Install/change-check/prerequisite/logging logic is otherwise identical to the other platform scripts.

## intune/

### 1.0.3 — 2026-09-18

**Critical bugfix:** both scripts were saved as UTF-8 without a BOM and contained em dashes (`—`) in comments and in one `Write-Host` string (`intune-acium-detection.ps1`'s "no prior install state is recorded" message). Windows PowerShell 5.1 only reads a `.ps1` file as UTF-8 when it has a BOM; without one it falls back to the system ANSI code page, which misdecodes the em dash's UTF-8 bytes into a curly right double-quote (U+201D) — a character PowerShell's parser accepts as an alternate string delimiter. That corrupted string/brace parsing well before the script did anything, so it failed at the PowerShell parse stage with "string is missing the terminator" / "missing closing '}'" errors (exit code 1, from `AgentExecutor.log`) before creating `C:\ProgramData\AciumSensor` or writing anything to `deploy.log` — both `intune-acium-detection.ps1` and `intune-acium-remediation.ps1` were completely non-functional on any endpoint without a matching code page. Fixed by replacing all em dashes with ASCII hyphens in both files, removing the encoding dependency entirely. Found via a real device reporting "Detection status - with issues" / "Remediation status: failed" with no `AciumSensor` folder on disk, diagnosed from `AgentExecutor.log`.

### 1.0.2 — 2026-09-17 (intune-acium-remediation.ps1 only)

**Security fix + bugfix:** same two fixes as `ninjaone/` 1.0.2 above — the Authenticode CN check now does an exact comparison against the certificate's extracted CN instead of a wildcard substring match against the full Subject, and the no-op ETag-refresh path now preserves the rest of the saved state instead of dropping `ProductCode`/`Version`/`ScriptVersion` and touching `InstalledAt`. Both flagged by automated PR review comments on `Acium-Inc/rmm-scripts` PR #1. `intune-acium-detection.ps1` is unaffected — it never performs the signature check or writes `last-installed.json`.

### 1.0.1 — 2026-09-16 (intune-acium-remediation.ps1 only)

**Security fix:** same ACL-hardening fail-closed fix as `ninjaone/` 1.0.1 above — if `Protect-Directory` (SECTION 2) failed on `$LogDir`/`$WorkDir`, `intune-acium-remediation.ps1` now exits `2` instead of warning and continuing with a privileged install against a directory that may still be writable by non-admins. `intune-acium-detection.ps1` is unaffected — it never calls `Protect-Directory`.

### 1.0.0 — 2026-09-16

Initial version, split into `intune-acium-detection.ps1` (read-only) and `intune-acium-remediation.ps1` (does the install), deployed as an Intune Remediation rather than a single script — Intune's plain "platform script" mechanism runs once per device and never recurs, which doesn't fit this repo's recurring/idempotent design, and Remediations have no per-deployment variable system, so configuration is hardcoded in both scripts (same pattern as `generic-acium.ps1`) between `EDIT THESE VALUES` markers. `$DownloadUrl` must be kept identical across both files — see the `.NOTES` in `intune-acium-remediation.ps1`. `intune-acium-remediation.ps1`'s install logic is otherwise adapted directly from `generic-acium.ps1` 1.1.0.

## generic/

### 1.2.2 — 2026-09-18

**Hardening:** while diagnosing the `intune/` 1.0.3 parsing bug (em dashes in a BOM-less `.ps1` get misdecoded by Windows PowerShell 5.1 into a curly quote character that breaks string/brace parsing), this file was found to already carry a UTF-8 BOM, which does protect it from that specific failure today. But that protection depends on every future edit/paste preserving the BOM — fragile given this script gets pasted into different RMM script editors. Replaced all em dashes with ASCII hyphens and dropped the now-unnecessary BOM, removing the encoding dependency entirely rather than relying on it being preserved.

### 1.2.1 — 2026-09-17

**Security fix + bugfix:** same two fixes as `ninjaone/` 1.0.2 above — the Authenticode CN check now does an exact comparison against the certificate's extracted CN instead of a wildcard substring match against the full Subject, and the no-op ETag-refresh path now preserves the rest of the saved state instead of dropping `ProductCode`/`Version`/`ScriptVersion` and touching `InstalledAt`. Both flagged by automated PR review comments on `Acium-Inc/rmm-scripts` PR #1 (on the new platform scripts, which shared this same logic — applied here since `generic-acium.ps1` had the identical bugs).

### 1.2.0 — 2026-09-16

**Security fix:** if hardening the ACL on `$LogDir`/`$WorkDir` (SECTION 2) failed, the script previously logged a warning and continued anyway — proceeding to stage and execute a privileged MSI, and recursively delete, inside a directory that may still have been writable by non-admins (the ProgramData-inherited-DACL/junction attack the hardening step exists to close off). It now fails closed: an ACL-hardening failure logs an error and exits with a new code `2` instead of proceeding. Flagged by a GitHub Copilot PR review comment (on `connectwise-rmm-acium.ps1`, which shares this same SECTION 2 logic); applied to every near-duplicate script in this repo. See the updated exit-code table in `CLAUDE.md` and this folder's readme.

### 1.1.0 — 2026-09-14

Promoted from `generic-acium-beta.ps1` to production as `generic-acium.ps1` after testing. Changes versus the prior production script:

- **ProductCode self-check.** The hardcoded `$ProductCode` is now cross-checked against the Uninstall registry. If Windows Installer says "not installed" but a matching product IS registered, the script logs the real ProductCode and uses it, instead of silently taking the first-time-install branch on an existing install (which produced error 1638).
- **Reboot gate.** If the ASP.NET Core hosting bundle install returns 3010 (reboot required), the script now stops instead of running the sensor MSI whose service can't yet start — that ordering was reproducing the exact 1603/1920 failure the prereq check exists to prevent. The next scheduled run completes the install.
- **SHA256 change detection in addition to ETag.** If the server ever stops returning an ETag header, the old script would reinstall the MSI on every scheduled run, fleet-wide, forever — and report success every time. The package hash now catches that.
- **Install state is read from the service, not a running process.** A stopped-but-installed service no longer looks like "not installed" and triggers a reinstall on every run.
- **`$WorkDir`/`$LogDir` ACLs are hardened.** `C:\ProgramData`'s default DACL lets standard users create directories in inherited subfolders; this script stages an MSI there and executes it as SYSTEM.
- **Authenticode check** on the MSI before running it as SYSTEM.
- **`Write-Log` can no longer kill the script.** Under `$ErrorActionPreference='Stop'`, a locked log file was an unhandled terminating error — exiting 1, which the exit-code table reads as "download failed."
- **msiexec 1618** ("another install in progress") is now retried.
- **TLS is OR'd into the existing protocol set** rather than replacing it, so TLS 1.3 isn't disabled on newer OSes.
- **Log files rotate** instead of growing unbounded; the MSI log appends instead of truncating every run.
- **Downloads retry, use the system proxy, and MSI property values are quoted correctly** (an `$Organization` containing a space used to silently break the old argument-array approach).
- **Added `$ScriptVersion`** tracking (this changelog).

## dattormm/

### 1.2.2 — 2026-09-18

**Hardening:** same as `generic/` 1.2.2 above — this file already carried a UTF-8 BOM, which does protect it from the em-dash parsing bug found in `intune/` 1.0.3, but that protection is fragile (depends on the BOM surviving every future edit/paste into Datto RMM's Component editor). Replaced all em dashes with ASCII hyphens and dropped the now-unnecessary BOM.

### 1.2.1 — 2026-09-17

**Security fix + bugfix:** same two fixes as `ninjaone/` 1.0.2 above — the Authenticode CN check now does an exact comparison against the certificate's extracted CN instead of a wildcard substring match against the full Subject, and the no-op ETag-refresh path now preserves the rest of the saved state instead of dropping `ProductCode`/`Version`/`ScriptVersion` and touching `InstalledAt`. Both flagged by automated PR review comments on `Acium-Inc/rmm-scripts` PR #1 (on the new platform scripts, which shared this same logic — applied here since `dattormm-acium.ps1` had the identical bugs).

### 1.2.0 — 2026-09-16

**Security fix:** if hardening the ACL on `$LogDir`/`$WorkDir` (SECTION 2) failed, the script previously logged a warning and continued anyway — proceeding to stage and execute a privileged MSI, and recursively delete, inside a directory that may still have been writable by non-admins (the ProgramData-inherited-DACL/junction attack the hardening step exists to close off). It now fails closed: an ACL-hardening failure logs an error and exits with a new code `2` instead of proceeding. Flagged by a GitHub Copilot PR review comment (on `connectwise-rmm-acium.ps1`, which shares this same SECTION 2 logic); applied to every near-duplicate script in this repo. See the updated exit-code table in `CLAUDE.md` and this folder's readme.

### readme.md — 2026-09-16 (docs only, no script change)

Rewrote the "Setup in Datto RMM" section with the actual current console flow, confirmed against a live tenant, and added screenshots for each step (`dattormm/images/`): Component Library's "Create Component" button (the button is labeled "Create Component", not "New Component"), the Create Component form fields (Name/Description/Category/Script type), setting Sites and adding Variables, the filled-in Component Variables, and the full Job-creation flow (Automation > Jobs > Create Job > Add Component > confirm variable values and Targets > Execution: Run as system account > Create Job). Removed the old standalone "Set execution context" step — execution context (System vs. logged-in user) is actually set per-Job during Job creation, not on the Component itself; there's no such setting on the Component form.

### 1.1.0 — 2026-09-14

Promoted from `dattormm-acium-beta.ps1` to production as `dattormm-acium.ps1` after testing. Changes versus the prior production script:

- **ORGANIZATION support**, via the new `AgentOrganization` Component Variable. The previous Datto script had no way to set it at all, so Datto-deployed sensors installed with no organization ID while the generic script set one — a silent divergence between the two copies.
- **ProductCode self-check.** The hardcoded `$ProductCode` is now cross-checked against the Uninstall registry. If Windows Installer says "not installed" but a matching product IS registered, the script logs the real ProductCode and uses it, instead of silently taking the first-time-install branch on an existing install (which produced error 1638).
- **Reboot gate.** If the ASP.NET Core hosting bundle install returns 3010 (reboot required), the script now stops instead of running the sensor MSI whose service can't yet start — that ordering was reproducing the exact 1603/1920 failure the prereq check exists to prevent. The next scheduled run completes the install.
- **SHA256 change detection in addition to ETag.** If the server ever stops returning an ETag header, the old script would reinstall the MSI on every scheduled run, fleet-wide, forever — and report success every time. The package hash now catches that.
- **Install state is read from the service, not a running process.** A stopped-but-installed service no longer looks like "not installed" and triggers a reinstall on every run.
- **`$WorkDir`/`$LogDir` ACLs are hardened.** `C:\ProgramData`'s default DACL lets standard users create directories in inherited subfolders; this script stages an MSI there and executes it as SYSTEM.
- **Authenticode check** on the MSI before running it as SYSTEM.
- **`Write-Log` can no longer kill the script.** Under `$ErrorActionPreference='Stop'`, a locked log file was an unhandled terminating error — exiting 1, which the exit-code table reads as "download failed."
- **msiexec 1618** ("another install in progress") is now retried.
- **TLS is OR'd into the existing protocol set** rather than replacing it, so TLS 1.3 isn't disabled on newer OSes.
- **Log files rotate** instead of growing unbounded; the MSI log appends instead of truncating every run.
- **Downloads retry, use the system proxy, and MSI property values are quoted correctly** (an `AgentOrganization` containing a space used to silently break the old argument-array approach).
- **Added `$ScriptVersion`** tracking (this changelog).
