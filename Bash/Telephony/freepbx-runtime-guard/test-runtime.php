<?php
declare(strict_types=1);
require __DIR__ . '/runtime-guard.php';

function check(bool $condition, string $label): void {
    if (!$condition) { throw new RuntimeException($label); }
}
$users = [['extension' => '201', 'name' => 'Test User', 'ringtimer' => '0', 'password' => 'private-test-value']];
$devices = [['id' => '201', 'dial' => 'PJSIP/201', 'tech' => 'pjsip', 'devicetype' => 'fixed', 'user' => '201']];
$expected = kc_expected_runtime($users, $devices);
$runtime = ['AMPUSER/201/device' => '999', 'AMPUSER/201/ringtimer' => '60', 'CF/201' => 'preserve-forward'];
$get = static function ($key) use (&$runtime) { return $runtime[$key] ?? false; };
$put = static function ($key, $value) use (&$runtime) { $runtime[$key] = $value; return true; };
$before = $runtime;
$result = kc_reconcile_runtime($expected, $get, $put, false);
check(count($result['missing']) > 0 && $runtime === $before, 'Read-only checks must not write');
kc_reconcile_runtime($expected, $get, $put, true);
check($runtime['DEVICE/201/dial'] === 'PJSIP/201', 'Missing device route must be restored');
check($runtime['AMPUSER/201/device'] === '999&201', 'Existing device associations must be preserved');
check($runtime['AMPUSER/201/ringtimer'] === '60', 'Existing preferences must be preserved');
check($runtime['CF/201'] === 'preserve-forward', 'Forwarding state must be preserved');
check(kc_reconcile_runtime($expected, $get, $put, false)['missing'] === [], 'Repair must verify cleanly');
$stable = $runtime;
check(kc_reconcile_runtime($expected, $get, $put, true)['repaired'] === [] && $runtime === $stable, 'Repair must be idempotent');
$runtime['DEVICE/201/dial'] = 'PJSIP/other-device';
$result = kc_reconcile_runtime($expected, $get, $put, true);
check(in_array('DEVICE/201/dial', $result['mismatched'], true), 'Conflicting routes must report failure');
check($runtime['DEVICE/201/dial'] === 'PJSIP/other-device', 'Conflicting routes must not be overwritten');
unset($runtime['DEVICE/201/dial']);
kc_reconcile_runtime($expected, $get, static fn() => false, true);
check(in_array('DEVICE/201/dial', kc_reconcile_runtime($expected, $get, $put, false)['missing'], true), 'Failed writes must stay unhealthy');
$dynamic = $devices; $dynamic[0]['devicetype'] = 'adhoc';
check(!isset(kc_expected_runtime($users, $dynamic)['DEVICE/201/dial']), 'Dynamic assignments must not be reconstructed from SQL defaults');
try { kc_expected_runtime([], $devices); throw new LogicException('Empty configuration was accepted'); }
catch (RuntimeException $error) { check($error->getMessage() === 'Saved users or devices are empty', 'Empty configuration must fail safely'); }
echo "Runtime recovery tests passed: missing mappings, preservation, idempotence, conflicts, and failed writes\n";
