# Acium Sensor — ConnectWise RMM Deployment Script

> **Status: Untested.** This script has not yet been run against a live ConnectWise RMM deployment. Validate it end-to-end in a lab/pilot environment before rolling it out to production endpoints.

This folder contains `connectwise-rmm-acium.ps1`, a PowerShell script that installs and keeps the Acium Sensor up to date across a fleet of Windows endpoints via **ConnectWise RMM** — the Asio-based SaaS RMM product ConnectWise currently markets as "ConnectWise RMM." This is a different product from **ConnectWise Automate** (formerly LabTech), which has its own separate scripting engine; if you're on Automate, adapt this script rather than assuming it drops in unchanged.

It's designed to run as a **recurring ConnectWise RMM script**, safely skipping machines that are already up to date and only reinstalling when something's actually changed.

## ⚠️ Configuration mechanism is UNVERIFIED — read before deploying

Datto RMM and NinjaOne both expose a documented per-script variable system that injects named values into a script's process as environment variables at runtime, which is what `dattormm-acium.ps1` and `ninjaone-acium.ps1` use. Public ConnectWise RMM documentation available while writing this script did not confirm whether an equivalent exists for a plain "PowerShell Script" step — ConnectWise RMM does have variable concepts (predefined variables mapped to custom fields, user-defined variables, and `%output%` for capturing a step's output), referenced with `%VariableName%` syntax, but it's unclear whether that's genuine environment-variable injection into a single script or a text-substitution mechanism scoped to chaining ConnectWise's own script-editor blocks together.

**Rather than guess, this script hardcodes its configuration** (same pattern as `generic/generic-acium.ps1`) so it works correctly regardless of how your tenant's variable system behaves. If your ConnectWise RMM instance *does* support wiring a custom field into a script as a true `$env:` variable, you can switch this script's SECTION 1 to read from `$env:` the way `dattormm-acium.ps1`/`ninjaone-acium.ps1` do — confirm the exact variable name/casing ConnectWise exposes it under first, and record the change in this repo's `CHANGELOG.md`.

Also unverified: exactly how ConnectWise RMM's script/task history UI surfaces this script's process exit code. The script still exits with specific, documented codes (see below) so `deploy.log` carries full diagnostic detail regardless of what the console shows.

## What the script does

On each run, in order:

1. **Takes a machine-wide lock** so an overlapping run (a slow previous run plus a new scheduled trigger, or a manual run stacked on a scheduled one) can't run twice at once.
2. **Checks whether anything's changed** — compares the source file's ETag (a fingerprint from the download server) against what was saved from the last successful run, *and* checks whether the `AciumSensor` Windows service is present. Only skips the rest of the script if both say "nothing to do."
3. **Downloads** the sensor package (a `.zip`) and hashes it (SHA256) as a second, server-independent change check, in case the server ever stops sending an ETag.
4. **Checks for the ASP.NET Core 8.0 Runtime** — a hard requirement for the sensor to run. If it's missing, silently installs Microsoft's official Hosting Bundle before doing anything else. If that install needs a reboot, the script defers the sensor install to the next scheduled run rather than installing against a runtime that can't start yet.
5. **Extracts** the `.zip`, locates `AciumSensorInstall.msi` inside it, and checks its Authenticode signature.
6. **Installs** the MSI silently via `msiexec`, correctly distinguishing a first-time install from a reinstall (see Known dependencies below for why that distinction matters), and verifies afterward that the sensor is actually present.
7. **Cleans up** downloaded files and records the new ETag/SHA256 for next time — only after a verified successful install.

The script is idempotent and safe to run on a schedule — a machine that's already current will do almost nothing (a quick network check, then exit).

## Configuration

All configuration is **hardcoded** in SECTION 1, between the `EDIT THESE VALUES` markers (see the warning above for why):

```powershell
$DownloadUrl = 'https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup-0.17.3.zip'
$Organization = ''
$ExpectedPublisherCN = ''
```

- `$DownloadUrl` — the direct URL of the pinned agent `.zip`. **Required.**
- `$Organization` — the organization/tenant ID this sensor should report under, passed to the MSI as the `ORGANIZATION` property. **Optional.** If you maintain a separate copy of this script per client/site in ConnectWise RMM, this is typically the one line that differs between copies.
- `$ExpectedPublisherCN` — expected Authenticode signer subject CN. **Optional**, but recommended once you've confirmed the real signer from a first run's log.

Bumping to a new sensor version later means editing `$DownloadUrl` and redeploying the script to ConnectWise RMM — there is no external variable to update instead.

## Prerequisites

- ConnectWise RMM agent installed and checking in on target endpoints.
- Endpoints running Windows with PowerShell 5.1 (Windows PowerShell) or later.
- Outbound HTTPS access from endpoints to your sensor package's download URL and to `aka.ms` (for the ASP.NET Core Runtime installer, only needed on machines that don't already have it).

## Setup in ConnectWise RMM

### 1. Create a new script

In the ConnectWise RMM script editor, create a new script and add a PowerShell script step.

### 2. Paste in the script

Copy the contents of `connectwise-rmm-acium.ps1` into the PowerShell step's body. Edit `$DownloadUrl` (and optionally `$Organization`/`$ExpectedPublisherCN`) directly in the pasted script before saving, per Configuration above.

