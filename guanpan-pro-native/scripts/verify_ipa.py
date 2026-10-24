#!/usr/bin/env python3
"""Fail the cloud build if an unsigned IPA has a broken or non-ASCII app path."""

from __future__ import annotations

import plistlib
import re
import sys
import zipfile
from pathlib import PurePosixPath


EXPECTED_APP = "GuanpanPro.app"
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe",  # 64-bit little endian
    b"\xfe\xed\xfa\xcf",  # 64-bit big endian
    b"\xca\xfe\xba\xbe",  # Universal/fat binary
    b"\xbe\xba\xfe\xca",
}


def verify_ipa(path: str) -> dict[str, str]:
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as exc:
        raise ValueError(f"IPA is not a readable ZIP: {exc}") from exc

    with archive:
        bad_member = archive.testzip()
        if bad_member:
            raise ValueError(f"ZIP CRC check failed for {bad_member}")

        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("IPA contains duplicate ZIP paths")
        for name in names:
            member = PurePosixPath(name)
            if name.startswith("/") or "\\" in name or ".." in member.parts:
                raise ValueError(f"Unsafe IPA path: {name!r}")

        info_paths = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(info_paths) != 1:
            raise ValueError(f"Expected one Payload app Info.plist, found {len(info_paths)}")
        info_path = info_paths[0]
        app_path = info_path.removesuffix("Info.plist")
        app_name = app_path.removeprefix("Payload/").removesuffix("/")
        if app_name != EXPECTED_APP or not app_name.isascii():
            raise ValueError(f"App bundle path must be ASCII {EXPECTED_APP}; got {app_name!r}")

        try:
            info = plistlib.loads(archive.read(info_path))
        except (plistlib.InvalidFileException, KeyError) as exc:
            raise ValueError(f"Invalid app Info.plist: {exc}") from exc
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", executable):
            raise ValueError(f"CFBundleExecutable must be an ASCII filename; got {executable!r}")
        executable_path = f"{app_path}{executable}"
        if executable_path not in names:
            raise ValueError(f"CFBundleExecutable path is missing from IPA: {executable_path}")
        if archive.read(executable_path)[:4] not in MACHO_MAGICS:
            raise ValueError(f"CFBundleExecutable is not a Mach-O binary: {executable_path}")

        bundle_id = info.get("CFBundleIdentifier")
        if bundle_id != "com.guanpan.pro.native":
            raise ValueError(f"Unexpected bundle identifier: {bundle_id!r}")
        bundle_name = info.get("CFBundleName")
        if not isinstance(bundle_name, str) or not bundle_name.isascii():
            raise ValueError(f"CFBundleName must be ASCII; got {bundle_name!r}")
        if "embedded.mobileprovision" in names:
            raise ValueError("Unsigned IPA unexpectedly contains a provisioning profile")
        return {"app": app_name, "executable": executable, "bundle_id": bundle_id}


if __name__ == "__main__":
    try:
        result = verify_ipa(sys.argv[1])
    except (IndexError, ValueError) as exc:
        print(f"IPA validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
    print("IPA validation passed: " + ", ".join(f"{key}={value}" for key, value in result.items()))
