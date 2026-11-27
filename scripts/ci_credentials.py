#!/usr/bin/env python3
"""Install Diffs signing inputs in a disposable GitHub Actions Keychain."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import subprocess
import sys
import uuid


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Credentials can occur in both arguments and subprocess diagnostics.
        raise RuntimeError(f"{args[0]} failed ({result.returncode})")
    return result.stdout


def write_private(path, content):
    with os.fdopen(
        os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb"
    ) as output:
        output.write(content)


def install(root):
    root.mkdir(mode=0o700)
    keychain = root / "signing.keychain-db"
    original = shlex.split(command("security", "list-keychains", "-d", "user"))
    state = {"keychain": str(keychain), "originalKeychains": original, "profiles": []}
    state_file = root / "state.json"
    state_file.write_text(json.dumps(state))
    password = secrets.token_urlsafe(32)
    command("security", "create-keychain", "-p", password, keychain)
    command("security", "set-keychain-settings", "-lut", "21600", keychain)
    command("security", "unlock-keychain", "-p", password, keychain)
    command("security", "list-keychains", "-d", "user", "-s", keychain, *original)

    certificate = root / "certificate.p12"
    write_private(certificate, base64.b64decode(os.environ["DIFFS_CERTIFICATE_P12"], validate=True))
    command("security", "import", certificate, "-k", keychain, "-P", os.environ["DIFFS_CERTIFICATE_PASSWORD"],
            "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    command("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain)
    certificate.unlink()

    data = base64.b64decode(os.environ["DIFFS_MAC_PROFILE"], validate=True)
    temporary = root / "Diffs.provisionprofile"
    write_private(temporary, data)
    profile = plistlib.loads(subprocess.check_output(
        ["security", "cms", "-D", "-i", temporary], stderr=subprocess.DEVNULL))
    identifier = "com.SilverMarcs.Atrium"
    team = "J52QUTREBS"
    profile_id = str(uuid.UUID(profile["UUID"])).upper()
    entitlements = profile["Entitlements"]
    if (entitlements.get("com.apple.application-identifier") != f"{team}.{identifier}"
            or not entitlements.get("com.apple.developer.usernotifications.communication")
            or not profile.get("ProvisionsAllDevices") or profile.get("ProvisionedDevices")
            or profile.get("IsXcodeManaged")):
        raise RuntimeError("Unexpected Diffs Developer ID profile")
    for directory in [Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
                      Path.home() / "Library/MobileDevice/Provisioning Profiles"]:
        directory.mkdir(parents=True, exist_ok=True)
        destination = directory / (profile_id + ".provisionprofile")
        write_private(destination, data)
        state["profiles"].append(str(destination))
        state_file.write_text(json.dumps(state))
    options = {"method": "developer-id", "signingStyle": "manual", "teamID": team,
               "signingCertificate": "Developer ID Application", "provisioningProfiles": {identifier: profile_id}}
    write_private(root / "ExportOptions.plist", plistlib.dumps(options))

    key = root / "AuthKey.p8"
    write_private(key, os.environ["DIFFS_NOTARY_API_KEY"].encode())
    command("xcrun", "notarytool", "store-credentials", "swiftterminal-notary", "--key", key,
            "--key-id", os.environ["DIFFS_NOTARY_KEY_ID"].strip(),
            "--issuer", os.environ["DIFFS_NOTARY_ISSUER_ID"].strip(), "--keychain", keychain)
    key.unlink()
    write_private(root / "sparkle-key", os.environ["DIFFS_SPARKLE_PRIVATE_KEY"].strip().encode() + b"\n")
    with open(os.environ["GITHUB_ENV"], "a") as environment:
        environment.write(f"DIFFS_CI_PROFILE={profile_id}\n")
        environment.write(f"DIFFS_CI_EXPORT_OPTIONS={root / 'ExportOptions.plist'}\n")
        environment.write(f"SPARKLE_KEY_FILE={root / 'sparkle-key'}\n")
    print("Installed isolated signing, provisioning, notarization and Sparkle credentials.")


def cleanup(root):
    state_file = root / "state.json"
    if state_file.exists():
        state = json.loads(state_file.read_text())
        command("security", "list-keychains", "-d", "user", "-s", *state["originalKeychains"])
        if Path(state["keychain"]).exists():
            command("security", "delete-keychain", state["keychain"])
        for profile in state["profiles"]:
            Path(profile).unlink(missing_ok=True)
    if root.exists():
        shutil.rmtree(root)
    print("Removed runner signing credentials.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "cleanup"])
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        (install if args.action == "install" else cleanup)(args.directory)
    except RuntimeError as error:
        sys.exit(f"Credential operation failed: {error}")
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError):
        print("Credential operation failed. No secret values were logged.", file=sys.stderr)
        sys.exit(1)
