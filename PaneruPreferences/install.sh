#!/bin/zsh
set -euo pipefail
project="${0:A:h}"
workspace="${project:h}"
zsh "$workspace/PaneruEngine/build.sh"
zsh "$project/build.sh"
python3 - "$project" <<'PY'
from pathlib import Path
from datetime import datetime
import os, shutil, signal, subprocess, sys, time

project = Path(sys.argv[1])
app = Path.home() / 'Applications/Paneru Settings.app'
executable = str(app / 'Contents/MacOS/PaneruSettings')
service = f'gui/{os.getuid()}/com.github.karinushka.paneru'
# Stop the companion first so its Desktop policy cannot restart the engine
# while the installer is waiting for the old engine to exit.
companions = []
for line in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
    parts = line.strip().split(maxsplit=1)
    if len(parts) == 2 and parts[1] in (executable, executable + ' --background'):
        companions.append(int(parts[0]))
        os.kill(int(parts[0]), signal.SIGTERM)
for _ in range(30):
    alive = []
    for pid in companions:
        try: os.kill(pid, 0); alive.append(pid)
        except ProcessLookupError: pass
    if not alive: break
    time.sleep(0.1)
else: raise SystemExit('Paneru Settings is still stopping; installation did not replace it.')
status = subprocess.run(['launchctl', 'print', service], capture_output=True, text=True)
if 'state = running' in status.stdout:
    engine = app / 'Contents/MacOS/paneru'
    if not engine.exists(): engine = Path('/opt/homebrew/bin/paneru')
    subprocess.run([str(engine), 'send-cmd', 'quit'], timeout=8, check=True)
    for _ in range(50):
        status = subprocess.run(['launchctl', 'print', service], capture_output=True, text=True)
        if 'state = running' not in status.stdout: break
        time.sleep(0.1)
    else: raise SystemExit('Paneru is still stopping; installation did not replace it.')
subprocess.run(['launchctl', 'bootout', service], capture_output=True)
config = Path.home() / '.config/paneru'
backup = config / 'backups' / ('install-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
backup.mkdir(parents=True)
for name in ['init.lua', 'preferences.json', 'preferences.lua']:
    if (config / name).exists(): shutil.copy2(config / name, backup / name)
shutil.copy2(project / 'paneru-init.lua', config / 'init.lua')
app.parent.mkdir(exist_ok=True)
subprocess.run(['ditto', str(project.parent / '.build/paneru-preferences/Paneru Settings.app'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
print('Installed:', app)
print('Previous config:', backup)
PY
print -r -- 'Open Paneru Settings to start the engine and menu-bar app.'
