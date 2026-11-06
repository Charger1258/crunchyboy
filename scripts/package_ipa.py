"""Package an unsigned *device* .app for SideStore. Never packages simulator builds."""
from pathlib import Path
import hashlib
import os
import plistlib
import stat
import sys
import zipfile


def package(app: Path, output: Path) -> None:
    app = app.resolve(strict=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("An iPhoneOS device build is required, not an iPhone Simulator build")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("The app executable is missing")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.with_suffix(".tmp")
    try:
        with zipfile.ZipFile(staging, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(app.rglob("*")):
                if path.is_dir() and not path.is_symlink():
                    continue
                path.resolve(strict=True).relative_to(app)  # refuse links outside the app
                relative = (Path("Payload") / app.name / path.relative_to(app)).as_posix()
                if path.is_symlink():
                    entry = zipfile.ZipInfo(relative)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, os.readlink(path))
                else:
                    archive.write(path, relative)
        staging.replace(output)
    finally:
        staging.unlink(missing_ok=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".sha256").write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    print(f"Created {output.name} ({output.stat().st_size:,} bytes)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: package_ipa.py DEVICE_APP OUTPUT_IPA")
    package(Path(sys.argv[1]), Path(sys.argv[2]))
