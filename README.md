# rundeck-railway

A one-layer image over [`rundeck/rundeck`](https://hub.docker.com/r/rundeck/rundeck)
that makes Rundeck Community deployable on [Railway](https://railway.com) as a
template — no manual first-run steps, no default credentials.

## What this layer adds

| Gap in the published image | What happens here |
|---|---|
| The first admin is `admin`/`admin`, baked into `server/config/realm.properties` at build time, with no environment variable to replace it | `entrypoint.sh` writes a bcrypt credential from `RUNDECK_ADMIN_USER` / `RUNDECK_ADMIN_PASSWORD` onto the volume, and refuses to start if the password is empty |
| The bundled remco template for S3 execution-log storage renders only `bucket` and `region` | The endpoint, path-style flag, credentials and key path are appended as a second `framework.properties` partial, so any S3-compatible endpoint works |
| The S3 execution-log plugin is not shipped with Rundeck | The release jar is dropped into `container-plugins/`, which the image's own sideload script copies into `libext/` each boot |
| The image runs as the non-root `rundeck` user and cannot write a root-owned volume | The entrypoint prepares the volume as root and drops back with `setpriv` |
| Nothing under `/home/rundeck` survives a container recreate | `projects/`, `var/logs/` and the users file are relocated onto the volume |

## Environment variables

Everything the stock image documents still applies; these are the additions.

| Variable | Default | Purpose |
|---|---|---|
| `RUNDECK_ADMIN_USER` | `admin` | Login for the seeded administrator |
| `RUNDECK_ADMIN_PASSWORD` | — | **Required.** The container refuses to start without it |
| `RUNDECK_ADMIN_ROLES` | `user,admin,architect,deploy,build` | Roles granted to that account |
| `RUNDECK_ADMIN_PASSWORD_ENCODING` | `bcrypt` | `bcrypt`, `md5` or `plain` |
| `RUNDECK_RAILWAY_DATA` | `/home/rundeck/railway-data` | Volume mount path |
| `RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_ENDPOINT` | — | S3-compatible endpoint, with scheme |
| `RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_ACCESSKEY` | — | Access key id |
| `RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_SECRETKEY` | — | Secret access key |
| `RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_PATHSTYLE` | `true` | Path-style addressing |
| `RUNDECK_PLUGIN_EXECUTIONFILESTORAGE_S3_PATH` | `rundeck/${job.project}/${job.execid}.log` | Object key template |
| `RUNDECK_MAIL_SMTP_HOST_DEFAULT` | `mailpit.railway.internal` | Used when the mail host reference is still empty on a first deploy |

The admin line is rewritten only when the user, roles, encoding or password
change, so extra users added to `realm.properties` by hand are preserved.

## Licence

This repository packages Rundeck Community. Rundeck is © PagerDuty and licensed
under the Apache License 2.0; clustering, autotakeover and cluster remote
execution are commercial features and are not part of this image.
