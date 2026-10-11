#!/usr/bin/env python3
"""Creates damaged and hostile backup archives used by BackupTests (and for manual QA).

Usage: python3 Tools/make_backup_fixtures.py TimestampCameraWorkPhotosTests/Fixtures
"""
import hashlib
import json
import os
import struct
import sys
import zipfile
import zlib

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(OUT, exist_ok=True)

PROJECT = "11111111-1111-1111-1111-111111111111"
OTHER_PROJECT = "22222222-2222-2222-2222-222222222222"
PHOTO = "33333333-3333-3333-3333-333333333333"
PHOTO2 = "44444444-4444-4444-4444-444444444444"
NOW = "2026-10-08T10:00:00Z"
PAYLOAD = b"\xff\xd8\xff\xe0" + b"fake jpeg payload " * 50 + b"\xff\xd9"


def manifest(files, photos=None, projects=None, pairs=None, version=1):
    return {
        "format": "WorkPhotosBackup", "formatVersion": version, "createdAt": NOW, "appVersion": "1.0", "appBuild": "1",
        "scope": "all",
        "projects": projects if projects is not None else [
            {"id": PROJECT, "title": "Fixture", "siteAddress": "", "clientName": "", "notes": "", "createdAt": NOW, "updatedAt": NOW}],
        "photos": photos if photos is not None else [
            {"id": PHOTO, "projectID": PROJECT, "source": "import", "createdAt": NOW, "updatedAt": NOW, "dateSource": "unavailable",
             "originalPath": f"Originals/{PHOTO}.jpg", "format": "jpeg", "pixelWidth": 10, "pixelHeight": 10, "orientation": 1,
             "sha256": hashlib.sha256(PAYLOAD).hexdigest(), "byteSize": len(PAYLOAD), "caption": "", "order": 0}],
        "pairs": pairs or [], "reports": [], "brandPresets": [],
        "files": files,
    }


def entry(path, data):
    return {"path": path, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def write(name, members, manifest_obj=None):
    path = os.path.join(OUT, name)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for member in members:
            archive.writestr(*member)
        if manifest_obj is not None:
            archive.writestr("manifest.json", json.dumps(manifest_obj))
    print("wrote", path)
    return path


photo_path = f"Originals/{PHOTO}.jpg"
good_files = [entry(photo_path, PAYLOAD)]

# Valid minimal backup (control case: must restore).
write("backup_valid_minimal.zip", [(photo_path, PAYLOAD)], manifest(good_files))
# Entry escaping the staging directory.
write("backup_zip_slip.zip", [(photo_path, PAYLOAD), ("../escape.txt", b"evil")], manifest(good_files))
# Absolute path entry.
write("backup_absolute_path.zip", [(photo_path, PAYLOAD), ("/tmp/evil.txt", b"evil")], manifest(good_files))
# Path traversal inside the manifest itself.
write("backup_manifest_traversal.zip", [(photo_path, PAYLOAD)],
      manifest([entry("Originals/../../evil.jpg", PAYLOAD)],
               photos=[dict(manifest(good_files)["photos"][0], originalPath="Originals/../../evil.jpg")]))
# Symbolic link entry.
path = os.path.join(OUT, "backup_symlink.zip")
with zipfile.ZipFile(path, "w") as archive:
    archive.writestr(photo_path, PAYLOAD)
    info = zipfile.ZipInfo("Originals/link.jpg")
    info.create_system = 3
    info.external_attr = (0o120777 << 16)
    archive.writestr(info, "/etc/passwd")
    archive.writestr("manifest.json", json.dumps(manifest(good_files)))
print("wrote", path)
# No manifest.
write("backup_no_manifest.zip", [(photo_path, PAYLOAD)])
# Newer, unsupported format version.
write("backup_future_version.zip", [(photo_path, PAYLOAD)], manifest(good_files, version=99))
# Wrong checksum.
bad = [dict(good_files[0], sha256="0" * 64)]
write("backup_bad_checksum.zip", [(photo_path, PAYLOAD)], manifest(bad, photos=[dict(manifest(good_files)["photos"][0], sha256="0" * 64)]))
# Pair that uses photos of different projects (broken relations).
photo2_path = f"Originals/{PHOTO2}.jpg"
projects = [
    {"id": PROJECT, "title": "A", "siteAddress": "", "clientName": "", "notes": "", "createdAt": NOW, "updatedAt": NOW},
    {"id": OTHER_PROJECT, "title": "B", "siteAddress": "", "clientName": "", "notes": "", "createdAt": NOW, "updatedAt": NOW}]
photos = [manifest(good_files)["photos"][0],
          dict(manifest(good_files)["photos"][0], id=PHOTO2, projectID=OTHER_PROJECT, originalPath=photo2_path)]
pairs = [{"id": "55555555-5555-5555-5555-555555555555", "projectID": PROJECT, "beforePhotoID": PHOTO, "afterPhotoID": PHOTO2,
          "title": "Broken", "caption": "", "order": 0, "createdAt": NOW, "updatedAt": NOW}]
write("backup_bad_relations.zip", [(photo_path, PAYLOAD), (photo2_path, PAYLOAD)],
      manifest([entry(photo_path, PAYLOAD), entry(photo2_path, PAYLOAD)], photos=photos, projects=projects, pairs=pairs))
# Not a ZIP at all.
with open(os.path.join(OUT, "backup_corrupted.zip"), "wb") as handle:
    handle.write(b"PK\x03\x04 this is not really a zip archive" * 10)
print("wrote", os.path.join(OUT, "backup_corrupted.zip"))

# Declared sizes lie: manifest and central directory claim 10 bytes, real data is 1 MB (zip-bomb style).
big = b"A" * (1024 * 1024)
lie = os.path.join(OUT, "backup_size_lie.zip")
fake_entry = {"path": photo_path, "sha256": hashlib.sha256(big[:10]).hexdigest(), "bytes": 10}
with zipfile.ZipFile(lie, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr(photo_path, big)
    archive.writestr("manifest.json", json.dumps(manifest([fake_entry],
                     photos=[dict(manifest(good_files)["photos"][0], sha256=fake_entry["sha256"], byteSize=10)])))
data = bytearray(open(lie, "rb").read())
# Patch the uncompressed size of the first entry in the local header (offset 22) and central directory.
name = photo_path.encode()
local = data.find(b"PK\x03\x04")
struct.pack_into("<I", data, local + 22, 10)
central = data.find(b"PK\x01\x02")
while central != -1:
    name_len = struct.unpack_from("<H", data, central + 28)[0]
    if bytes(data[central + 46: central + 46 + name_len]) == name:
        struct.pack_into("<I", data, central + 24, 10)
    central = data.find(b"PK\x01\x02", central + 4)
open(lie, "wb").write(bytes(data))
print("wrote", lie)
