#!/usr/bin/env python3
"""
gen-index.py — Generate index.toml dari kumpulan file .tetopkg di suatu folder.
Format mengikuti struct RepoIndex/RepoMeta di crates/teto-repo/src/index.rs
"""
import sys
import os
import glob
import hashlib
import subprocess
import time
import re
import argparse
import tomllib  # python 3.11+
import tomli_w  # pip install tomli_w

def parse_version_key(ver_str: str):
    tokens = []
    for part in re.split(r'([0-9]+)', str(ver_str)):
        if not part:
            continue
        if part.isdigit():
            tokens.append((0, int(part), ""))
        else:
            tokens.append((1, 0, part.lower()))
    return tuple(tokens)

def get_pkg_version_key(pkg_entry: dict):
    pkg = pkg_entry["package"]
    ver = pkg.get("version", "0.0.0")
    try:
        pkgrel = int(pkg.get("pkgrel", 1))
    except (ValueError, TypeError):
        pkgrel = 1
    return (parse_version_key(ver), pkgrel)

def get_package_size(pkg_path: str, pkg_info: dict) -> int:
    """Ambil ukuran asli installer dari data/.manifest atau .PKGINFO.toml."""
    try:
        res = subprocess.run(
            f"zstd -dc '{pkg_path}' | tar -xO --wildcards '*data/.manifest' 2>/dev/null",
            shell=True, capture_output=True, text=True
        )
        if res.returncode == 0 and res.stdout:
            for line in res.stdout.splitlines():
                if ':' in line:
                    k, v = line.split(':', 1)
                    if k.strip().lower() in ['installersize', 'installer_size'] and v.strip().isdigit():
                        sz = int(v.strip())
                        if sz > 0:
                            return sz
    except Exception:
        pass

    pkg_meta = pkg_info.get("package", {})
    try:
        pkg_size = int(pkg_meta.get("size", 0))
        if pkg_size > 1024:
            return pkg_size
    except (ValueError, TypeError):
        pass

    return int(os.path.getsize(pkg_path))

def read_pkginfo(tetopkg_path: str) -> dict:
    """Extract .PKGINFO.toml dari dalam arsip .tetopkg (tar + zstd)."""
    result = subprocess.run(
        f"zstd -dc '{tetopkg_path}' | tar -xO --wildcards '.PKGINFO.toml'",
        shell=True, capture_output=True, check=True
    )
    return tomllib.loads(result.stdout.decode("utf-8"))

def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()

