#!/usr/bin/env bash
# Đóng gói Sách lười thành AppImage cho Linux x86_64.
#
#   ./build-appimage.sh
#
# Kết quả: dist/SachLuoi-1.8.0-x86_64.AppImage

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APPDIR="${ROOT_DIR}/build/AppDir"
VERSION="1.8.0"
OUTPUT_NAME="SachLuoi-${VERSION}-x86_64.AppImage"

export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/flutter/bin:${PATH}"

echo "=== 1. Chuẩn bị bundle Linux ==="
if [ ! -d "${DIST_DIR}/SachLuoi-linux-x64" ]; then
    "${ROOT_DIR}/dong-goi-linux.sh"
fi

echo "=== 2. Tạo cấu trúc AppDir ==="
rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin"
mkdir -p "${APPDIR}/usr/lib"
mkdir -p "${APPDIR}/usr/share/applications"
mkdir -p "${APPDIR}/usr/share/icons/hicolor/512x512/apps"
mkdir -p "${APPDIR}/usr/share/metainfo"

# Sao chép Flutter bundle vào usr/bin
cp -a "${DIST_DIR}/SachLuoi-linux-x64"/* "${APPDIR}/usr/bin/"

# Sao chép các thư viện libmpv & ffmpeg kèm theo vào usr/lib để tự chứa (hermetic)
if [ -d "${ROOT_DIR}/build/test_mpv" ]; then
    cp -a "${ROOT_DIR}/build/test_mpv"/* "${APPDIR}/usr/lib/"
fi

# Sao chép desktop file, icon và metainfo
cp "${ROOT_DIR}/flatpak/vn.sachluoi.SachLuoi.desktop" "${APPDIR}/vn.sachluoi.SachLuoi.desktop"
cp "${ROOT_DIR}/flatpak/vn.sachluoi.SachLuoi.desktop" "${APPDIR}/usr/share/applications/"

cp "${ROOT_DIR}/flatpak/icons/512x512.png" "${APPDIR}/vn.sachluoi.SachLuoi.png"
cp "${ROOT_DIR}/flatpak/icons/512x512.png" "${APPDIR}/.DirIcon"
cp "${ROOT_DIR}/flatpak/icons/512x512.png" "${APPDIR}/usr/share/icons/hicolor/512x512/apps/vn.sachluoi.SachLuoi.png"

cp "${ROOT_DIR}/flatpak/vn.sachluoi.SachLuoi.metainfo.xml" "${APPDIR}/usr/share/metainfo/"

# Tạo AppRun
cat << 'EOF' > "${APPDIR}/AppRun"
#!/usr/bin/env bash
set -e

HERE="$(dirname "$(readlink -f "${0}")")"

export APPDIR="${HERE}"
export PATH="${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${HERE}/usr/bin/lib:${LD_LIBRARY_PATH:-}"
export ORT_DYLIB_PATH="${HERE}/usr/bin/lib/libonnxruntime.so"
export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

exec "${HERE}/usr/bin/SachLuoi" "$@"
EOF
chmod +x "${APPDIR}/AppRun"

echo "=== 3. Tạo file AppImage bằng appimagetool ==="
mkdir -p "${DIST_DIR}"
ARCH=x86_64 appimagetool --comp zstd "${APPDIR}" "${DIST_DIR}/${OUTPUT_NAME}"

echo ""
echo "Đã tạo thành công: ${DIST_DIR}/${OUTPUT_NAME}"
ls -lh "${DIST_DIR}/${OUTPUT_NAME}"
