"""Ghi sẵn giọng nhân bản thành hồ sơ dùng lại được.

Mỗi lần đọc, VieNeu phải trích đặc trưng giọng từ file .wav mẫu: lọc nhiễu rồi
chạy bộ mã hoá giọng nói. Việc đó chỉ phụ thuộc vào file mẫu chứ không phụ thuộc
nội dung đọc, nên làm một lần rồi cất kết quả là hơn:

* Đọc nhanh hơn — mỗi đoạn khỏi phải trích lại.
* Bỏ được PyTorch khỏi đường chạy. Bộ mã hoá giọng là chỗ duy nhất còn cần
  torchaudio; có sẵn hồ sơ rồi thì máy chỉ cần ONNX Runtime, tức là chạy được cả
  trên điện thoại.

    .venv-vieneu\\Scripts\\python.exe nap_giong.py

Đọc mọi file .wav trong voices/ và ghi voices/giong.json.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np

VOICES_DIR = Path(__file__).resolve().parent / "voices"
PROFILE_FILE = VOICES_DIR / "giong.json"

# Giọng nhân bản dùng để đọc sách nên lấy phong cách kể chuyện.
DEFAULT_STYLE = "doc_truyen"


def _builtin_presets() -> dict[str, dict]:
    """Đọc 14 giọng dựng sẵn từ chính gói vieneu đã cài.

    Chúng đã có sẵn đặc trưng giọng và mã tham chiếu tính từ trước, chỉ việc
    chép sang đúng định dạng mà engine trên máy đọc được.
    """
    try:
        import vieneu
    except ImportError:
        return {}

    package = Path(vieneu.__file__).resolve().parent
    for name in ("voices_v3_turbo.json", "voices.json"):
        path = package / "assets" / name
        if not path.exists():
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        out = {}
        for voice, value in (data.get("presets") or {}).items():
            emb = value.get("speaker_emb")
            codes = value.get("codes")
            if emb is None or codes is None:
                continue
            out[voice] = {
                "description": value.get("description", ""),
                "gender": value.get("gender", ""),
                "style": value.get("style", "tu_nhien"),
                "source": "dựng sẵn trong mô hình",
                "speaker_emb": [round(float(x), 6) for x in emb],
                "codes": np.asarray(codes, dtype=int).tolist(),
            }
        if out:
            return out
    return {}


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")

    samples = sorted(VOICES_DIR.glob("*.wav"))
    if not samples:
        print(f"Không có file .wav nào trong {VOICES_DIR}")
        return 1

    # torchaudio 2.11 không tự đọc được file .wav nữa; dùng chung bản vá của engine.
    from doc_wav import ensure_audio_loader

    ensure_audio_loader()

    from vieneu import Vieneu

    print(f"Đang nạp mô hình để trích đặc trưng {len(samples)} giọng...")
    started = time.time()
    tts = Vieneu(mode="v3turbo")
    print(f"Nạp xong sau {time.time() - started:.1f}s\n")

    profiles = {}

    # Giọng dựng sẵn của mô hình cũng cất vào cùng một file. Bản chạy trên điện
    # thoại không nạp được thư viện Python nên phải có sẵn đặc trưng ở đây, nếu
    # không nó chỉ thấy mấy giọng nhân bản.
    for name, preset in _builtin_presets().items():
        profiles[name] = preset
    print(f"Đã lấy {len(profiles)} giọng dựng sẵn của mô hình\n")

    for wav in samples:
        name = wav.stem
        print(f"  {name}: đang trích đặc trưng...", flush=True)
        start = time.time()
        speaker_emb, ref_codes = tts.engine.prepare_reference(
            str(wav), denoise=True, use_ref_codes=True
        )
        # Giữ nguyên hình dạng của mã tham chiếu: đó là ma trận [số khung x 16
        # tầng lượng tử], làm phẳng đi là mô hình dựng lại prompt sai.
        codes_array = None if ref_codes is None else np.asarray(ref_codes, dtype=int)
        emb_array = np.asarray(speaker_emb, dtype=np.float32).reshape(-1)

        profiles[name] = {
            "description": "Giọng nhân bản từ mẫu ghi âm của bạn",
            "gender": "",
            "style": DEFAULT_STYLE,
            "source": wav.name,
            "speaker_emb": [round(float(x), 6) for x in emb_array],
            "codes": None if codes_array is None else codes_array.tolist(),
        }
        shape = "không có" if codes_array is None else "x".join(str(n) for n in codes_array.shape)
        print(f"     xong sau {time.time() - start:.1f}s "
              f"({emb_array.size} chiều đặc trưng, mã tham chiếu {shape})")

    payload = {
        "meta": {
            "note": "Ho so giong nhan ban, tinh san bang nap_giong.py",
            "style_mac_dinh": DEFAULT_STYLE,
        },
        "presets": profiles,
    }
    PROFILE_FILE.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    size = PROFILE_FILE.stat().st_size / 1024
    print(f"\nĐã ghi {len(profiles)} giọng vào {PROFILE_FILE.name} ({size:.0f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