def main():
    parser = argparse.ArgumentParser(
        description="Generate index.toml from .tetopkg files in a repository directory."
    )
    parser.add_argument("repo_dir", help="Directory containing .tetopkg files")
    parser.add_argument("output_path", help="Output path for index.toml")
    parser.add_argument("repo_name", help="Repository name")
    parser.add_argument("repo_desc", help="Repository description")
    parser.add_argument(
        "--srcpkgs",
        default="srcpkgs",
        help="Path to srcpkgs directory to filter valid packages",
    )
    parser.add_argument(
        "--prune-files",
        action="store_true",
        default=False,
        help="Delete .tetopkg files from disk if their package is not in srcpkgs",
    )
    parser.add_argument(
        "--keep-all-versions",
        action="store_true",
        default=False,
        help="Disable deduplication and keep all package versions in index.toml",
    )
    parser.add_argument(
        "--repo-url",
        default="https://repository.eu.org/x86_64/",
        help="Repository base URL",
    )

    args = parser.parse_args()

    valid_pkgs = set()
    if os.path.isdir(args.srcpkgs):
        valid_pkgs = {
            d for d in os.listdir(args.srcpkgs)
            if os.path.isfile(os.path.join(args.srcpkgs, d, "template"))
        }
        print(f":: Loaded {len(valid_pkgs)} valid package templates from {args.srcpkgs}")

    raw_packages = []
    for pkg_path in sorted(glob.glob(os.path.join(args.repo_dir, "*.tetopkg"))):
        try:
            info = read_pkginfo(pkg_path)
            pkg = info.get("package", {})
            deps = info.get("deps", {})
            pkg_name = pkg.get("name", "")

            # Filter against srcpkgs if provided
            if valid_pkgs and pkg_name not in valid_pkgs:
                print(f":: Package '{pkg_name}' not found in srcpkgs templates.")
                if args.prune_files:
                    try:
                        os.remove(pkg_path)
                        print(f":: Deleted unreferenced file: {pkg_path}")
                    except OSError as e:
                        print(f"[ERROR] Failed to delete {pkg_path}: {e}")
                else:
                    print(f":: Skipping '{pkg_name}' (use --prune-files to remove from storage)")
                continue

            print(f":: Reading {pkg_path}")
            raw_packages.append({
                "package": {
                    "name": pkg_name,
                    "version": str(pkg.get("version", "1.0.0")),
                    "pkgrel": int(pkg.get("pkgrel", 1)),
                    "arch": str(pkg.get("arch", "x86_64")),
                    "desc": str(pkg.get("desc", "")),
                    "url": str(pkg.get("url", "")),
                    "license": str(pkg.get("license", "Unknown")),
                    "size": get_package_size(pkg_path, info),
                    "builddate": int(pkg.get("builddate", int(time.time()))),
                    "packager": str(pkg.get("packager", "gen-index")),
                    "product_code": str(pkg.get("product_code", "")),
                    "main_exe": str(pkg.get("main_exe", "")),
                    "shortcut_name": str(pkg.get("shortcut_name", pkg_name)),
                    "installer_type": str(pkg.get("installer_type", "exe")),
                    "installer_url": str(pkg.get("installer_url", "")),
                    "installer_sha256": str(pkg.get("installer_sha256", "")),
                    "installer_flavor": str(pkg.get("installer_flavor", "")),
                },
                "deps": {
                    "requires": deps.get("requires", deps.get("depends", [])),
                    "optional": deps.get("optional", []),
                    "conflicts": deps.get("conflicts", []),
                    "replaces": deps.get("replaces", []),
                    "provides": deps.get("provides", []),
                },
            })
        except Exception as e:
            print(f"[ERROR] Failed to read {pkg_path}: {e}", file=sys.stderr)

    if args.keep_all_versions:
        filtered_packages = raw_packages
    else:
        # Group by package name and retain only the highest version
        grouped_packages = {}
        for entry in raw_packages:
            name = entry["package"]["name"]
            grouped_packages.setdefault(name, []).append(entry)

        filtered_packages = []
        for name, entries in grouped_packages.items():
            if len(entries) == 1:
                filtered_packages.append(entries[0])
            else:
                entries.sort(key=get_pkg_version_key)
                highest = entries[-1]
                pruned = entries[:-1]
                filtered_packages.append(highest)
                print(f":: Deduplicating '{name}': keeping version {highest['package']['version']} (rel {highest['package']['pkgrel']})")
                for p in pruned:
                    if args.prune_files:
                        p_file = os.path.join(args.repo_dir, f"{p['package']['name']}-{p['package']['version']}-{p['package']['pkgrel']}-{p['package']['arch']}.tetopkg")
                        if os.path.isfile(p_file):
                            try:
                                os.remove(p_file)
                                print(f"   -> Deleted older file: {p_file}")
                            except OSError as e:
                                print(f"[ERROR] Failed to delete older file {p_file}: {e}")

    # Urutkan berdasarkan nama paket
    filtered_packages.sort(key=lambda p: p["package"]["name"])

    repo_url = args.repo_url.rstrip("/") + "/"
    # Format struct RepoIndex dari crates/teto-repo/src/index.rs:
    # pub struct RepoIndex { pub meta: RepoMeta, pub packages: Vec<PackageInfo> }
    # pub struct RepoMeta { pub name: String, pub description: String, pub url: String, pub generated: i64 }
    index_data = {
        "meta": {
            "name": args.repo_name,
            "description": args.repo_desc,
            "url": repo_url,
            "generated": int(time.time()),
        },
        "packages": filtered_packages,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.output_path)), exist_ok=True)
    with open(args.output_path, "wb") as f:
        tomli_w.dump(index_data, f)

    print(f":: Done! Generated {args.output_path} with {len(filtered_packages)} package(s)")

if __name__ == "__main__":
    main()
