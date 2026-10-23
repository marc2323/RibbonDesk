#!/bin/zsh
set -euo pipefail
project="${0:A:h}"
workspace="${project:h}"
zsh "$workspace/PaneruEngine/build.sh"
zsh "$project/build.sh"
python3 - <<'PY'
from pathlib import Path
import os, signal, subprocess, time

app = Path.home() / 'Applications/RibbonDesk.app'
legacy = Path.home() / 'Applications/Paneru Settings.app'
executables = [str(app / 'Contents/MacOS/RibbonDesk'), str(legacy / 'Contents/MacOS/PaneruSettings')]
service = f'gui/{os.getuid()}/com.github.karinushka.paneru'
# Stop the companion first so its Desktop policy cannot restart the engine
# while the installer is waiting for the old engine to exit.
companions = []
for line in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
    parts = line.strip().split(maxsplit=1)
    if len(parts) == 2 and any(parts[1] in (executable, executable + ' --background') for executable in executables):
        companions.append(int(parts[0]))
        os.kill(int(parts[0]), signal.SIGTERM)
for _ in range(30):
    alive = []
    for pid in companions:
        try: os.kill(pid, 0); alive.append(pid)
        except ProcessLookupError: pass
    if not alive: break
    time.sleep(0.1)
else: raise SystemExit('RibbonDesk is still stopping; installation did not replace it.')
status = subprocess.run(['launchctl', 'print', service], capture_output=True, text=True)
if 'state = running' in status.stdout:
    engine = app / 'Contents/MacOS/paneru'
    if not engine.exists(): engine = legacy / 'Contents/MacOS/paneru'
    if not engine.exists(): engine = Path('/opt/homebrew/bin/paneru')
    subprocess.run([str(engine), 'send-cmd', 'quit'], timeout=8, check=True)
    for _ in range(50):
        status = subprocess.run(['launchctl', 'print', service], capture_output=True, text=True)
        if 'state = running' not in status.stdout: break
        time.sleep(0.1)
    else: raise SystemExit('The window engine is still stopping; installation did not replace it.')
subprocess.run(['launchctl', 'bootout', service], capture_output=True)
PY
zsh "$project/Scripts/install-app.sh" "$workspace/.build/paneru-preferences/RibbonDesk.app" "$project/paneru-init.lua"
