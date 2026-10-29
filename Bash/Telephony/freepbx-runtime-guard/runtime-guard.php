<?php
declare(strict_types=1);

// Only absent values are restored. Existing user preferences are left alone.
function kc_expected_runtime(array $users, array $devices): array
{
    if (!$users || !$devices) {
        throw new RuntimeException('Saved users or devices are empty');
    }
    $expected = [];
    $knownUsers = [];
    foreach ($users as $user) {
        $id = (string)$user['extension'];
        if (!preg_match('/^[A-Za-z0-9_.-]+$/D', $id)) {
            throw new RuntimeException('Unsupported extension identifier');
        }
        $knownUsers[$id] = true;
        foreach (['password', 'ringtimer', 'noanswer', 'recording', 'outboundcid', 'voicemail'] as $field) {
            $expected["AMPUSER/$id/$field"] = ['value' => (string)($user[$field] ?? '')];
        }
        $expected["AMPUSER/$id/cidname"] = ['value' => (string)$user['name']];
        $expected["AMPUSER/$id/cidnum"] = ['value' => $id];
    }
    foreach ($devices as $device) {
        // Hot-desk device assignments are runtime state, not fixed SQL mappings.
        if ($device['devicetype'] !== 'fixed') {
            continue;
        }
        $id = (string)$device['id'];
        $user = (string)$device['user'];
        if (!preg_match('/^[A-Za-z0-9_.-]+$/D', $id) || ($user !== 'none' && !isset($knownUsers[$user]))) {
            throw new RuntimeException('Invalid fixed device assignment');
        }
        foreach (['dial' => 'dial', 'type' => 'devicetype', 'user' => 'user', 'default_user' => 'user', 'tech' => 'tech'] as $field => $column) {
            $expected["DEVICE/$id/$field"] = [
                'value' => (string)$device[$column],
                'strict' => in_array($field, ['dial', 'type', 'tech'], true),
            ];
        }
        if (!empty($device['emergency_cid'])) {
            $expected["DEVICE/$id/emergency_cid"] = ['value' => (string)$device['emergency_cid']];
        }
        if ($user !== 'none') {
            $key = "AMPUSER/$user/device";
            $expected[$key]['members'][] = $id;
        }
    }
    return $expected;
}

function kc_reconcile_runtime(array $expected, callable $get, callable $put, bool $repair): array
{
    $missing = [];
    $mismatched = [];
    $repaired = [];
    foreach ($expected as $key => $spec) {
        $actual = $get($key);
        $replacement = null;
        if (isset($spec['members'])) {
            $members = ($actual === false || $actual === '') ? [] : explode('&', (string)$actual);
            $absent = array_diff($spec['members'], $members);
            if ($absent) {
                $replacement = implode('&', array_unique(array_merge($members, $absent)));
            }
        } elseif ($actual === false) {
            $replacement = $spec['value'];
        } elseif (($spec['strict'] ?? false) && (string)$actual !== $spec['value']) {
            $mismatched[] = $key;
        }
        if ($replacement !== null) {
            $missing[] = $key;
            if ($repair && $put($key, $replacement)) {
                $repaired[] = $key;
            }
        }
    }
    return ['missing' => $missing, 'mismatched' => $mismatched, 'repaired' => $repaired];
}

function kc_runtime_main(): int
{
    $options = getopt('', ['repair', 'check', 'status-path:']);
    $path = $options['status-path'] ?? '/var/lib/kc-pbx-runtime/status.json';
    $lock = fopen('/run/lock/kc-pbx-runtime.lock', 'c');
    if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) {
        return 0;
    }
    $status = ['ok' => false, 'checked_at' => time(), 'repaired_count' => 0];
    try {
        $fpbx = FreePBX::Create();
        $ami = $fpbx->astman;
        if (!$ami->connected()) {
            throw new RuntimeException('Asterisk management connection is unavailable');
        }
        $ami->useCaching = false;
        $users = $fpbx->Database->query('SELECT extension,name,password,ringtimer,noanswer,recording,outboundcid,voicemail FROM users')->fetchAll(PDO::FETCH_ASSOC);
        $devices = $fpbx->Database->query('SELECT id,tech,dial,devicetype,user,emergency_cid FROM devices')->fetchAll(PDO::FETCH_ASSOC);
        $expected = kc_expected_runtime($users, $devices);
        $get = static function (string $key) use ($ami) {
            [$family, $entry] = explode('/', $key, 2);
            return $ami->database_get($family, $entry);
        };
        $put = static function (string $key, string $value) use ($ami): bool {
            [$family, $entry] = explode('/', $key, 2);
            return $ami->database_put($family, $entry, $value);
        };
        $result = kc_reconcile_runtime($expected, $get, $put, isset($options['repair']));
        $verified = kc_reconcile_runtime($expected, $get, $put, false);
        $target = trim((string)shell_exec('/usr/bin/dpkg-divert --truename /var/lib/asterisk/astdb.sqlite3'));
        $status += [
            'package_protected' => $target === '/var/lib/asterisk/astdb.sqlite3.package-default',
            'missing_count' => count($verified['missing']),
            'mismatched_count' => count($verified['mismatched']),
            'missing_keys' => $verified['missing'],
            'mismatched_keys' => $verified['mismatched'],
        ];
        $status['repaired_count'] = count($result['repaired']);
        $status['ok'] = $status['package_protected'] && !$verified['missing'] && !$verified['mismatched'];
    } catch (Throwable $error) {
        // Exception payloads can contain connection details; never publish them.
        $safeErrors = ['Saved users or devices are empty', 'Unsupported extension identifier',
            'Invalid fixed device assignment', 'Asterisk management connection is unavailable'];
        $status['error'] = in_array($error->getMessage(), $safeErrors, true)
            ? $error->getMessage() : 'Runtime verification failed';
    }
    $json = json_encode($status, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES) . "\n";
    if (!is_dir(dirname($path))) {
        mkdir(dirname($path), 0755, true);
    }
    $temporary = tempnam(dirname($path), '.status-');
    file_put_contents($temporary, $json);
    chmod($temporary, 0644);
    rename($temporary, $path);
    echo $json;
    return $status['ok'] ? 0 : 1;
}

if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
    // FreePBX's bootstrap exports globals and must run in global scope.
    try {
        require '/etc/freepbx.conf';
    } catch (Throwable $error) {
        fwrite(STDERR, "FreePBX bootstrap failed; runtime status will expire\n");
        exit(1);
    }
    exit(kc_runtime_main());
}
