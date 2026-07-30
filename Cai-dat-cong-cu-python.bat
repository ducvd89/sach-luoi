@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title Cai dat giong doc VieNeu-TTS
cd /d "%~dp0"

echo.
echo   ============================================================
echo     CAI DAT GIONG DOC VIENEU-TTS (chat luong cao nhat)
echo   ============================================================
echo.
echo   Buoc nay chi can lam MOT LAN.
echo   VieNeu chay trong moi truong Python RIENG (.venv-vieneu),
echo   khong dung cham den giong nhe chay trong ung dung.
echo.
echo   Co san 14 giong: nam/nu, ba mien Bac/Trung/Nam, voi cac
echo   phong cach ke chuyen, tin tuc, tu nhien.
echo.
echo   Muon them giong rieng: tha mot file .wav 3-15 giay vao
echo   tts_service\voices\ la xong, khong can chep loi.
echo.
pause

set "SERVICE=%~dp0tts_service"
if not exist "%SERVICE%\vieneu_server.py" (
  echo   [!] Khong tim thay tts_service\vieneu_server.py canh file nay.
  pause
  exit /b 1
)

rem ---- Tim Python 3.10 tro len -------------------------------------------
set "PY="
for %%P in ("%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
            "%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
            "%LOCALAPPDATA%\Programs\Python\Python310\python.exe") do (
  if exist %%P if not defined PY set "PY=%%~P"
)
if not defined PY (
  for /f "delims=" %%P in ('where python 2^>nul') do if not defined PY set "PY=%%P"
)
if not defined PY (
  echo   [!] Khong tim thay Python. Tai Python 3.11 tai
  echo       https://www.python.org/downloads/ roi chay lai file nay.
  pause
  exit /b 1
)
echo   Dung Python: %PY%

rem ---- Moi truong ao rieng -------------------------------------------------
if not exist "%SERVICE%\.venv-vieneu\Scripts\python.exe" (
  echo.
  echo   [1/5] Tao moi truong Python rieng cho VieNeu...
  "%PY%" -m venv "%SERVICE%\.venv-vieneu"
  if errorlevel 1 goto :fail
)
set "VPY=%SERVICE%\.venv-vieneu\Scripts\python.exe"
"%VPY%" -m pip install --upgrade pip --quiet

rem ---- PyTorch chi can khi co card NVIDIA -----------------------------------
rem Khong co card thi VieNeu chay bang ONNX Runtime, khoi tai 3 GB PyTorch.
echo.
where nvidia-smi >nul 2>nul
if errorlevel 1 (
  echo   [2/4] Khong thay card NVIDIA - bo qua PyTorch, se chay bang CPU.
) else (
  echo   [2/4] Thay card NVIDIA, cai PyTorch ban CUDA 12.8 ^(~3 GB^)...
  "%VPY%" -c "import torch" 2>nul
  if errorlevel 1 (
    "%VPY%" -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128
    if errorlevel 1 goto :fail
  ) else (
    echo         Da co san, bo qua.
  )
)

echo.
echo   [3/4] Cai VieNeu-TTS va cac goi phu tro...
"%VPY%" -m pip install -r "%SERVICE%\requirements-vieneu.txt"
if errorlevel 1 goto :fail

echo.
echo   [4/4] Tai mo hinh va doc thu mot cau ^(lan dau mat vai phut^)...
pushd "%SERVICE%"
"%VPY%" vieneu_server.py --self-test
if errorlevel 1 (
  popd
  echo.
  echo   [!] Mo hinh chua chay duoc - xem phan bao loi o tren.
  goto :fail
)
popd

echo.
echo   ============================================================
echo     XONG! Gio chay duoc nap_giong.py va them_giong.py
echo     trong thu muc tts_service.
echo   ============================================================
echo.
pause
exit /b 0

:fail
echo.
echo   [!] Co loi xay ra o buoc tren. Hay chup man hinh phan bao loi.
echo.
pause
exit /b 1
