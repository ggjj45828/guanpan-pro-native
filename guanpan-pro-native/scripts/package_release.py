#!/usr/bin/env python3
"""Create clean GuanpanMax source and NAS deployment archives."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[2]
NAS_ROOT = PurePosixPath("nas-advisor-compat")
DENIED = re.compile(r"(^|/)(\.env|[^/]*\.(?:db|sqlite3?|ipa|p12|pem|mobileprovision))$|secret|token", re.I)


def tracked_files() -> list[str]:
    result = subprocess.run(["git", "-c", f"safe.directory={ROOT.as_posix()}",
                             "-c", "core.quotepath=false", "ls-files", "-z"],
                            cwd=ROOT, check=True, capture_output=True)
    return sorted(line.decode("utf-8").replace("\\", "/")
                  for line in result.stdout.split(b"\0") if line)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_zip(path: Path, entries: list[tuple[str, Path]]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, source in entries:
            archive.write(source, name)
        manifest = "\n".join(f"{sha256(source)}  {name}" for name, source in entries) + "\n"
        archive.writestr("SHA256SUMS.txt", manifest)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    files = tracked_files()
    if any(DENIED.search(name) for name in files):
        blocked = [name for name in files if DENIED.search(name)]
        raise SystemExit(f"Refusing to package sensitive or generated files: {blocked}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    source_entries = [(name, ROOT / Path(*PurePosixPath(name).parts)) for name in files]
    nas_names = {".env.example", "compose.yml", "README-NAS.md", "update.sh"}
    nas_entries: list[tuple[str, Path]] = []
    for name, source in source_entries:
        relative = PurePosixPath(name)
        if not relative.is_relative_to(NAS_ROOT):
            continue
        child = relative.relative_to(NAS_ROOT)
        if (child.as_posix() in nas_names or
                (len(child.parts) == 2 and child.parts[0] == "server" and
                 (child.suffix == ".py" or child.name in {"Dockerfile", "start.sh", "VERSION"}))):
            nas_entries.append((child.as_posix(), source))
    required = {".env.example", "compose.yml", "README-NAS.md", "update.sh",
                "server/Dockerfile", "server/start.sh", "server/VERSION"}
    missing = required - {name for name, _ in nas_entries}
    if missing:
        raise SystemExit(f"NAS package is missing required files: {sorted(missing)}")

    source_name = f"GuanpanMax-source-{args.revision}.zip"
    nas_name = f"GuanpanMax-NAS-{args.revision}.zip"
    write_zip(args.output_dir / source_name, source_entries)
    write_zip(args.output_dir / nas_name, nas_entries)
    print(f"source={args.output_dir / source_name}")
    print(f"source_sha256={sha256(args.output_dir / source_name)}")
    print(f"source_files={len(source_entries)}")
    print(f"nas={args.output_dir / nas_name}")
    print(f"nas_sha256={sha256(args.output_dir / nas_name)}")
    print(f"nas_files={len(nas_entries)}")


if __name__ == "__main__":
    main()
