"""Run the retained NAS data-channel tests with synthetic fixtures only.
Requires Python 3.10+. The HTTP tests bind only to loopback on a random port.
"""
from pathlib import Path
import json
import os
import platform
import py_compile
import subprocess
import sys
from datetime import datetime, timezone

root = Path(__file__).resolve().parents[1]
out = root / 'docs' / 'validation'
out.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, PYTHONUTF8='1')
commands = [
    ('nas-channels', [sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py', '-v']),
]
results = []
for name, cmd in commands:
    result = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True, encoding='utf-8')
    (out / (name + '.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
    results.append({'name': name, 'exitCode': result.returncode, 'log': name + '.log'})
    print(name + ': ' + ('PASS' if result.returncode == 0 else 'FAIL'))
for name in ['server.py', 'channel_store.py', 'market_data.py', 'market_runtime.py', 'fundamentals.py', 'market_universe.py']:
    py_compile.compile(str(root / 'nas-sync-server' / name), doraise=True)
report = {
    'timestampUTC': datetime.now(timezone.utc).isoformat(),
    'platform': platform.platform(),
    'python': platform.python_version(),
    'node': subprocess.check_output(['node','--version'],text=True).strip(),
    'results': results,
    'iOSBuild': 'NOT_RUN: Xcode and Swift unavailable in current Windows environment',
    'originalSwiftPrototypeTests': 'NOT_RUN: Swift unavailable',
    'dockerBuild': 'NOT_RUN: engine not running',
    'liveMarketAndDeployedNAS': 'NOT_RUN',
    'realDataUsed': False,
}
(out/'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2),encoding='utf-8')
sys.exit(1 if any(r['exitCode'] for r in results) else 0)

