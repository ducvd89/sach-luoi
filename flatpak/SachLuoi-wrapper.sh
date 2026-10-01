#!/usr/bin/env bash
set -e

# Tìm đường dẫn libonnxruntime.so nếu chưa được chỉ định
if [ -z "$ORT_DYLIB_PATH" ]; then
    if [ -f "/app/lib/libonnxruntime.so" ]; then
        export ORT_DYLIB_PATH="/app/lib/libonnxruntime.so"
    elif [ -f "/app/SachLuoi/lib/libonnxruntime.so" ]; then
        export ORT_DYLIB_PATH="/app/SachLuoi/lib/libonnxruntime.so"
    fi
fi

# Đảm bảo các thư viện chia sẻ trong /app/lib và /app/SachLuoi/lib được ưu tiên nạp
export LD_LIBRARY_PATH="/app/lib:/app/SachLuoi/lib:${LD_LIBRARY_PATH:-}"

exec /app/SachLuoi/SachLuoi "$@"
