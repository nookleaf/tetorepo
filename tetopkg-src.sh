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

echo ":: Downloading distfile..."
curl -fL --retry 5 --retry-delay 3 --retry-all-errors -C - -o payload.bin "$distfiles"

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

echo ":: Calculating SHA256 checksum..."
if command -v sha256sum >/dev/null 2>&1; then
    INSTALLER_SHA256="$(sha256sum payload.bin | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    INSTALLER_SHA256="$(shasum -a 256 payload.bin | awk '{print $1}')"
else
    INSTALLER_SHA256="$(certutil -hashfile payload.bin SHA256 | sed -n '2p' | tr -d ' \r\n')"
fi

TYPE="${installer_type:-exe}"

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
    echo "Kemungkinan penyebab: installer bukan 7z-compatible archive, silent install flags salah sehingga installer gagal menulis ke buildroot, atau instalasi butuh privilege/dependency yang tidak tersedia di environment build." >&2
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

echo ":: Done: ${WORKDIR}/${pkgname}-${version}-${revision}-${arch}.tetopkg"
