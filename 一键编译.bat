@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ==================================================
echo   便携 Edge 面板 v1.3.0 —— 一键编译
echo ==================================================
echo.
if not exist "tools\7zr.exe" (
    echo [提示] 未检测到 tools\7zr.exe。
    echo 请将原仓库 tools\7zr.exe 复制到本目录的 tools\ 文件夹，
    echo 或从 https://www.7-zip.org/a/7zr.exe 下载放入后再运行。
    echo.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1"
if errorlevel 1 (
    echo.
    echo [失败] 编译未完成，请查看上方报错信息。
    pause
    exit /b 1
)
echo.
echo [成功] 已生成 Edge面板.exe，可直接复制到便携 Edge 根目录使用。
pause
