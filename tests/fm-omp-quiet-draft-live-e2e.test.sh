#!/usr/bin/env bash
# Credentialed OMP TUI regression: real tracked watcher, guard, quiet daemon,
# drain, multiline editing, attachment and deliberate submission. All terminal
# operations, including nested daemon lifecycle calls, use one guarded Herdr lab.
# Startup discovery is not under test: the isolated startup runner stands down;
# a test extension seeds the session lock and records public extension events.
# Evidence stays local. The generated image and all messages are synthetic.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OMP_DRAFT_LIVE omp herdr python3 jq
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name omp-quiet-draft)
LAB=$(fm_test_tmproot fm-omp-quiet-draft)
cleanup() {
  local result=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || result=1
  if [ "${FM_OMP_LIVE_KEEP:-0}" = 1 ]; then
    printf '# local OMP evidence retained at %s\n' "$LAB"
  else
    fm_test_cleanup
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
export HERDR_LAB_HELPER HERDR_LAB_SESSION LAB
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import time
import zlib

root, lab = Path(sys.argv[1]), Path(os.environ['LAB'])
home = lab / 'home'
helper, session = os.environ['HERDR_LAB_HELPER'], os.environ['HERDR_LAB_SESSION']
basepath = os.environ['PATH']

def run(*args):
    return subprocess.run([helper, 'run', session, *args], check=True, text=True, capture_output=True).stdout

def wait_for(predicate, description, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('timed out: ' + description)

for directory in ['bin', '.omp', '.pi', 'docs']:
    shutil.copytree(root / directory, home / directory)
for directory in ['state', 'config', 'data']:
    (home / directory).mkdir()
(home / 'config/backend').write_text('herdr\n')
(home / 'config/backlog-backend').write_text('manual\n')
(home / 'config/wedge-alarm').write_text('off\n')
(home / 'bin/fm-sessionstart-run.sh').write_text('#!/usr/bin/env bash\nexit 3\n')

safe = lab / 'safe-bin'
safe.mkdir()
(safe / 'herdr').write_text(f'''#!/usr/bin/env bash
set -eu
args=("$@")
n=${{#args[@]}}
if [ "$n" -lt 2 ] || [ "${{args[n-2]}}" != --session ] || [ "${{args[n-1]}}" != {shlex.quote(session)} ]; then
  printf 'refusing an unscoped Herdr call in the OMP lab\\n' >&2
  exit 2
fi
unset 'args[n-1]' 'args[n-2]'
exec env PATH={shlex.quote(basepath)} {shlex.quote(helper)} run {shlex.quote(session)} "${{args[@]}}"
''')
(safe / 'herdr').chmod(0o755)
entry = lab / 'daemon-entry'
entry.write_text(f'#!/usr/bin/env bash\nexec env FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 {shlex.quote(str(home / "bin/fm-afk-start.sh"))}\n')
entry.chmod(0o755)
probe = lab / 'probe.ts'
probe.write_text(r'''
import { appendFileSync, existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { Type } from "typebox";
export default function(pi: any) {
  const home = process.env.FM_HOME!;
  let ctx: any, timer: NodeJS.Timeout;
  const log = (event: any) => appendFileSync(`${home}/events.jsonl`, JSON.stringify(event) + "\n");
  pi.on("session_start", (_event: any, context: any) => {
    ctx = context;
    writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
    timer = setInterval(() => {
      if (!existsSync(`${home}/request.json`)) return;
      const request = JSON.parse(readFileSync(`${home}/request.json`, "utf8"));
      unlinkSync(`${home}/request.json`);
      if (request.kind === "snapshot") {
        log({kind: "snapshot", id: request.id, draft: ctx.ui.getEditorText()});
        return;
      }
      const env = {...process.env};
      delete env.FM_AFK_MODE;
      if (request.kind === "heartbeat") {
        const result = spawnSync("bash", ["-c", '. "$1/bin/fm-wake-lib.sh"; fm_wake_append heartbeat heartbeat heartbeat', "probe", home], {env, encoding: "utf8"});
        log({kind: "control", id: request.id, code: result.status, stdout: result.stdout, stderr: result.stderr});
        return;
      }
      if (request.kind === "quiet") env.FM_AFK_MODE = "quiet";
      const result = spawnSync("bash", [home + "/bin/fm-afk-launch.sh", request.kind === "off" ? "stop" : "start"], {env, encoding: "utf8"});
      log({kind: "control", id: request.id, code: result.status, stdout: result.stdout, stderr: result.stderr});
    }, 100);
    writeFileSync(`${home}/ready`, String(process.pid));
  });
  pi.on("message_start", (event: any) => {
    const message = event.message;
    const blocks = Array.isArray(message.content) ? message.content : [];
    log({kind: "message", role: message.role,
      text: typeof message.content === "string" ? message.content : blocks.filter((b: any) => b.type === "text").map((b: any) => b.text).join("\n"),
      images: blocks.filter((b: any) => b.type === "image").length, draft: ctx.ui.getEditorText()});
  });
  pi.on("agent_end", () => setTimeout(() => log({kind: "settled", draft: ctx.ui.getEditorText()}), 50));
  pi.registerTool({name: "fm_lab_drain", description: "Handle the synthetic event by draining and acknowledging this isolated home.", parameters: Type.Object({}), execute: async () => {
    const script = home + "/bin/fm-wake-drain.sh";
    const result = spawnSync("bash", [script], {encoding: "utf8", env: process.env});
    if (result.status !== 0) throw new Error(result.stderr);
    const ack = result.stderr.match(/WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)/);
    if (ack) {
      const acknowledged = spawnSync("bash", [script, "--ack-through", ack[1], "--recovery-generation", ack[2]], {encoding: "utf8", env: process.env});
      if (acknowledged.status !== 0) throw new Error(acknowledged.stderr);
    }
    log({kind: "drain", draft: ctx.ui.getEditorText()});
    return {content: [{type: "text", text: "Synthetic event handled."}]};
  }});
  pi.on("session_shutdown", () => clearInterval(timer));
}
''')
workspace = json.loads(run('workspace', 'create', '--cwd', str(home), '--label', 'omp-quiet-draft', '--no-focus'))
pane = workspace['result']['root_pane']['pane_id']
command = ['env', '-u', 'FM_STATE_OVERRIDE', '-u', 'FM_DATA_OVERRIDE', '-u', 'FM_CONFIG_OVERRIDE', '-u', 'FM_TASK_ID',
           f'PATH={safe}:{basepath}', f'FM_HOME={home}', f'FM_ROOT_OVERRIDE={home}', f'FM_AFK_LAUNCH_ENTRY={entry}',
           'FM_OMP_HARNESS=omp', 'OMP_SKIP_SETUP=1', 'FM_POLL=1', 'FM_SIGNAL_GRACE=0', 'FM_HEARTBEAT=3600',
           'omp', '--cwd', str(home), '--no-extensions', '--no-rules', '--no-skills', '--no-session', '--no-title', '--no-lsp',
           '--tools', 'read', '--config', str(home / '.omp/fm-worker-overlay.yml'), '-e', str(probe),
           '-e', str(home / '.omp/extensions/fm-primary-omp-watch.ts'), '-e', str(home / '.omp/extensions/fm-primary-turnend-guard.ts'),
           '--model', os.environ.get('FM_OMP_LIVE_MODEL', 'openai-codex/gpt-6-astra'), '--thinking', 'low', '--auto-approve',
           '--system-prompt', 'This is a synthetic isolated regression. On EVERY turn, call fm_lab_drain exactly once, then reply HANDLED. If needed, read xd://fm_lab_drain and write {} to that device to call the registered tool. Never skip the tool, even for an image or ordinary text. Do not perform fleet operations.']
run('pane', 'run', pane, 'exec ' + shlex.join(command))
wait_for(lambda: (home / 'ready').exists(), 'OMP extension startup')
print('OMP_TUI_READY', flush=True)

serial = 0

def events(kind=None):
    if not (home / 'events.jsonl').exists():
        return []
    records = [json.loads(line) for line in (home / 'events.jsonl').read_text().splitlines()]
    return records if kind is None else [record for record in records if record['kind'] == kind]

def request(kind):
    global serial
    serial += 1
    temporary = home / 'request.tmp'
    temporary.write_text(json.dumps({'kind': kind, 'id': serial}))
    temporary.replace(home / 'request.json')
    result = wait_for(lambda: next((event for event in events() if event.get('id') == serial), None), kind)
    if kind != 'snapshot':
        assert result['code'] == 0, result
    return result

def draft():
    return request('snapshot')['draft']

def send(text):
    run('pane', 'send-text', pane, text)

def keys(*names):
    run('pane', 'send-keys', pane, *names)

def watch_processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,args='], text=True).splitlines()
    candidates = {int(parts[0]): int(parts[1]) for row in rows if len(parts := row.split()) > 3 and str(home / 'bin/fm-watch.sh') in parts[2:]}
    processes = [(pid, parent) for pid, parent in candidates.items() if parent not in candidates]
    assert len(processes) <= 1, 'competing monitors in the same home'
    return processes

def event_cycle(name, edit=''):
    previous = len(events('settled'))
    previous_drains = len(events('drain'))
    (home / f'state/{name}.status').write_text(f'blocked: synthetic {name} action\n')
    wait_for(lambda: any(name in event['text'] for event in events('message') if event['role'] == 'custom'), 'native actionable delivery')
    if edit:
        send(edit)
    wait_for(lambda: len(events('drain')) > previous_drains and len(events('settled')) > previous, 'handled event')
    return draft()

request('quiet')
wait_for(lambda: (home / 'state/.supervise-daemon.lock/pid').exists(), 'quiet daemon')
daemon = (home / 'state/.supervise-daemon.lock/pid').read_text()
wait_for(lambda: len(watch_processes()) == 1, 'singleton monitor')
assert watch_processes()[0][1] != int(daemon), 'daemon started a competing raw watcher'
request('refresh')
assert (home / 'state/.supervise-daemon.lock/pid').read_text() == daemon, 'quiet refresh restarted daemon'
assert (home / 'state/.afk').read_text().splitlines()[0] == 'quiet'
assert not (home / 'state/.afk-contract').exists(), 'quiet invented an away mandate'

image = lab / 'synthetic.png'
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
image.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00')) + chunk(b'IEND', b''))
send('\x1b[200~' + str(image) + '\x1b[201~')
wait_for(lambda: draft(), 'image attachment in composer')
keys('shift+enter')
send('draft alpha')
keys('shift+enter')
send('draft omega')
keys('left', 'left', 'left')
original = draft()
assert original.endswith('draft omega'), original
before = len(events('message'))
(home / 'state/routine.status').write_text('working: synthetic routine progress\n')
request('heartbeat')
wait_for(lambda: not (home / 'state/.wake-queue').exists() or not (home / 'state/.wake-queue').read_text(), 'routine classification')
time.sleep(3)
assert len(events('message')) == before, 'routine quiet event reached the model'
assert draft() == original
wait_for(lambda: len(watch_processes()) == 1, 'quiet successor monitor')

assert event_cycle('approval', 'X') == original[:-3] + 'X' + original[-3:], 'delivery overwrote an in-flight edit'
expected = draft()
assert event_cycle('failure') == expected, 'second event changed the draft'
settled = len(events('settled'))
keys('enter')
wait_for(lambda: len([event for event in events('message') if event['role'] == 'user']) == 1, 'deliberate submission')
user = [event for event in events('message') if event['role'] == 'user'][0]
assert 'draft alpha\ndraft omXega' in user['text'] and user['images'] == 1, user
wait_for(lambda: draft() == '', 'submitted draft cleared')
wait_for(lambda: len(events('settled')) > settled, 'quiet ordinary reply completed')
assert (home / 'state/.afk').read_text().splitlines()[0] == 'quiet', 'ordinary chat exited quiet mode'
request('off')
assert not (home / 'state/.afk').exists()
wait_for(lambda: len(watch_processes()) == 1, 'attended monitor after quiet exit')
send('ordinary draft')
assert event_cycle('attended') == 'ordinary draft', 'attended wake cleared composer'
settled = len(events('settled'))
keys('enter')
wait_for(lambda: len([event for event in events('message') if event['role'] == 'user']) == 2, 'second deliberate submission')
wait_for(lambda: draft() == '', 'second submitted draft cleared')
wait_for(lambda: len(events('settled')) > settled, 'attended ordinary reply completed')
(home / 'visible.txt').write_text(run('pane', 'read', pane, '--source', 'visible'))
print('ok - real OMP: quiet entry/refresh/chat/exit, one monitor, actionable delivery, and ordinary wakes')
print('ok - real OMP: multiline draft, cursor edit during delivery, repeated events, image attachment, and exactly-once submission')
PY
