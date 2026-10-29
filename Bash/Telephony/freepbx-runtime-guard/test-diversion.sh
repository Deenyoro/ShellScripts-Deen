#!/usr/bin/env bash
# Exercise a package reinstall in an isolated dpkg root, never the live PBX.
set -euo pipefail
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
target="$stage/root"
payload="$stage/package"
mkdir -p "$target/var/lib/dpkg" "$target/var/lib/asterisk" "$payload/DEBIAN" "$payload/var/lib/asterisk"
touch "$target/var/lib/dpkg/status"
cat > "$payload/DEBIAN/control" <<'CONTROL'
Package: kc-runtime-diversion-test
Version: 1
Architecture: all
Maintainer: KC Operations <dean@kawaconnect.com>
Description: Isolated runtime database overwrite regression fixture
CONTROL
printf 'working live database\n' > "$target/var/lib/asterisk/astdb.sqlite3"
printf 'empty package database\n' > "$payload/var/lib/asterisk/astdb.sqlite3"
dpkg-deb --build "$payload" "$stage/test.deb" >/dev/null
dpkg-divert --root="$target" --local --add --no-rename \
    --divert /var/lib/asterisk/astdb.sqlite3.package-default /var/lib/asterisk/astdb.sqlite3 >/dev/null
for attempt in 1 2; do
    dpkg --root="$target" --unpack "$stage/test.deb" >/dev/null
    test "$(cat "$target/var/lib/asterisk/astdb.sqlite3")" = 'working live database'
    test "$(cat "$target/var/lib/asterisk/astdb.sqlite3.package-default")" = 'empty package database'
done
echo 'Package install and same-version reinstall preserved the live database in the isolated dpkg root'
