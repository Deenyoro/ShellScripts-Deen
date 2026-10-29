#!/usr/bin/env bash
set -euo pipefail
umask 077
root=/var/backups/kc-pbx/daily
mkdir -p "$root"
target="$root/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$target"
python3 - "$target/astdb.sqlite3" <<'PY'
import sqlite3
import sys
source = sqlite3.connect('file:/var/lib/asterisk/astdb.sqlite3?mode=ro', uri=True)
destination = sqlite3.connect(sys.argv[1])
source.backup(destination)
destination.close()
source.close()
PY
mysqldump --single-transaction asterisk > "$target/asterisk.sql"
tar -czf "$target/asterisk-config.tgz" -C /etc asterisk
cp -a /opt/kc-pbx "$target/connector"
cp /var/lib/dpkg/diversions "$target/dpkg-diversions"
touch "$target/COMPLETE"
find "$root" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -mtime +14 -exec rm -rf -- {} +
echo "FreePBX backup saved: $target"
