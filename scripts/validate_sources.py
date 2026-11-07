"""Fail before Xcode if an edited Swift file is not valid UTF-8."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
errors = []
for folder in ("Sources", "Tests", "UITests"):
    for source in sorted((root / folder).rglob("*.swift")):
        try:
            source.read_bytes().decode("utf-8")
        except UnicodeDecodeError as error:
            errors.append(f"{source.relative_to(root)}: invalid UTF-8 at byte {error.start}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("Swift source encoding: UTF-8")
