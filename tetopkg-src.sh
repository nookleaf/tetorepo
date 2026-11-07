#!/bin/bash
# Usage: ./tetopkg-src.sh <pkgname>
set -euo pipefail

PKG="$1"
TEMPLATE="srcpkgs/${PKG}/template"

[ -f "$TEMPLATE" ] || { echo "Template tidak ditemukan: $TEMPLATE"; exit 1; }

source <(sed 's/\r$//' "$TEMPLATE")

WORKDIR="build/${pkgname}-${version}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/buildroot"
cd "$WORKDIR"

THRESHOLD_BYTES=104857600 # 100 MB

# Cek Content-Length secara cepat via HEAD request
REMOTE_SIZE=$(curl -sIL --connect-timeout 15 -A "Mozilla/5.0" "$distfiles" 2>/dev/null | tr -d '\r' | awk '/^[Cc]ontent-[Ll]ength:/ {print $2}' | tail -n 1 || echo "")
REMOTE_SIZE="${REMOTE_SIZE//[!0-9]/}"
REMOTE_SIZE="${REMOTE_SIZE:-0}"

PAYLOAD_SIZE=0
IS_MANIFEST_ONLY=0
INSTALLER_SHA256="skip"

if [ "${REMOTE_SIZE:-0}" -gt "$THRESHOLD_BYTES" ] 2>/dev/null; then
    echo ":: Remote distfile is >100MB (${REMOTE_SIZE} bytes). Using Manifest-Only packaging mode (no binary payload bundled)."
    IS_MANIFEST_ONLY=1
    INSTALLER_SHA256="skip"
else
    echo ":: Downloading distfile..."
    if ! curl -fL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 --max-time 600 -C - -o payload.bin "$distfiles"; then
        echo "Error: Gagal mendownload distfile dari $distfiles" >&2
        exit 1
    fi

    # 1. Validasi hasil download
    if stat -c%s payload.bin >/dev/null 2>&1; then
        PAYLOAD_SIZE="$(stat -c%s payload.bin)"
    elif stat -f%z payload.bin >/dev/null 2>&1; then
        PAYLOAD_SIZE="$(stat -f%z payload.bin)"
    else
        PAYLOAD_SIZE="$(wc -c < payload.bin | tr -d ' ')"
    fi

    if [ "$PAYLOAD_SIZE" -lt 1024 ]; then
        echo "Error: File payload.bin terlalu kecil (${PAYLOAD_SIZE} bytes). Kemungkinan URL redirect ke halaman error/HTML, bukan file installer asli." >&2
        exit 1
    fi

    echo ":: Downloaded payload.bin (${PAYLOAD_SIZE} bytes)"

    if [ "$PAYLOAD_SIZE" -gt "$THRESHOLD_BYTES" ]; then
        echo ":: Payload size (${PAYLOAD_SIZE} bytes) exceeds 100MB threshold. Using Manifest-Only packaging."
        IS_MANIFEST_ONLY=1
        INSTALLER_SHA256="skip"
        rm -f payload.bin
    else
        echo ":: Calculating SHA256 checksum..."
        if command -v sha256sum >/dev/null 2>&1; then
            INSTALLER_SHA256="$(sha256sum payload.bin | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
            INSTALLER_SHA256="$(shasum -a 256 payload.bin | awk '{print $1}')"
        else
            INSTALLER_SHA256="$(certutil -hashfile payload.bin SHA256 | sed -n '2p' | tr -d ' \r\n')"
        fi
    fi
fi

TYPE="${installer_type:-exe}"

ACTUAL_SIZE=0
if [ "${PAYLOAD_SIZE:-0}" -gt 0 ] 2>/dev/null; then
    ACTUAL_SIZE="$PAYLOAD_SIZE"
elif [ "${REMOTE_SIZE:-0}" -gt 0 ] 2>/dev/null; then
    ACTUAL_SIZE="$REMOTE_SIZE"
fi

if [ "$IS_MANIFEST_ONLY" -eq 1 ]; then
    echo ":: Creating manifest-only package descriptor in buildroot..."
    echo "Package: ${pkgname}" > buildroot/.manifest
    echo "Type: remote-manifest" >> buildroot/.manifest
    echo "InstallerUrl: ${distfiles}" >> buildroot/.manifest
    echo "InstallerSize: ${ACTUAL_SIZE}" >> buildroot/.manifest
else
    if [ "$TYPE" = "zip" ]; then
        echo ":: Zip installer payload detected, extracting to buildroot..."
        if 7z x payload.bin -obuildroot >/dev/null 2>&1; then
            echo ":: Successfully extracted zip payload."
        else
            unzip -q payload.bin -d buildroot 2>/dev/null || true
        fi
    else
        echo ":: Exe installer payload detected, placing installer in buildroot..."
        EXE_TARGET="${main_exe:-installer.exe}"
        cp payload.bin "buildroot/${EXE_TARGET}"
        [ "$EXE_TARGET" != "installer.exe" ] && cp payload.bin buildroot/installer.exe
    fi
    echo "Package: ${pkgname}" > buildroot/.manifest
    echo "Type: bundled" >> buildroot/.manifest
    echo "InstallerUrl: ${distfiles}" >> buildroot/.manifest
    echo "InstallerSize: ${ACTUAL_SIZE}" >> buildroot/.manifest
