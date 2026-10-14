# Acium Sensor — N-able Deployment Script

> **Status: Untested.** This script has not yet been run against a live N-able deployment. Validate it end-to-end in a lab/pilot environment before rolling it out to production endpoints.

> **Product targeted: N-able N-CENTRAL** (Automation Manager), not N-sight RMM. N-able sells two separate RMM products under one brand. This script targets N-central because its Automation Manager has a dedicated "Run PowerShell Script" Object with documented Input/Output Parameters built specifically for PowerShell. N-sight RMM's custom-script docs describe passing arguments via a "Command Line" field, with examples only in batch/bash/VBScript — if you're actually on N-sight RMM, read the **Parameter mechanism** warning below carefully before deploying.

This folder contains `n-able-acium.ps1`, a PowerShell script that installs and keeps the Acium Sensor up to date across a fleet of Windows endpoints via an N-central Automation Manager Policy.

It's designed to run as a **recurring Automation Manager Policy**, safely skipping machines that are already up to date and only reinstalling when something's actually changed.

## ⚠️ Parameter mechanism — unverified, test before relying on it

N-able's documentation confirms that Automation Manager's "Run PowerShell Script" Object requires Input Parameters to be "preceded by `$`" for the script engine to recognize them, but does **not** show a concrete example of the underlying mechanism (environment variable vs. the Object binding directly to a same-named PowerShell parameter vs. literal text substitution). This script uses a standard PowerShell `param()` block at the top of the file — the safest, most portable option for a script that receives values "as if entered directly on the device" — and expects Input Parameters named to match it.

**Before deploying this to more than a single test device:** run the Object once against a test machine with each Input Parameter set to an obviously-distinct value, then check `deploy.log`'s `Download URL:` / `Organization:` lines to confirm the values actually arrived. If your N-central instance instead injects values as environment variables (the way Datto RMM and NinjaOne do — see [`dattormm/`](../dattormm/) and [`ninjaone/`](../ninjaone/) in this repo), change the top of `n-able-acium.ps1` to read `$env:AgentDownloadUrl` etc. instead of the `param()` block.

Similarly, **SYSTEM execution context is unverified**: the docs mention a "Run as Current Logged on User" option on the Object, implying unchecked runs under the N-central agent's own service account, but don't explicitly confirm that account is `NT AUTHORITY\SYSTEM` on every N-central configuration. Confirm via `deploy.log`'s `Running as:` line after your first test run.

## What the script does

On each run, in order:

1. **Takes a machine-wide lock** so an overlapping run (a slow previous run plus a new scheduled trigger, or a manual run stacked on a scheduled one) can't run twice at once.
2. **Checks whether anything's changed** — compares the source file's ETag (a fingerprint from the download server) against what was saved from the last successful run, *and* checks whether the `AciumSensor` Windows service is present. Only skips the rest of the script if both say "nothing to do."
3. **Downloads** the sensor package (a `.zip`) and hashes it (SHA256) as a second, server-independent change check, in case the server ever stops sending an ETag.
4. **Checks for the ASP.NET Core 8.0 Runtime** — a hard requirement for the sensor to run. If it's missing, silently installs Microsoft's official Hosting Bundle before doing anything else. If that install needs a reboot, the script defers the sensor install to the next scheduled run rather than installing against a runtime that can't start yet.
5. **Extracts** the `.zip`, locates `AciumSensorInstall.msi` inside it, and checks its Authenticode signature.
6. **Installs** the MSI silently via `msiexec`, correctly distinguishing a first-time install from a reinstall, and verifies afterward that the sensor is actually present.
7. **Cleans up** downloaded files and records the new ETag/SHA256 for next time — only after a verified successful install.

The script is idempotent and safe to run on a schedule — a machine that's already current will do almost nothing (a quick network check, then exit).

## Prerequisites

- N-central probe/agent installed and checking in on target endpoints.
- Endpoints running Windows with PowerShell 5.1 (Windows PowerShell) or later.
- Outbound HTTPS access from endpoints to your sensor package's download URL and to `aka.ms` (for the ASP.NET Core Runtime installer, only needed on machines that don't already have it).
- An N-central license/edition that includes Automation Manager.

## Setup in N-central

### 1. Create (or open) an Automation Manager Policy

In N-central, go to **Configuration > Automation Manager** and create a new Policy (or edit an existing one) targeting your device group/filter.

### 2. Add a "Run PowerShell Script" Object

Add the **Run PowerShell Script** Object to the Policy, and paste the contents of `n-able-acium.ps1` into it.

### 3. Add the Input Parameters

Define these as **Input Parameters** on the Object (Input Parameter names must be alphabetic only — no numbers, spaces, or symbols):

