#!/usr/bin/env python3
"""Signing workflow tests with fake security/codesign backends; no keys or app launch."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CERT = b"persistent fixture certificate (not a real credential)"
OTHER_CERT = b"different fixture certificate (not a real credential)"
IDENTITY = hashlib.sha1(CERT).hexdigest().upper()
OTHER_IDENTITY = hashlib.sha1(OTHER_CERT).hexdigest().upper()
MOCK = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, plistlib, sys
args=sys.argv[1:]
state_path=pathlib.Path(os.environ["RD_SIGNING_FIXTURE_STATE"])
state=json.loads(state_path.read_text())
with pathlib.Path(os.environ["RD_SIGNING_FIXTURE_LOG"]).open("a") as log:
    log.write(json.dumps([pathlib.Path(sys.argv[0]).name]+args)+"\n")
if pathlib.Path(sys.argv[0]).name=="security":
    print("Policy: Code Signing\n  Matching identities")
    if state["available"]:
        for index, (fingerprint, _) in enumerate(state["certificates"].items()):
            print(f' {index+1}) {fingerprint} "Fixture identity"')
    print("  Valid identities only\n     0 valid identities found")
    sys.exit(0)
if "--extract-certificates" in args:
    # Native codesign treats an optional argument passed as a separate token
    # as an extra code path. Keep this mock strict to catch that regression.
    print("Separate certificate prefix is a code path, not an option argument",file=sys.stderr)
    sys.exit(1)
app=pathlib.Path(args[-1])
metadata=app/".fixture-signature.json"
if "--sign" in args:
    identity=args[args.index("--sign")+1]
    bundle=plistlib.loads((app/"Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    requirement=f'identifier "{bundle}" and anchor H"{identity}"'
    if "--requirements" in args:
        requirement=args[args.index("--requirements")+1].removeprefix("=designated => ")
    if identity=="-": requirement='cdhash H"fixtureadhoc"'
    cdhash=hashlib.sha256((app/"Contents/MacOS/Fixture").read_bytes()).hexdigest()[:40]
    metadata.write_text(json.dumps(dict(identity=identity,requirement=requirement,cdhash=cdhash)))
    sys.exit(0)
if not metadata.exists(): sys.exit(1)
data=json.loads(metadata.read_text())
if "--verify" in args:
    if state.get("fail_verify"): sys.exit(1)
    if "-R" in args:
        if state.get("fail_cross") or args[args.index("-R")+1] != "="+data["requirement"]: sys.exit(1)
    sys.exit(0)
extraction=next((argument for argument in args if argument.startswith("--extract-certificates=")),None)
if extraction:
    if data["identity"]=="-": sys.exit(0)
    pathlib.Path(extraction.split("=",1)[1]+"0").write_bytes(bytes.fromhex(state["certificates"][data["identity"]]))
elif "-r-" in args: print("designated => "+data["requirement"])
else: print("CDHash="+data["cdhash"],file=sys.stderr)
'''

def main():
    checks = 0
    with tempfile.TemporaryDirectory(prefix="RibbonDesk-signing-checks-") as temporary:
        work = Path(temporary)
        fake_bin = work / "bin"
        fake_bin.mkdir()
        for name in ("codesign", "security"):
            tool = fake_bin / name
            tool.write_text(MOCK)
            tool.chmod(0o755)
        config = work / "local settings" / "signing.plist"
        state_file = work / "state.json"
        log = work / "commands.jsonl"
        state = dict(available=False, certificates={IDENTITY: CERT.hex(), OTHER_IDENTITY: OTHER_CERT.hex()})
        def save_state(): state_file.write_text(json.dumps(state))
        save_state()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("RIBBONDESK_SIGNING_")}
        environment.update(PATH=str(fake_bin)+os.pathsep+os.environ["PATH"],
                           RIBBONDESK_SIGNING_CONFIG=str(config), RD_SIGNING_FIXTURE_STATE=str(state_file),
                           RD_SIGNING_FIXTURE_LOG=str(log))
        def run(script, *arguments, success=True):
            nonlocal checks
            result = subprocess.run(["zsh", str(ROOT / "Scripts" / script), *map(str, arguments)],
                                    cwd=ROOT, env=environment, text=True, capture_output=True)
            if (result.returncode == 0) != success:
                raise AssertionError(f"{script} {arguments}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
            checks += 1
            return result
        def fixture(name, content, bundle="local.prototype.RibbonDesk.signing-fixture"):
            app = work / (name+".app")
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle, CFBundleExecutable="Fixture")))
            (app / "Contents/MacOS/Fixture").write_text(content)
            return app
        first = fixture("First", "one")
        second = fixture("Second", "two")
        run("sign-app.sh", first, success=False)
        run("sign-app.sh", first, "--identity", "identifier-only", success=False)
        assert not log.exists(), "Missing/invalid identity must fail before any backend call"
        run("configure-signing.sh", "--identity", IDENTITY, "--mode", "certificate", success=False)
        assert not config.exists(), "Unavailable identity cannot be persisted"
        state["available"] = True; save_state()
        run("configure-signing.sh", "--identity", IDENTITY.lower(), "--mode", "certificate")
        selected = plistlib.loads(config.read_bytes())
        assert selected == dict(Identity=IDENTITY, RequirementMode="certificate", Keychain="")
        assert stat.S_IMODE(config.stat().st_mode) == 0o600
        run("sign-app.sh", first)
        run("sign-app.sh", second)
        incorrect_extraction = subprocess.run(
            ["codesign", "--display", "--extract-certificates", str(work / "incorrect-prefix-"), str(first)],
            env=environment, text=True, capture_output=True)
        assert incorrect_extraction.returncode != 0, "Mock must reject native optional arguments passed separately"
        checks += 1
        run("check-signing-continuity.sh", "--require-changed-code", first, second)
        run("check-signing-continuity.sh", "--require-changed-code", first, first, success=False)
        actions = [json.loads(line) for line in log.read_text().splitlines()]
        valid_extractions = [row for row in actions if any(argument.startswith("--extract-certificates=") for argument in row)]
        assert len(valid_extractions) >= 4, "Signing and continuity checks must use the native '=' extraction syntax"
        signing = [row for row in actions if row[0] == "codesign" and "--sign" in row]
        assert len(signing) == 2 and all(row[row.index("--sign")+1] == IDENTITY for row in signing)
        for row in signing:
            requirement = row[row.index("--requirements")+1]
            assert 'identifier "local.prototype.RibbonDesk.signing-fixture"' in requirement
            assert f'certificate leaf = H"{IDENTITY}"' in requirement
            assert "trusted" not in requirement and "cdhash" not in requirement
        third = fixture("OtherBundle", "three", "local.prototype.RibbonDesk.other-fixture")
        run("sign-app.sh", third)
        run("check-signing-continuity.sh", first, third, success=False)
        other_signer = fixture("OtherSigner", "other")
        run("sign-app.sh", other_signer, "--identity", OTHER_IDENTITY)
        run("check-signing-continuity.sh", first, other_signer, success=False)
        adhoc = fixture("AdHoc", "adhoc")
        run("sign-app.sh", adhoc, "--ad-hoc")
        run("check-signing-continuity.sh", first, adhoc, success=False)
        state["fail_cross"] = True; save_state()
        run("check-signing-continuity.sh", first, second, success=False)
        state["fail_cross"] = False; state["fail_verify"] = True; save_state()
        run("sign-app.sh", second, success=False)
        state["fail_verify"] = False; state["available"] = False; save_state()
        run("sign-app.sh", second, success=False)
        invalid = dict(selected, RequirementMode="identifier-only")
        config.write_bytes(plistlib.dumps(invalid))
        run("sign-app.sh", first, success=False)
        print(f"PASS {checks} signing workflow/failure checks; mocked OS tools, no keys, trust changes, builds, or app launches.")

if __name__ == "__main__": main()
