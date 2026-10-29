#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
test "$(id -u)" = 0 || { echo 'Run as root on the FreePBX host' >&2; exit 1; }
php -l runtime-guard.php
php test-runtime.php
python3 test-health.py
install -d -m 755 /usr/local/lib/kc-pbx-runtime /var/lib/kc-pbx-runtime
install -m 644 runtime-guard.php /usr/local/lib/kc-pbx-runtime/runtime-guard.php
install -m 755 backup.sh /usr/local/lib/kc-pbx-runtime/backup.sh
/usr/local/lib/kc-pbx-runtime/backup.sh
target=$(dpkg-divert --truename /var/lib/asterisk/astdb.sqlite3)
if [ "$target" = /var/lib/asterisk/astdb.sqlite3 ]; then
    dpkg-divert --local --add --no-rename \
      --divert /var/lib/asterisk/astdb.sqlite3.package-default /var/lib/asterisk/astdb.sqlite3
elif [ "$target" != /var/lib/asterisk/astdb.sqlite3.package-default ]; then
    echo 'An unexpected AstDB diversion exists; review before changing it' >&2
    exit 1
fi
install -m 644 runtime_health.py /opt/kc-pbx/runtime_health.py
python3 patch-health.py
install -m 644 kc-pbx-runtime.service kc-pbx-runtime.timer kc-pbx-backup.service kc-pbx-backup.timer /etc/systemd/system/
install -m 644 99-kc-pbx-backup /etc/apt/apt.conf.d/99-kc-pbx-backup
systemd-analyze verify /etc/systemd/system/kc-pbx-runtime.service /etc/systemd/system/kc-pbx-runtime.timer /etc/systemd/system/kc-pbx-backup.service /etc/systemd/system/kc-pbx-backup.timer
systemctl daemon-reload
systemctl start kc-pbx-runtime.service
systemctl enable --now kc-pbx-runtime.timer kc-pbx-backup.timer
echo 'Guard and backups installed. Restart kc-pbx when its alert dispatcher is idle to load the health patch.'
