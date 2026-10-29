"""Add runtime verification to the existing connector's health response."""
from pathlib import Path

path = Path('/opt/kc-pbx/kc_pbx.py')
source = path.read_text()
old = '''        if self.path == "/health":
            self._reply(200, {"ok": True, "time": datetime.now(TZ).isoformat()})
            return
'''
new = '''        if self.path == "/health":
            from runtime_health import runtime_health
            runtime = runtime_health()
            self._reply(200 if runtime["ok"] else 503, {
                "ok": runtime["ok"], "time": datetime.now(TZ).isoformat(), "runtime": runtime,
            })
            return
'''
if new not in source:
    if source.count(old) != 1:
        raise SystemExit('Connector health implementation changed; review before patching')
    source = source.replace(old, new, 1)
    compile(source, str(path), 'exec')
    path.write_text(source)
print('Connector health patch verified')
