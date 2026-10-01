#!/usr/bin/env bash
# Dựng và cài đặt Flatpak cho Sách lười.
#
# Cách dùng:
#   ./flatpak/build-flatpak.sh [--bundle]
#
# Tuỳ chọn:
#   --bundle    Xuất ra file vn.sachluoi.SachLuoi.flatpak để phân phối độc lập.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist/SachLuoi-linux-x64"

# Kiểm tra thư mục dist đã được build chưa
if [ ! -d "${DIST_DIR}" ]; then
    echo "Chưa thấy thư mục ${DIST_DIR}."
    echo "Đang tự động chạy ./dong-goi-linux.sh..."
    "${ROOT_DIR}/dong-goi-linux.sh"
fi

# Tìm flatpak-builder
BUILDER=""
if command -v flatpak-builder &>/dev/null; then
    BUILDER="flatpak-builder"
elif flatpak info org.flatpak.Builder &>/dev/null; then
    BUILDER="flatpak run org.flatpak.Builder"
else
    echo "Chưa tìm thấy flatpak-builder trên hệ thống."
    echo "Bạn có thể cài đặt bằng:"
    echo "  - Arch/CachyOS: sudo pacman -S flatpak-builder"
    echo "  - Ubuntu/Debian: sudo apt install flatpak-builder"
    echo "  - Hoặc qua Flatpak: flatpak install --user flathub org.flatpak.Builder"
    exit 1
fi

BUILD_DIR="${ROOT_DIR}/build/flatpak-build"
REPO_DIR="${ROOT_DIR}/build/flatpak-repo"

echo ""
echo "=== Dựng Flatpak vn.sachluoi.SachLuoi ==="
$BUILDER --user --install --force-clean \
    --repo="${REPO_DIR}" \
    "${BUILD_DIR}" \
    "${ROOT_DIR}/flatpak/vn.sachluoi.SachLuoi.yml"

echo ""
echo "Đã cài đặt Flatpak vn.sachluoi.SachLuoi thành công!"
echo "Chạy ứng dụng: flatpak run vn.sachluoi.SachLuoi"

if [ "${1:-}" == "--bundle" ]; then
    BUNDLE_FILE="${ROOT_DIR}/dist/vn.sachluoi.SachLuoi.flatpak"
    mkdir -p "${ROOT_DIR}/dist"
    echo ""
    echo "=== Đóng gói file Flatpak Bundle ==="
    flatpak build-bundle "${REPO_DIR}" "${BUNDLE_FILE}" vn.sachluoi.SachLuoi
    echo "Đã tạo: ${BUNDLE_FILE}"
fi
