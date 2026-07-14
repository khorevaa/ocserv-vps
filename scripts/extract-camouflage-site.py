#!/usr/bin/env python3
"""Safely unpack a small static Camouflage website."""

from __future__ import annotations

import os
import shutil
import stat
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import BinaryIO

MAX_FILES = 1000
MAX_BYTES = 10 * 1024 * 1024
MAX_PATH_LENGTH = 512


class SiteArchiveError(Exception):
    pass


def safe_relative_path(raw_name: str) -> Path:
    if (
        "\\" in raw_name
        or "\x00" in raw_name
        or any(ord(character) < 32 for character in raw_name)
    ):
        raise SiteArchiveError(f"unsafe archive path: {raw_name!r}")
    pure = PurePosixPath(raw_name)
    parts = tuple(part for part in pure.parts if part not in ("", "."))
    if pure.is_absolute() or not parts or ".." in parts:
        raise SiteArchiveError(f"unsafe archive path: {raw_name!r}")
    if len("/".join(parts)) > MAX_PATH_LENGTH or any(len(part) > 128 for part in parts):
        raise SiteArchiveError(f"archive path is too long: {raw_name!r}")
    return Path(*parts)


def copy_limited(source: BinaryIO, target: Path, total: list[int]) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as output:
        while True:
            chunk = source.read(64 * 1024)
            if not chunk:
                break
            total[0] += len(chunk)
            if total[0] > MAX_BYTES:
                raise SiteArchiveError("unpacked website exceeds the 10 MiB limit")
            output.write(chunk)


def extract_zip(archive_path: Path, root: Path) -> None:
    total = [0]
    seen: set[Path] = set()
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_FILES:
            raise SiteArchiveError("website archive contains too many entries")
        if sum(entry.file_size for entry in entries) > MAX_BYTES:
            raise SiteArchiveError("unpacked website exceeds the 10 MiB limit")
        for entry in entries:
            relative = safe_relative_path(entry.filename)
            if relative in seen:
                raise SiteArchiveError(f"duplicate archive path: {entry.filename!r}")
            seen.add(relative)
            target = root / relative
            mode = (entry.external_attr >> 16) & 0xFFFF
            file_type = stat.S_IFMT(mode)
            if file_type == stat.S_IFLNK:
                raise SiteArchiveError("website archive contains a symbolic link")
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if file_type not in (0, stat.S_IFREG):
                raise SiteArchiveError("website archive contains a non-regular file")
            with archive.open(entry, "r") as source:
                copy_limited(source, target, total)


def extract_tar(archive_path: Path, root: Path) -> None:
    total = [0]
    seen: set[Path] = set()
    count = 0
    with tarfile.open(archive_path, mode="r:*") as archive:
        for entry in archive:
            count += 1
            if count > MAX_FILES:
                raise SiteArchiveError("website archive contains too many entries")
            relative = safe_relative_path(entry.name)
            if relative in seen:
                raise SiteArchiveError(f"duplicate archive path: {entry.name!r}")
            seen.add(relative)
            target = root / relative
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not entry.isfile():
                raise SiteArchiveError("website archive contains a link or special file")
            if entry.size > MAX_BYTES or total[0] + entry.size > MAX_BYTES:
                raise SiteArchiveError("unpacked website exceeds the 10 MiB limit")
            source = archive.extractfile(entry)
            if source is None:
                raise SiteArchiveError(f"cannot read archive member: {entry.name!r}")
            with source:
                copy_limited(source, target, total)


def extract_html(archive_path: Path, root: Path) -> None:
    data = archive_path.read_bytes()
    if len(data) > MAX_BYTES:
        raise SiteArchiveError("HTML website exceeds the 10 MiB limit")
    probe = data[:8192].decode("utf-8", errors="ignore").lower()
    if "<!doctype html" not in probe and "<html" not in probe:
        raise SiteArchiveError("download is not ZIP, TAR, TAR.GZ, or HTML")
    (root / "index.html").write_bytes(data)


def select_site_root(extracted: Path) -> Path:
    if (extracted / "index.html").is_file():
        return extracted
    entries = list(extracted.iterdir())
    if len(entries) == 1 and entries[0].is_dir() and (entries[0] / "index.html").is_file():
        return entries[0]
    raise SiteArchiveError("website must contain index.html at the archive root or in one wrapper directory")


def unpack(archive_path: Path, destination: Path) -> None:
    if not archive_path.is_file() or archive_path.is_symlink():
        raise SiteArchiveError("downloaded website is missing or unsafe")
    destination.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or any(destination.iterdir()):
        raise SiteArchiveError("website destination must be an empty real directory")
    with tempfile.TemporaryDirectory(prefix=".camouflage-extract-", dir=destination.parent) as temp:
        extracted = Path(temp)
        if zipfile.is_zipfile(archive_path):
            extract_zip(archive_path, extracted)
        elif tarfile.is_tarfile(archive_path):
            extract_tar(archive_path, extracted)
        else:
            extract_html(archive_path, extracted)
        site_root = select_site_root(extracted)
        for child in site_root.iterdir():
            shutil.move(os.fspath(child), destination / child.name)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract-camouflage-site.py <download> <destination>", file=sys.stderr)
        return 2
    try:
        unpack(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, SiteArchiveError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f"Camouflage site extraction failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