### 3. Confirm execution context

ConnectWise RMM scripts typically execute in the SYSTEM context by default. Confirm this is the case for your script/task type before deploying broadly — `deploy.log`'s `Running as:` line on a test machine is the definitive check (should read `NT AUTHORITY\SYSTEM`).

### 4. Deploy as a recurring scheduled script

Schedule the script to run recurring against your target device group — ConnectWise RMM supports hourly, daily, and weekly recurrence. Because the script checks for changes before doing any real work, recurring execution is cheap — most runs will be a quick no-op. Avoid scheduling it too frequently across a large device count purely to reduce agent/API load; daily is sufficient for a "keep the sensor current" job.

## Logs

The script writes its own logs to the endpoint, independent of what ConnectWise RMM captures from the run's output:

| File | What's in it |
|---|---|
| `C:\ProgramData\AciumSensor\Logs\deploy.log` | The script's own step-by-step log — what it checked, downloaded, and decided on each run. |
| `C:\ProgramData\AciumSensor\Logs\msi-install.log` | Windows Installer's verbose log for the actual MSI install — useful for diagnosing install failures. |
| `C:\ProgramData\AciumSensor\Install\last-installed.json` | Small state file recording the ETag and SHA256 of the last successfully installed package, used for the change check. |

If a deployment isn't behaving as expected, `deploy.log` is the first place to look — it logs which account it's running as, the ETag/hash comparison result, whether the ASP.NET Core Runtime was found, and the final `msiexec` exit code.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — installed, already up to date (no-op), or deferred pending a reboot (see the log for which) |
| `1` | Download failed (sensor package or ASP.NET Core Runtime installer) |
| `2` | Could not secure the working/log directory (ACL hardening failed) — refused to proceed with a privileged install |
| `3` | Install failed (sensor MSI or ASP.NET Core Runtime installer) |
| `4` | Missing or invalid configuration value (`$DownloadUrl` empty, or `$Organization` contains a double quote) |
| `5` | Zip extraction failed / `AciumSensorInstall.msi` not found inside the package |
| `6` | MSI failed Authenticode signature verification against `$ExpectedPublisherCN` |

How ConnectWise RMM's own console surfaces this process exit code is unverified (see the warning above) — `deploy.log` is the authoritative source regardless.

## Known dependencies

- **ASP.NET Core 8.0 Runtime** is required for the sensor service to start. The script checks for and installs this automatically, but it does add extra time (and a download) the first time it runs on any given machine. Subsequent runs skip this once the runtime is present.
- The sensor's `.zip` package must contain a file named exactly `AciumSensorInstall.msi` — the script searches for this filename specifically.

## Troubleshooting

- **Script exits with code 2**: The script couldn't lock down `$LogDir` or `$WorkDir`'s permissions (`Set-Acl`/`Get-Acl` failed), so it refused to proceed rather than stage/execute a privileged MSI in a directory that might still be writable by non-admins. This should be very rare when running as SYSTEM — check `deploy.log` for the exact directory and investigate why an ACL change failed there (endpoint security software, filesystem issue, or an already-tampered-with directory are the likely causes).
- **UAC prompt appears on the client**: This shouldn't happen if the script is genuinely running as SYSTEM — SYSTEM-context execution never triggers UAC. If you see this, check `deploy.log`'s `Running as:` line to see what account actually ran the script, and confirm your script/task type isn't configured for logged-on-user context.
- **Install seems to succeed but the sensor doesn't run**: Check whether the ASP.NET Core 8.0 Runtime installed successfully in `deploy.log`, and confirm via `Get-Service AciumSensor` on the endpoint. If the runtime is present and the service still isn't there, check `msi-install.log` for the `Feature: Main; ... Action:` line — if it says `Action: Null` for every component (instead of `Action: Local`), Windows Installer silently did nothing (see the exit-code-3/1638 entry below for why).
- **Script always reinstalls, never skips**: Check that the download URL returns an `ETag` header (most servers, including Google Cloud Storage, do this by default) and that `last-installed.json` is being written and persisted between runs.
- **Install fails with exit code 3 and `msi-install.log` shows error 1638 ("Another version of this product is already installed")**: The sensor's MSI keeps the same `ProductCode` across versions, so Windows Installer refuses a plain reinstall whenever that `ProductCode` is already registered — most commonly because the sensor was installed manually at some point (outside this script), so there's no `last-installed.json` to make the script skip it. The script checks whether the product is already installed via Windows Installer's own `ProductState` API (look for `$isProductInstalled` in SECTION 8) and only adds `REINSTALL=ALL REINSTALLMODE=vomus` in that case — those properties are needed to force a reinstall over an existing registration, but must NOT be passed on a genuine first-time install: doing so makes Windows Installer resolve every component's install action to `Null`, silently installing nothing while still reporting exit code 0.
- **Script exits 0 but nothing was installed and the log says "deferred"**: The ASP.NET Core Hosting Bundle needed a reboot to finish. This is expected — the script intentionally stops rather than installing the sensor against a runtime that can't start yet. The next scheduled run completes the install once the machine has rebooted.