fi

# 2. Validasi hasil extract/buildroot
FILE_COUNT="$(find buildroot -type f | wc -l | tr -d ' ')"

if du -sb buildroot >/dev/null 2>&1; then
    EXTRACTED_SIZE="$(du -sb buildroot | awk '{print $1}')"
elif command -v stat >/dev/null 2>&1 && stat -c%s buildroot >/dev/null 2>&1; then
    EXTRACTED_SIZE="$(find buildroot -type f -exec stat -c%s {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')"
elif command -v stat >/dev/null 2>&1 && stat -f%z buildroot >/dev/null 2>&1; then
    EXTRACTED_SIZE="$(find buildroot -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')"
else
    EXTRACTED_SIZE="$(find buildroot -type f -exec wc -c {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')"
fi

echo ":: Extract info: ${FILE_COUNT} files, ${EXTRACTED_SIZE} bytes in buildroot"

if [ "$FILE_COUNT" -eq 0 ] || [ "$EXTRACTED_SIZE" -eq 0 ]; then
    echo "Error: Hasil ekstraksi/instalasi kosong (0 file / 0 bytes dalam buildroot)." >&2
    exit 1
fi

echo ":: Generating TETOBUILD..."
flavor_escaped="${installer_flavor//\\/\\\\}"
flavor_escaped="${flavor_escaped//\"/\\\"}"
cat > TETOBUILD <<EOF
[meta]
pkgname = "${pkgname}"
pkgver = "${version}"
pkgrel = ${revision}
pkgdesc = "${short_desc}"
arch = ["${arch}"]
url = "${homepage}"
license = ["${license}"]
main_exe = "${main_exe:-}"
shortcut_name = "${shortcut_name:-${pkgname}}"
installer_type = "${TYPE}"
installer_url = "${distfiles}"
installer_sha256 = "${INSTALLER_SHA256}"
installer_flavor = "${flavor_escaped}"

[deps]
depends = []
EOF

echo ":: Package payload size (extracted): ${EXTRACTED_SIZE} bytes (${FILE_COUNT} files)"
echo ":: Packing .tetopkg..."
TETO_PACK_BIN="../../teto-pack"
if [ ! -f "$TETO_PACK_BIN" ]; then
    if [ -f "./teto-pack" ]; then
        TETO_PACK_BIN="./teto-pack"
    elif [ -f "../../tetopkg/target/debug/teto-pack.exe" ]; then
        TETO_PACK_BIN="../../tetopkg/target/debug/teto-pack.exe"
    elif command -v teto-pack >/dev/null 2>&1; then
        TETO_PACK_BIN="teto-pack"
    fi
fi

"$TETO_PACK_BIN" --tetobuild TETOBUILD --prefix buildroot \
    --output "${pkgname}-${version}-${revision}-${arch}.tetopkg"

PKG_FILE="${pkgname}-${version}-${revision}-${arch}.tetopkg"
if [ "$IS_MANIFEST_ONLY" -eq 1 ] && [ "${ACTUAL_SIZE:-0}" -gt 0 ] 2>/dev/null && [ -f "$PKG_FILE" ]; then
    echo ":: Updating .PKGINFO.toml size to actual installer size: ${ACTUAL_SIZE} bytes..."
    python3 -c "
import tarfile, io, os, re, subprocess
pkg = '$PKG_FILE'
size = $ACTUAL_SIZE
tmp_tar = pkg + '.tmp.tar'
new_tar = pkg + '.new.tar'
try:
    subprocess.run(f'zstd -d \"{pkg}\" -o \"{tmp_tar}\"', shell=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with tarfile.open(tmp_tar, 'r') as tin:
        with tarfile.open(new_tar, 'w') as tout:
            for member in tin.getmembers():
                f = tin.extractfile(member) if member.isreg() else None
                data = f.read() if f else b''
                if member.name in ('.PKGINFO.toml', './.PKGINFO.toml'):
                    text = data.decode('utf-8', errors='ignore')
                    text = re.sub(r'(?m)^size\s*=\s*\d+', f'size = {size}', text)
                    data = text.encode('utf-8')
                    member.size = len(data)
                tout.addfile(member, io.BytesIO(data) if data else None)
    subprocess.run(f'zstd -f -3 \"{new_tar}\" -o \"{pkg}\"', shell=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f':: Successfully updated .PKGINFO.toml size to {size}')
except Exception as e:
    print(f':: Warning: Failed to patch .PKGINFO.toml: {e}')
finally:
    if os.path.exists(tmp_tar): os.remove(tmp_tar)
    if os.path.exists(new_tar): os.remove(new_tar)
" 2>/dev/null || true
fi

echo ":: Done: ${WORKDIR}/${pkgname}-${version}-${revision}-${arch}.tetopkg"
