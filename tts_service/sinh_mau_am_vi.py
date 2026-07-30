"""Sinh dữ liệu đối chiếu âm vị từ thư viện Python.

Bản Dart trên điện thoại gọi cùng lõi Rust nhưng qua cổng C tự viết. Nếu cổng đó
sai ở đâu — chuỗi UTF-8, cờ punc_norm, quản lý bộ nhớ — thì âm vị lệch và mô
hình đọc sai, mà lỗi kiểu đó tai người rất khó bắt. Nên chốt kết quả của bản
Python thành file để bài test bên Dart đối chiếu từng câu.

    .venv-vieneu\\Scripts\\python.exe sinh_mau_am_vi.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent / "test_data" / "am_vi_mau.json"

# Chọn câu chạm vào những chỗ dễ sai nhất: dấu tiếng Việt, số, ngày tháng, đơn
# vị, viết tắt, chữ nước ngoài, dấu câu lạ và câu ngắn (nhánh punc_norm).
CASES: list[tuple[str, bool]] = [
    ("Xin chào, đây là bản đọc thử.", False),
    ("Xin chào", True),
    ("Năm 1975, cả nước thống nhất.", False),
    ("Ngày 20/11/1954 trời mưa rất to.", False),
    ("Giá một cân gạo là 12.500 đồng.", False),
    ("Ruộng nhà ông rộng 3.500 m2, cách nhà chừng 2 km.", False),
    ("PGS.TS Nguyễn Văn A phát biểu lúc 10:30.", False),
    ("Phía đông bắc thành Thăng Long có một xóm nhà lá sập sệ.", False),
    ("Họ sống chen chúc với chuột, gián, rết, bọ.", True),
    ("Nàng kéo tay Liễu Thạch đi dạo phố với vẻ mặt rất hào hứng.", False),
    ("Tỉ số chung cuộc là 2-1 nghiêng về đội khách.", False),
    ("Nhiệt độ hôm nay khoảng 30-32 độ C, độ ẩm 75%.", False),
]


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")

    from sea_g2p import SEAPipeline, Normalizer

    pipeline = SEAPipeline(lang="vi")
    normalizer = Normalizer(lang="vi")

    cases = []
    for text, punc_norm in CASES:
        cases.append({
            "text": text,
            "punc_norm": punc_norm,
            "normalized": normalizer.normalize(text, punc_norm=punc_norm),
            "phonemes": pipeline.run(text, punc_norm=punc_norm),
        })
        print(f"  {text[:48]:50s} -> {cases[-1]['phonemes'][:40]}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps({"nguon": "sea-g2p (Python)", "cases": cases}, ensure_ascii=False, indent=1),
        encoding="utf-8",
    )
    print(f"\nĐã ghi {len(cases)} câu vào {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
