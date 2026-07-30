"""Chuẩn bị file mẫu để VieNeu nhân bản giọng.

Mẫu tốt nhất là mono, một người nói liên tục, 3-15 giây, không nhạc nền. Bản ghi
thật thường dài hơn thế và có quãng lặng, nên script chọn giúp đoạn "sạch" nhất:
cửa sổ có tỉ lệ tiếng nói cao nhất, cắt tại chỗ im lặng để không đứt giữa từ, rồi
trộn về mono và cân bằng âm lượng.

    .venv-vieneu\\Scripts\\python.exe them_giong.py "D:\\ghi-am.wav" voices\\Latradio.wav

Sau đó bấm "Kiểm tra lại" trong Cài đặt là giọng mới hiện ra trong danh sách.
"""

import sys
from pathlib import Path

import numpy as np
import soundfile as sf

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
target_seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 11.0

wav, rate = sf.read(str(src), dtype="float32", always_2d=True)
mono = wav.mean(axis=1)
print(f"Goc: {len(mono)/rate:.1f}s, {rate} Hz, {wav.shape[1]} kenh")

# Năng lượng theo khung 20 ms.
frame = int(rate * 0.02)
usable = (len(mono) // frame) * frame
frames = mono[:usable].reshape(-1, frame)
rms = np.sqrt((frames.astype(np.float64) ** 2).mean(axis=1) + 1e-12)
speech = rms > max(rms.max() * 0.06, 10 ** (-42 / 20))

# Cửa sổ nào có tỉ lệ tiếng nói cao nhất thì lấy.
win = int(target_seconds / 0.02)
if win >= len(speech):
    start_frame = 0
    win = len(speech)
else:
    coverage = np.convolve(speech.astype(np.float64), np.ones(win), mode="valid") / win
    start_frame = int(np.argmax(coverage))
    print(f"Doan chon: {start_frame*0.02:.1f}s -> {(start_frame+win)*0.02:.1f}s, "
          f"ty le tieng noi {coverage[start_frame]*100:.0f}%")

# Nhích hai đầu về chỗ im lặng gần nhất để không cắt ngang từ.
begin, end = start_frame, min(start_frame + win, len(speech))
while begin > 0 and speech[begin] and begin > start_frame - 25:
    begin -= 1
while end < len(speech) - 1 and speech[end - 1] and end < start_frame + win + 25:
    end += 1

clip = mono[begin * frame : end * frame]

# Bỏ im lặng thừa hai đầu, chừa 80 ms cho tự nhiên.
def trim(sig):
    f = np.sqrt((sig[: (len(sig) // frame) * frame].reshape(-1, frame) ** 2).mean(axis=1) + 1e-12)
    loud = np.where(f > max(f.max() * 0.06, 10 ** (-42 / 20)))[0]
    if len(loud) == 0:
        return sig
    pad = 4
    a = max(0, loud[0] - pad) * frame
    b = min(len(f), loud[-1] + pad) * frame
    return sig[a:b]

clip = trim(clip)

peak = float(np.max(np.abs(clip)))
if peak > 1e-6:
    clip = clip * (0.92 / peak)

dst.parent.mkdir(parents=True, exist_ok=True)
sf.write(str(dst), clip, rate, subtype="PCM_16")
print(f"Da ghi: {dst}  ({len(clip)/rate:.1f}s, mono, {rate} Hz)")
