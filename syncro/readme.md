# Acium Sensor — Syncro Deployment Script

> **Status: Untested.** This script has not yet been run against a live Syncro deployment. Validate it end-to-end in a lab/pilot environment before rolling it out to production endpoints.

This folder contains `syncro-acium.ps1`, a PowerShell script that installs and keeps the Acium Sensor up to date across a fleet of Windows endpoints via Syncro.

It's designed to run as a **recurring Syncro script**, assigned to a Policy's **Script Schedule**, safely skipping machines that are already up to date and only reinstalling when something's actually changed.

## A note on how configuration reaches this script

Unlike Datto RMM/NinjaOne, which inject Component/Script Variables as environment variables (`$env:Name`), Syncro's own documentation example shows a script variable named `runtime` referenced directly in the script body as plain `$runtime`, not `$env:runtime` ([Manage Scripts](https://docs.syncrosecure.com/scripting-apis/manage-scripts): *"Make sure to add your variables in the text editor for your Script (e.g., echo "$runtime")."*). That confirms the reference syntax — a bare top-level PowerShell variable matching the name you give it in Syncro's "Add Script Variable" UI — but Syncro doesn't publicly document the exact injection mechanism or its timing in more detail. `syncro-acium.ps1` uses `Agent`-prefixed names (`AgentDownloadUrl`, not `DownloadUrl`) specifically so Syncro's injected variables can't collide with the script's own internal `$DownloadUrl`/`$Organization` variables regardless of which mechanism it turns out to be. If your tenant's behavior differs, confirm against current Syncro docs and adjust SECTION 1 of the script.

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

## Prerequisites

- Syncro agent installed and checking in on target endpoints.
- Endpoints running Windows with PowerShell 5.1 (Windows PowerShell) or later.
- Outbound HTTPS access from endpoints to your sensor package's download URL and to `aka.ms` (for the ASP.NET Core Runtime installer, only needed on machines that don't already have it).

## Setup in Syncro

### 1. Add the script

In Syncro, go to **Scripts** (or **Automation > Scripts**, naming varies by tenant/version) and create a new script. Set its type to **PowerShell**.

### 2. Paste in the script

Copy the contents of `syncro-acium.ps1` into the script body.

### 3. Add the Script Variables

Click **Add Script Variable** (type **String**) for each of these:

| Variable name | Required | Example value |
|---|---|---|
| `AgentDownloadUrl` | Yes | `https://storage.googleapis.com/ebm-sensors-prod/win/acium-sensor-setup-0.17.3.zip` |
| `AgentOrganization` | No | Your org/tenant ID, passed to the MSI as the `ORGANIZATION` property |
| `ExpectedPublisherCN` | No | Expected Authenticode signer subject CN, e.g. `Acium, Inc.` — when set, an MSI not validly signed by it is refused |

> Bumping to a new sensor version later is just updating `AgentDownloadUrl` — you don't need to edit the script itself. If different customers/sites need different `AgentOrganization` values, set that variable's value per script assignment/policy rather than maintaining separate copies of the script.

### 4. Set execution context

When configuring the script for scheduled or ad hoc execution, set **Run As** to **System**, not the logged-in user. Running as anything other than System can surface Windows security prompts (UAC) that a background service context never would.

### 5. Deploy as a Script Schedule

In a Policy, under the Policy Builder's **Scripting** category, add this script under **Script Schedules** with a recurring interval (Syncro supports intervals from every 15 minutes up to monthly; Syncro's own guidance recommends no more than daily for scheduled scripts). Because the script checks for changes before doing any real work, recurring execution is cheap — most runs will be a quick no-op. You can also run it once, ad hoc, against a specific asset from the Assets & RMM page to test it before scheduling.

## Logs

The script writes its own logs to the endpoint, independent of what Syncro captures from the run's output:

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
| `4` | Missing or invalid Script Variable (`AgentDownloadUrl` empty, or `AgentOrganization` contains a double quote) |
| `5` | Zip extraction failed / `AciumSensorInstall.msi` not found inside the package |
| `6` | MSI failed Authenticode signature verification against `ExpectedPublisherCN` |

## Known dependencies

- **ASP.NET Core 8.0 Runtime** is required for the sensor service to start. The script checks for and installs this automatically, but it does add extra time (and a download) the first time it runs on any given machine. Subsequent runs skip this once the runtime is present.
- The sensor's `.zip` package must contain a file named exactly `AciumSensorInstall.msi` — the script searches for this filename specifically.

## Troubleshooting

- **Script exits with code 2**: The script couldn't lock down `$LogDir` or `$WorkDir`'s permissions (`Set-Acl`/`Get-Acl` failed), so it refused to proceed rather than stage/execute a privileged MSI in a directory that might still be writable by non-admins. This should be very rare when running as SYSTEM — check `deploy.log` for the exact directory and investigate why an ACL change failed there (endpoint security software, filesystem issue, or an already-tampered-with directory are the likely causes).
- **UAC prompt appears on the client**: This shouldn't happen if the script is genuinely running as System — SYSTEM-context execution never triggers UAC. If you see this, first confirm the **Run As** setting on the script/schedule, then check `deploy.log`'s `Running as:` line to see what account actually ran it.
- **Install seems to succeed but the sensor doesn't run**: Check whether the ASP.NET Core 8.0 Runtime installed successfully in `deploy.log`, and confirm via `Get-Service AciumSensor` on the endpoint. If the runtime is present and the service still isn't there, check `msi-install.log` for the `Feature: Main; ... Action:` line — if it says `Action: Null` for every component (instead of `Action: Local`), Windows Installer silently did nothing (see the exit-code-3/1638 entry below for why).
- **Script always reinstalls, never skips**: Check that the download URL returns an `ETag` header (most servers, including Google Cloud Storage, do this by default) and that `last-installed.json` is being written and persisted between runs.
- **Install fails with exit code 3 and `msi-install.log` shows error 1638 ("Another version of this product is already installed")**: The sensor's MSI keeps the same `ProductCode` across versions, so Windows Installer refuses a plain reinstall whenever that `ProductCode` is already registered — most commonly because the sensor was installed manually at some point (outside this script), so there's no `last-installed.json` to make the script skip it. The script checks whether the product is already installed via Windows Installer's own `ProductState` API (look for `$isProductInstalled` in SECTION 8) and only adds `REINSTALL=ALL REINSTALLMODE=vomus` in that case — those properties are needed to force a reinstall over an existing registration, but must NOT be passed on a genuine first-time install: doing so makes Windows Installer resolve every component's install action to `Null`, silently installing nothing while still reporting exit code 0.
- **Script exits 0 but nothing was installed and the log says "deferred"**: The ASP.NET Core Hosting Bundle needed a reboot to finish. This is expected — the script intentionally stops rather than installing the sensor against a runtime that can't start yet. The next scheduled run completes the install once the machine has rebooted.
