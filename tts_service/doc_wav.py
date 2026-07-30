"""Cho phép thư viện đọc file .wav mà không cần cài torchcodec.

Từ bản 2.11, torchaudio bỏ hết bộ giải mã tích hợp và bắt cài torchcodec (kéo
theo cả FFmpeg) mới mở được file. Các công cụ ở đây chỉ cần đọc vài file .wav
ngắn, nên thay bằng soundfile vốn đã có sẵn.
"""

from __future__ import annotations

import importlib.util


def ensure_audio_loader() -> None:
    try:
        import torch
        import torchaudio
    except ImportError:
        return  # không có torch thì cũng không ai gọi torchaudio

    if importlib.util.find_spec("torchcodec") is not None:
        return  # máy đã cài đủ, không đụng vào
    if getattr(torchaudio.load, "_sachnoi_shim", False):
        return

    import soundfile as sf

    def load(uri, *args, **kwargs):
        data, rate = sf.read(str(uri), dtype="float32", always_2d=True)
        # torchaudio trả về [số kênh, số mẫu]; soundfile trả ngược lại.
        return torch.from_numpy(data.T.copy()), rate

    load._sachnoi_shim = True
    torchaudio.load = load
