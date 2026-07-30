# -*- coding: utf-8 -*-
"""Ve icon ung dung Sach luoi: quyen sach mo dang ngu, kem chu z.

Chay lai khi muon sua icon (can Pillow):

    tts_service\.venv-vieneu\Scripts\python.exe tools\ve_icon.py icon-moi

Roi chep ket qua vao dung cho:

    icon-moi\app_icon.ico          -> app\windows\runner\resources\
    icon-moi\mipmap-*\*.png       -> app\android\app\src\main\res\mipmap-*\

Ve o 4096 roi thu nho bang LANCZOS -> net o ca 48 px. Mau lay theo mau chu dao
cua app (#C8752A trong app/lib/ui/theme.dart).
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

S = 4096          # canh khi ve
U = S / 1024.0    # he so: moi so do ben duoi tinh theo khong gian 1024

CAM_SANG = (232, 163, 84)
CAM_DAM = (176, 96, 30)
NAU = (108, 56, 18)
KEM = (250, 245, 233)
KEM_TOI = (222, 208, 184)


def px(v):
    return v * U


def duong_cong(x1, x2, y_bien, y_giua, buoc=140):
    """Canh tren/duoi cua sach: vong xuong o giua (khe gap sach)."""
    diem = []
    for i in range(buoc + 1):
        t = i / buoc
        x = x1 + (x2 - x1) * t
        # nua hinh sin: 0 o hai dau, 1 o giua
        y = y_bien + (y_giua - y_bien) * math.sin(math.pi * t)
        diem.append((px(x), px(y)))
    return diem


def hinh_sach(dy=0.0, no=0.0):
    """Mot khoi trang sach. [dy] day xuong, [no] phinh ra moi phia."""
    tren = duong_cong(140 - no, 884 + no, 372 + dy - no, 446 + dy - no)
    duoi = duong_cong(166 - no, 858 + no, 636 + dy + no, 716 + dy + no)
    return tren + duoi[::-1]


def nen_chuyen_mau():
    """Nen cam, sang o goc tren-trai xuong dam o goc duoi-phai."""
    nho = Image.new("RGB", (64, 64))
    d = nho.load()
    for y in range(64):
        for x in range(64):
            t = (x / 63 * 0.45 + y / 63 * 0.55)
            d[x, y] = tuple(
                round(a + (b - a) * t) for a, b in zip(CAM_SANG, CAM_DAM)
            )
    return nho.resize((S, S), Image.LANCZOS)


def mat_na_vien_tron(ban_kinh=224):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, S - 1, S - 1], radius=px(ban_kinh), fill=255)
    return m


def font_z(kich_co):
    for ten in ("arialbd.ttf", "seguisb.ttf", "verdanab.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(ten, int(kich_co))
        except OSError:
            continue
    return None


def ve_chu_z(anh, tam_x, tam_y, kich_co, mau, nghieng=-12):
    """Ve mot chu z, ve rieng roi quay de vien khong bi rang cua."""
    f = font_z(kich_co)
    if f is None:
        return
    o = Image.new("RGBA", (int(kich_co * 2), int(kich_co * 2)), (0, 0, 0, 0))
    d = ImageDraw.Draw(o)
    d.text((int(kich_co), int(kich_co)), "z", font=f, fill=mau, anchor="mm")
    o = o.rotate(nghieng, resample=Image.BICUBIC, expand=True)
    anh.alpha_composite(o, (int(tam_x - o.width / 2), int(tam_y - o.height / 2)))


def ve_sach(anh, mau_bia=NAU, mau_trang=KEM, mau_bong=KEM_TOI):
    """Quyen sach mo: bia duoi, hai khoi trang, khe gap o giua."""
    d = ImageDraw.Draw(anh)
    # Bia lo ra phia duoi va hai ben.
    d.polygon(hinh_sach(dy=36, no=22), fill=mau_bia + (255,))
    # Lop trang duoi cung, hoi toi -> thay do day cua tap giay.
    d.polygon(hinh_sach(dy=14), fill=mau_bong + (255,))
    # Mat trang tren.
    d.polygon(hinh_sach(), fill=mau_trang + (255,))
    # Khe gap giua hai trang.
    d.line(
        [(px(512), px(446)), (px(512), px(716))],
        fill=mau_bong + (255,),
        width=int(px(13)),
    )


def ve_icon(kem_nen=True, ty_le_sach=0.94, day_xuong=52, doi_mau_z=None):
    anh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if kem_nen:
        nen = nen_chuyen_mau().convert("RGBA")
        nen.putalpha(mat_na_vien_tron())
        anh.alpha_composite(nen)

    lop = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ve_sach(lop)
    mau_z = doi_mau_z or KEM
    # Ba chu z bay len goc tren-phai, nho dan.
    ve_chu_z(lop, px(648), px(268), px(246), mau_z + (255,), nghieng=-10)
    ve_chu_z(lop, px(790), px(166), px(172), mau_z + (255,), nghieng=-16)
    ve_chu_z(lop, px(888), px(92), px(122), mau_z + (255,), nghieng=-22)

    # Ca nhom (sach + zzz) cao gan het khung nen phai thu nho va day xuong mot
    # chut, khong thi phan trong o duoi nhieu hon o tren, trong lech.
    moi = int(S * ty_le_sach)
    lop = lop.resize((moi, moi), Image.LANCZOS)
    dem = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dem.alpha_composite(lop, ((S - moi) // 2, (S - moi) // 2 + int(px(day_xuong))))
    anh.alpha_composite(dem)
    return anh


def luu(anh, duong_dan, canh):
    os.makedirs(os.path.dirname(duong_dan), exist_ok=True)
    anh.resize((canh, canh), Image.LANCZOS).save(duong_dan)
    print(f"  {canh:>4} px  {duong_dan}")


if __name__ == "__main__":
    ra = sys.argv[1]
    day_du = ve_icon()

    # Xem truoc o cac co that su hay gap.
    for canh in (512, 256, 128, 96, 48):
        luu(day_du, os.path.join(ra, f"xem-truoc-{canh}.png"), canh)

    # Icon Windows: nhieu co trong mot file .ico.
    ico = os.path.join(ra, "app_icon.ico")
    day_du.save(
        ico, format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print(f"  ico       {ico}")

    # Android kieu cu: anh vuong day du.
    for ten, canh in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        luu(day_du, os.path.join(ra, "mipmap-" + ten, "ic_launcher.png"), canh)

    # Android adaptive icon: lop truoc trong suot, hinh nam trong vung an toan
    # giua (108dp anh, chi 72dp o giua luon hien) -> thu nho con 62%.
    truoc = ve_icon(kem_nen=False, ty_le_sach=0.62, day_xuong=34)
    for ten, canh in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)):
        luu(truoc, os.path.join(ra, "mipmap-" + ten, "ic_launcher_foreground.png"), canh)

    # Lop nen adaptive: chi la mau chuyen, khong bo goc (he thong tu cat).
    nen = nen_chuyen_mau().convert("RGBA")
    for ten, canh in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)):
        luu(nen, os.path.join(ra, "mipmap-" + ten, "ic_launcher_background.png"), canh)
