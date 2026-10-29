"""Read the watchdog result without putting SQL/AMI credentials in HTTP handlers."""

import json
import time
from pathlib import Path


def runtime_health(path="/var/lib/kc-pbx-runtime/status.json", now=None):
    now = time.time() if now is None else now
    try:
        status = json.loads(Path(path).read_text())
        age = now - float(status["checked_at"])
        healthy = (status.get("ok") is True
                   and status.get("package_protected") is True and 0 <= age <= 180)
        return {
            "ok": healthy,
            "fresh": 0 <= age <= 180,
            "package_protected": status.get("package_protected") is True,
            "missing_count": status.get("missing_count"),
            "mismatched_count": status.get("mismatched_count"),
        }
    except (OSError, ValueError, KeyError, TypeError):
        return {"ok": False, "fresh": False, "package_protected": False}
