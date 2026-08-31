# RMM Scripts

A collection of scripts for deploying and managing software across endpoints via RMM (Remote Monitoring and Management) platforms.

## Structure

Each subfolder targets a specific RMM platform (or a platform-agnostic use case) and contains the scripts, along with its own README, for deploying/managing agents.

| Folder | Platform | Contents |
|---|---|---|
| [`dattormm/`](dattormm/) | Datto RMM | Deployment script for the Acium Sensor agent |
| [`generic/`](generic/) | Any RMM / scheduled task / manual | Deployment script for the Acium Sensor agent, with configuration hardcoded directly in the script instead of an RMM's variable system |

## Adding a new script

1. Create a subfolder named for the target platform (e.g. `ninjaone/`, `n-able/`).
2. Add the script(s) plus a `readme.md` documenting what it does, its prerequisites, required variables/inputs, and exit codes.
3. Link the new folder from the table above.