| Input Parameter name | Type | Required | Example value |
|---|---|---|---|
| `AgentDownloadUrl` | Text | Yes | `https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup-0.17.3.zip` |
| `AgentOrganization` | Text | No | Your org/tenant ID, passed to the MSI as the `ORGANIZATION` property |
| `ExpectedPublisherCN` | Text | No | Expected Authenticode signer subject CN, e.g. `Acium, Inc.` — when set, an MSI not validly signed by it is refused |

See the **Parameter mechanism** warning above — verify these values actually reach the script before trusting this in production.

> Bumping to a new sensor version later is just updating the `AgentDownloadUrl` Input Parameter's value — you don't need to edit the script itself.

### 4. Set execution context

Confirm the Object is **not** set to "Run as Current Logged on User" — leave that option off so it runs under the N-central agent's own service account. Verify this actually resolves to SYSTEM via `deploy.log`'s `Running as:` line (see the warning above).

### 5. Schedule the Policy

Assign the Policy to run on a recurring schedule (e.g. daily) against your target device group. Because the script checks for changes before doing any real work, recurring execution is cheap — most runs will be a quick no-op.

## Logs

The script writes its own logs to the endpoint, independent of what N-central captures from the Object's own output:

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
| `4` | Missing or invalid Input Parameter (`AgentDownloadUrl` empty, or `AgentOrganization` contains a double quote) |
| `5` | Zip extraction failed / `AciumSensorInstall.msi` not found inside the package |
| `6` | MSI failed Authenticode signature verification against `ExpectedPublisherCN` |

Automation Manager only distinguishes success (exit `0`) from failure (any non-zero exit) in its own UI — it does not surface which specific code was returned. Read `deploy.log` for that detail.

## Known dependencies

- **ASP.NET Core 8.0 Runtime** is required for the sensor service to start. The script checks for and installs this automatically, but it does add extra time (and a download) the first time it runs on any given machine. Subsequent runs skip this once the runtime is present.
- The sensor's `.zip` package must contain a file named exactly `AciumSensorInstall.msi` — the script searches for this filename specifically.

## Troubleshooting

- **Input Parameter values don't seem to reach the script (`deploy.log` shows "Download URL: (blank)" or similar)**: This is the unverified part of the setup — see the warning above. Confirm your N-central version actually binds Input Parameters to same-named PowerShell `param()` variables; if not, switch SECTION 1 to read `$env:AgentDownloadUrl` etc. instead.
- **Script exits with code 2**: The script couldn't lock down `$LogDir` or `$WorkDir`'s permissions (`Set-Acl`/`Get-Acl` failed), so it refused to proceed rather than stage/execute a privileged MSI in a directory that might still be writable by non-admins. This should be very rare when running as SYSTEM — check `deploy.log` for the exact directory and investigate why an ACL change failed there (endpoint security software, filesystem issue, or an already-tampered-with directory are the likely causes).
- **UAC prompt appears on the client**: This shouldn't happen if the Object is genuinely running under the agent's service account — SYSTEM-context execution never triggers UAC. If you see this, first confirm the Object isn't set to "Run as Current Logged on User," then check `deploy.log`'s `Running as:` line to see what account actually ran the script.
- **Install seems to succeed but the sensor doesn't run**: Check whether the ASP.NET Core 8.0 Runtime installed successfully in `deploy.log`, and confirm via `Get-Service AciumSensor` on the endpoint. If the runtime is present and the service still isn't there, check `msi-install.log` for the `Feature: Main; ... Action:` line — if it says `Action: Null` for every component (instead of `Action: Local`), Windows Installer silently did nothing (see the exit-code-3/1638 entry below for why).
- **Script always reinstalls, never skips**: Check that the download URL returns an `ETag` header (most servers, including Google Cloud Storage, do this by default) and that `last-installed.json` is being written and persisted between runs.
- **Install fails with exit code 3 and `msi-install.log` shows error 1638 ("Another version of this product is already installed")**: The sensor's MSI keeps the same `ProductCode` across versions, so Windows Installer refuses a plain reinstall whenever that `ProductCode` is already registered — most commonly because the sensor was installed manually at some point (outside this Policy), so there's no `last-installed.json` to make the script skip it. The script checks whether the product is already installed via Windows Installer's own `ProductState` API (look for `$isProductInstalled` in SECTION 8) and only adds `REINSTALL=ALL REINSTALLMODE=vomus` in that case — those properties are needed to force a reinstall over an existing registration, but must NOT be passed on a genuine first-time install: doing so makes Windows Installer resolve every component's install action to `Null`, silently installing nothing while still reporting exit code 0.
- **Script exits 0 but nothing was installed and the log says "deferred"**: The ASP.NET Core Hosting Bundle needed a reboot to finish. This is expected — the script intentionally stops rather than installing the sensor against a runtime that can't start yet. The next scheduled Policy run completes the install once the machine has rebooted.
