# RMM Scripts

A collection of scripts for deploying and managing software across endpoints via RMM (Remote Monitoring and Management) platforms.

## Structure

Each subfolder targets a specific RMM platform and contains the scripts, along with its own README, for deploying/managing agents through that platform.

| Folder | Platform | Contents |
|---|---|---|
| [`dattormm/`](dattormm/readme.md) | Datto RMM | Deployment script for the Acium Sensor agent |

## Adding a new script

1. Create a subfolder named for the target platform (e.g. `ninjaone/`, `n-able/`).
2. Add the script(s) plus a `readme.md` documenting what it does, its prerequisites, required variables/inputs, and exit codes.
3. Link the new folder from the table above.
