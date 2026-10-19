#!/usr/bin/env python3
"""隔离模拟器运行取证；实际结果保留，失败不改写成通过。"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--simulator', required=True)
p.add_argument('--bundle', choices=['com.offline.tool.managed.sample', 'com.offline.tool.managed.consumer'], required=True)
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--run-id', required=True)
p.add_argument('--storage-id', required=True)
p.add_argument('--port', type=int, default=18765)
p.add_argument('--wait', type=float, default=60)
p.add_argument('--settle', type=float, default=3, help='完成后的真实观察时长')
p.add_argument('--version', choices=['A', 'B'])
p.add_argument('--failure', action='store_true')
p.add_argument('--wrong-sha', action='store_true')
p.add_argument('--long-cadence', action='store_true')
p.add_argument('--startup-only', action='store_true')
p.add_argument('--cancel-reenter', action='store_true')
p.add_argument('--web-fault-probes', action='store_true')
p.add_argument('--redirect-css-probe', action='store_true')
p.add_argument('--checking-action', choices=['privacy', 'close'])
p.add_argument('--privacy-deferred', action='store_true')
p.add_argument('--finish-deferred', action='store_true')
p.add_argument('--background-configuration', choices=['disabled', 'B'], help='第二次真实 provider 在途切普通后台，再恢复同一进程')
a = p.parse_args()
if not re.fullmatch(r'[a-zA-Z0-9-]+', a.run_id):
    p.error('run-id must contain only letters, digits and hyphens')
evidence = a.evidence.resolve()
evidence.mkdir(parents=True, exist_ok=True)
prefix = evidence / a.run_id
if prefix.with_suffix('.commands.json').exists():
    p.error('run evidence already exists')
env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
commands = []
def run(args, check=True):
    started = time.time()
    result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    commands.append(dict(argv=args, start_unix=started, end_unix=time.time(), exit=result.returncode, output=result.stdout))
    prefix.with_suffix('.commands.json').write_text(json.dumps(commands, indent=2))
    if check and result.returncode:
        raise SystemExit(result.stdout)
    return result
if a.version:
    body = json.dumps(dict(version=a.version, disabled=False, failure=a.failure, wrongSHA=a.wrong_sha, configDelay=0)).encode()
    request = urllib.request.Request('http://127.0.0.1:' + str(a.port) + '/control', data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=10) as response:
        prefix.with_suffix('.control.json').write_bytes(response.read())
run(['xcrun', 'simctl', 'terminate', a.simulator, a.bundle], check=False)
flags = ['--managed-smoke', '--server-port', str(a.port), '--storage-id', a.storage_id, '--run-id', a.run_id]
if a.long_cadence: flags += ['--long-cadence']
if a.startup_only: flags += ['--startup-only']
if a.cancel_reenter: flags += ['--cancel-after-progress', '--auto-reenter-after-cancel']
if a.web_fault_probes: flags += ['--web-fault-probes']
if a.redirect_css_probe: flags += ['--redirect-css-probe']
if a.checking_action: flags += ['--checking-action', a.checking_action]
if a.privacy_deferred: flags += ['--privacy-deferred']
if a.finish_deferred: flags += ['--finish-deferred']
if a.background_configuration: flags += ['--background-configuration', a.background_configuration]
launch = run(['xcrun', 'simctl', 'launch', '--stdout=' + str(prefix.with_suffix('.stdout.log')), '--stderr=' + str(prefix.with_suffix('.stderr.log')), a.simulator, a.bundle] + flags)
match = re.search(r': (\d+)\s*$', launch.stdout)
pid = match.group(1) if match else None
container = Path(run(['xcrun', 'simctl', 'get_app_container', a.simulator, a.bundle, 'data']).stdout.strip())
result_path = container / 'Documents' / ('managed-result-' + a.run_id + '.json')
started = time.monotonic()
first_screenshot = False
memory = []
snapshot = None
finished_at = None
background_started = None
foreground_resumed = False
resumed_pid = None
while time.monotonic() - started < a.wait:
    try:
        snapshot = json.loads(result_path.read_text())
    except (OSError, ValueError):
        snapshot = None
    if snapshot:
        if a.background_configuration:
            starts = [x for x in snapshot['events'] if x['event'] == 'provider-start']
            if len(starts) >= 2 and background_started is None:
                # 只打开系统 Safari 空白上下文，使隔离消费者接收真实 UIApplication 后台事件。
                run(['xcrun', 'simctl', 'launch', a.simulator, 'com.apple.mobilesafari'])
                background_started = time.monotonic()
            if background_started is not None and not foreground_resumed and time.monotonic() - background_started >= 5:
                resume = run(['xcrun', 'simctl', 'launch', a.simulator, a.bundle])
                resumed_match = re.search(r': (\d+)\s*$', resume.stdout)
                resumed_pid = int(resumed_match.group(1)) if resumed_match else None
                foreground_resumed = True
        progress = [x for x in snapshot['events'] if x['event'] == 'first-progress' and x['stage'] == 'download' and x['completed'] > 0]
        if progress and not first_screenshot:
            run(['xcrun', 'simctl', 'io', a.simulator, 'screenshot', str(prefix.with_suffix('.first.png'))])
            first_screenshot = True
        if snapshot.get('finished') and finished_at is None:
            finished_at = time.monotonic()
        if finished_at is not None and time.monotonic() - finished_at >= a.settle:
            break
    if pid:
        rss = subprocess.run(['ps', '-o', 'rss=', '-p', pid], stdout=subprocess.PIPE, text=True).stdout.strip()
        if rss.isdigit(): memory.append(dict(elapsed=time.monotonic() - started, rss_kib=int(rss)))
    time.sleep(0.5)
if result_path.exists(): shutil.copyfile(result_path, prefix.with_suffix('.result.json'))
run(['xcrun', 'simctl', 'io', a.simulator, 'screenshot', str(prefix.with_suffix('.final.png'))])
summary = dict(bundle=a.bundle, simulator=a.simulator, pid=int(pid) if pid else None, flags=flags,
    wall_seconds=time.monotonic() - started, finished=bool(snapshot and snapshot.get('finished')),
    result_sha256=hashlib.sha256(result_path.read_bytes()).hexdigest() if result_path.exists() else None,
    host_app_peak_rss_kib=max([x['rss_kib'] for x in memory], default=None),
    memory_scope='host app process only; excludes WebKit child processes', memory_samples=memory,
    background_configuration=a.background_configuration, resumed_pid=resumed_pid,
    resumed_same_process=bool(pid and resumed_pid == int(pid)) if a.background_configuration else None)
prefix.with_suffix('.summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps({k:v for k,v in summary.items() if k != 'memory_samples'}), flush=True)
raise SystemExit(0 if summary['finished'] else 2)
