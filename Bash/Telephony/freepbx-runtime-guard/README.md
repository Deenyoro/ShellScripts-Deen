# FreePBX runtime database protection

Installed on `freepbx104` after the October 23, 2026 `freepbx17` package reinstall
replaced `/var/lib/asterisk/astdb.sqlite3` with its packaged seed database. SQL
extension configuration and SIP registrations survived, but missing `AMPUSER`
and `DEVICE` mappings made ring group 600 return SIP 480 immediately.

Run `bash install.sh` as root on the PBX. It backs up configuration, installs a
local dpkg diversion without moving the live database, installs the watchdog and
backup timers, and patches the existing connector health handler. Restart
`kc-pbx.service` only when the alert dispatcher is idle to load the health patch.
No Asterisk restart is required. The installer refuses unknown health code or a
conflicting diversion. It does not change RingCentral routing or ring groups.

The one-minute watchdog reads saved SQL configuration through FreePBX and checks
the live mappings through its AMI library. It restores absent user metadata and
fixed-device mappings, preserving existing preferences and extra associations.
Conflicting dial strings are reported unhealthy instead of overwritten. Dynamic
hot-desk device assignments are not reconstructed from SQL defaults. Status and
logs contain key names and counts, never credentials or stored values.

The connector `/health` returns 503 for missing, failed, or stale watchdog
results, including missing package protection. A healthy HTTP process alone no
longer counts as a working PBX. Add this endpoint to the existing monitoring
system. It is monitored on the installed host by Uptime Kuma under KawaConnect
(FreePBX - runtime routing health), using the existing email and Discord alert
channels. Other connector endpoints and alert timing are unchanged.

Backups run daily and before APT package operations. Root-only snapshots under
`/var/backups/kc-pbx/daily` contain an online SQLite backup, SQL configuration,
Asterisk files, the connector, and diversion records. Daily snapshots retain
14 days. `COMPLETE` marks a successful snapshot. Initial incident backups are
outside this retention directory. An APT backup failure is logged and does not
block security updates.

Verification commands:

```sh
php test-runtime.php
python3 test-health.py
bash test-diversion.sh
systemctl status kc-pbx-runtime.timer kc-pbx-backup.timer
php /usr/local/lib/kc-pbx-runtime/runtime-guard.php --check
curl --fail http://127.0.0.1:8095/health
```

`test-diversion.sh` installs and reinstalls a tiny fixture package in an isolated
dpkg root to reproduce the overwrite scenario without touching production.
Runtime tests inject missing entries and failed writes and verify that checks
are read-only, repairs are idempotent, and existing settings survive.
GitLab runs these regression tests when this directory changes.

To remove the guard, disable both timers and remove its APT hook and health
patch first. Keep the diversion unless the upstream package no longer ships the
database. Removing it makes future package reinstalls destructive again. Never
copy a seed database over the active database or restore a stale live SQLite
file while Asterisk has it open.
