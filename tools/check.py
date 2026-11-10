"""Run Flutter checks/builds in a temporary working copy.

Some managed Windows environments reject native compiler writes in Documents.
The source stays in this repository; only generated build output uses temp.
Successful APKs are copied back into build/app/outputs/flutter-apk.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
sdk = root / ".tooling/flutter"
dart = sdk / "bin/cache/dart-sdk/bin/dart.exe"
config = sdk / "packages/flutter_tools/.dart_tool/package_config.json"
entry = sdk / "packages/flutter_tools/bin/flutter_tools.dart"
env = dict(os.environ)
env["NUDGE_FLUTTER_SDK"] = str(sdk)
env["ANDROID_HOME"] = str(root / ".tooling/android")
env["JAVA_HOME"] = str(next((root / ".tooling/java").glob("*/bin/java.exe")).parent.parent)

def copy_back(source, destination):
    """Use Windows file APIs when native compiler/Python writes are restricted."""
    source, destination = Path(source), Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        try:
            if source.read_bytes() == destination.read_bytes():
                return str(destination)
        except OSError:
            pass
    escaped_source = str(source).replace("'", "''")
    escaped_destination = str(destination).replace("'", "''")
    subprocess.run(["powershell", "-NoProfile", "-Command",
        f"[IO.File]::WriteAllBytes('{escaped_destination}', [IO.File]::ReadAllBytes('{escaped_source}'))"], check=True)
with tempfile.TemporaryDirectory(prefix="nudge-check-", ignore_cleanup_errors=True) as directory:
    stage = Path(directory)
    for name in ("lib", "test", "integration_test", "android", "ios", "tools", "assets"):
        shutil.copytree(root / name, stage / name, ignore=shutil.ignore_patterns(
            "build", ".gradle", "local.properties", "Pods", ".symlinks"))
    for name in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml", ".metadata"):
        if (root / name).exists():
            shutil.copy2(root / name, stage / name)

    def flutter(args):
        return subprocess.run([str(dart), f"--packages={config}", str(entry),
                               "--suppress-analytics", *args], cwd=stage, env=env).returncode

    print(f"Temporary build directory: {stage}", flush=True)
    status = flutter(["pub", "get"])
    if status:
        raise SystemExit(status)
    copy_back(stage / "pubspec.lock", root / "pubspec.lock")
    if sys.argv[1:] in (["verify"], ["verify-build"]):
        status = subprocess.run([str(dart), "format", "--output=none", "--set-exit-if-changed",
            "lib", "test", "integration_test", "tools/preview_test.dart"], cwd=stage, env=env).returncode
        for check in (["analyze", "--no-pub"], ["test", "--no-pub"],
                      ["test", "--no-pub", "tools/preview_test.dart"]):
            if status:
                break
            status = flutter(check)
        if status == 0 and sys.argv[1:] == ["verify-build"]:
            status = flutter(["build", "apk", "--debug", "--no-pub"])
    else:
        status = flutter(sys.argv[1:] or ["test"])
    previews = stage / "demo-output"
    if previews.exists():
        shutil.copytree(previews, root / "demo-output", dirs_exist_ok=True, copy_function=copy_back)
        print(f"Copied previews: {root / 'demo-output'}", flush=True)
    apk = stage / "build/app/outputs/flutter-apk/app-debug.apk"
    if status == 0 and apk.exists() and (sys.argv[1:3] == ["build", "apk"] or sys.argv[1:] == ["verify-build"]):
        output = root / "build/app/outputs/flutter-apk/app-debug.apk"
        output.parent.mkdir(parents=True, exist_ok=True)
        copy_back(apk, output)
        print(f"Copied APK: {output}", flush=True)
    raise SystemExit(status)
