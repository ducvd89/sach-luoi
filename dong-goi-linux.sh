#!/usr/bin/env bash
# Đóng gói ứng dụng Sách lười cho Linux / Flatpak.
#
#   ./dong-goi-linux.sh
#
# Kết quả nằm trong dist/SachLuoi-linux-x64/ gồm binary thực thi, các thư viện
# native Rust (libsachnoi_vieneu.so, libsea_g2p_rs.so) và tài nguyên bundle.
# Mô hình giọng nói KHÔNG được sao chép — ứng dụng tự tải trong phần Cài đặt.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${ROOT_DIR}/dist/SachLuoi-linux-x64"

export PATH="${HOME}/flutter/bin:${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"

echo ""
echo "=== 1. Biên dịch các thư viện Rust native ==="

echo "--> Biên dịch sea-g2p (chuyển chữ sang âm vị)..."
cd "${ROOT_DIR}/native/sea-g2p"
cargo build --release --no-default-features --features ffi

echo "--> Biên dịch vieneu (mô hình TTS & mã hoá âm thanh)..."
cd "${ROOT_DIR}/native/vieneu"
cargo build --release

echo ""
echo "=== 2. Biên dịch ứng dụng Flutter cho Linux ==="
cd "${ROOT_DIR}/app"
flutter build linux --release

RELEASE_BUNDLE="${ROOT_DIR}/app/build/linux/x64/release/bundle"
if [ ! -d "${RELEASE_BUNDLE}" ]; then
    echo "LỖI: Không tìm thấy thư mục bundle: ${RELEASE_BUNDLE}" >&2
    exit 1
fi

echo ""
echo "=== 3. Đóng gói vào dist/SachLuoi-linux-x64 ==="
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}/lib"

# Sao chép bundle Flutter
cp -r "${RELEASE_BUNDLE}"/* "${DIST_DIR}/"

# Đảm bảo các thư viện native Rust có mặt trong lib/
cp -f "${ROOT_DIR}/native/vieneu/target/release/libsachnoi_vieneu.so" "${DIST_DIR}/lib/"
cp -f "${ROOT_DIR}/native/sea-g2p/target/release/libsea_g2p_rs.so" "${DIST_DIR}/lib/"

# Sao chép tài nguyên flatpak và README
mkdir -p "${DIST_DIR}/flatpak"
cp -r "${ROOT_DIR}/flatpak"/* "${DIST_DIR}/flatpak/"
cp "${ROOT_DIR}/README.md" "${DIST_DIR}/"

# Hiển thị dung lượng
SIZE_MB=$(du -sm "${DIST_DIR}" | cut -f1)
echo ""
echo "Đóng gói hoàn tất: ${SIZE_MB} MB tại ${DIST_DIR}"
echo "Để chạy thử trực tiếp: ${DIST_DIR}/SachLuoi"
echo "Để đóng gói Flatpak: ./flatpak/build-flatpak.sh"
echo ""
