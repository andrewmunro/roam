"""Extract the subset of the Low Poly Ultimate Pack we use into the Godot project.

A .unitypackage is a gzipped tar of <guid>/{pathname,asset,asset.meta} entries.
Only the textured (T/) FBX meshes from a few categories and the atlas texture are copied.

Usage: python -I tools/extract_lpup.py "Low Poly Ultimate Pack.unitypackage" assets/lpup
"""
import gzip
import os
import sys
import tarfile

CATEGORIES = {
    "Vehicles_T": "vehicles",
    "Nature_T": "nature",
    "Buildings_T": "buildings",
    "Props_T": "props",
    "Racing_T": "racing",
}
TEXTURES = {"atlas-albedo-LPUP.png": "atlas-albedo.png"}


def target_for(pathname):
    parts = pathname.split("/")
    name = parts[-1]
    if name in TEXTURES and "- Textures" in parts:
        return TEXTURES[name]
    if not name.lower().endswith(".fbx") or "- Meshes_T" not in parts:
        return None
    i = parts.index("- Meshes_T")
    if i + 1 >= len(parts) or parts[i + 1] not in CATEGORIES:
        return None
    category = CATEGORIES[parts[i + 1]]
    # Trees live one folder deeper; other nested folders (rigs, dead trees) are skipped.
    if i + 4 == len(parts) and parts[i + 2] == "Trees_T":
        return category + "/trees/" + name
    if i + 3 != len(parts):
        return None
    return category + "/" + name


def main(package, out_dir):
    # Pass 1: map guid -> destination using the small pathname entries.
    targets = {}
    with gzip.open(package, "rb") as gz, tarfile.open(fileobj=gz, mode="r|") as tar:
        for member in tar:
            if member.name.endswith("/pathname"):
                data = tar.extractfile(member).read().decode("utf-8")
                rel = target_for(data.splitlines()[0].strip())
                if rel is not None:
                    targets[member.name[: -len("/pathname")]] = rel
    # Pass 2: stream the archive again and write the wanted assets.
    counts = {}
    root = os.path.normpath(out_dir)
    with gzip.open(package, "rb") as gz, tarfile.open(fileobj=gz, mode="r|") as tar:
        for member in tar:
            if not member.name.endswith("/asset"):
                continue
            rel = targets.get(member.name[: -len("/asset")])
            if rel is None:
                continue
            dest = os.path.normpath(os.path.join(root, rel))
            if not dest.startswith(root):
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(tar.extractfile(member).read())
            key = rel.split("/")[0] if "/" in rel else "textures"
            counts[key] = counts.get(key, 0) + 1
    for k in sorted(counts):
        print(f"{k}: {counts[k]}")
    print("total:", sum(counts.values()))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
