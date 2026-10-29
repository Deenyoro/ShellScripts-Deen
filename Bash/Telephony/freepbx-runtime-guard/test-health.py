import json
import tempfile
import unittest
from pathlib import Path

from runtime_health import runtime_health


class RuntimeHealthTest(unittest.TestCase):
    def test_health_fails_when_missing_stale_or_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'status.json'
            self.assertFalse(runtime_health(path, now=1000)['ok'])
            for value in ['not json', '{}', '{"checked_at":"bad"}']:
                path.write_text(value)
                self.assertFalse(runtime_health(path, now=1000)['ok'])
            for checked_at in [100, 1001]:
                path.write_text(json.dumps({'ok': True, 'package_protected': True, 'checked_at': checked_at}))
                self.assertFalse(runtime_health(path, now=1000)['ok'])

    def test_exposes_only_health_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'status.json'
            for protected in [False, True]:
                path.write_text(json.dumps({'ok': True, 'checked_at': 990, 'package_protected': protected,
                                            'private_value': 'not-for-http', 'missing_keys': ['secret-name']}))
                result = runtime_health(path, now=1000)
                self.assertEqual(result['ok'], protected)
                self.assertNotIn('not-for-http', json.dumps(result))
                self.assertNotIn('secret-name', json.dumps(result))


if __name__ == '__main__':
    unittest.main()
