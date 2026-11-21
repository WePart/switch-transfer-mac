"""Build a self-contained Apple Silicon app. Run with a Python containing PyInstaller + PyUSB."""
import importlib.metadata
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

source = Path(__file__).resolve().parent
args = [a for a in sys.argv[1:] if not a.startswith('--')]
make_dmg = '--no-dmg' not in sys.argv
destination = Path(args[0]).resolve() if args else source / 'release'
version = re.search(r"^VERSION = '([^']+)'", (source/'backend.py').read_text(), re.M).group(1)
build_number = os.environ.get('BUILD_NUMBER', '2')
destination.mkdir(parents=True, exist_ok=True)
app = destination / 'Switch 传输助手.app'
build = source / 'build'
libusb = Path(os.environ.get('DBI_LIBUSB_PATH', '/opt/homebrew/opt/libusb/lib/libusb-1.0.dylib'))

def run(*args):
    subprocess.run([str(x) for x in args], check=True, cwd=source)

run(sys.executable, '-m', 'PyInstaller', '--noconfirm', '--onedir', '--name', 'dbi-worker',
    '--distpath', source/'dist', '--workpath', build, '--specpath', source,
    '--add-binary', f'{libusb}:.', '--hidden-import', 'usb.backend.libusb1', source/'backend.py')
run('swiftc', '-parse-as-library', '-O', '-target', 'arm64-apple-macosx26.0', *sorted((source/'Sources').glob('*.swift')),
    '-o', source/'SwitchTransfer', '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'IOKit',
    '-framework', 'UserNotifications')
run('swift', source/'MakeIcon.swift', source/'AppIcon.iconset')
run('iconutil', '-c', 'icns', source/'AppIcon.iconset', '-o', source/'AppIcon.icns')
if app.exists():
    # This is a generated build artifact, never a user's installed application.
    shutil.rmtree(app)
macos = app/'Contents/MacOS'; resources = app/'Contents/Resources'
macos.mkdir(parents=True); resources.mkdir(parents=True)
shutil.copy2(source/'SwitchTransfer', macos/'SwitchTransfer')
shutil.copy2(source/'AppIcon.icns', resources/'AppIcon.icns')
shutil.copytree(source/'dist/dbi-worker', resources/'backend', symlinks=True)
info = {
    'CFBundleName': 'Switch 传输助手', 'CFBundleDisplayName': 'Switch 传输助手',
    'CFBundleIdentifier': 'cn.xion.switchtransfer', 'CFBundleExecutable': 'SwitchTransfer',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version, 'CFBundleVersion': build_number,
    'CFBundleIconFile': 'AppIcon', 'CFBundleDevelopmentRegion': 'zh_CN',
    'CFBundleLocalizations': ['zh_CN'], 'LSMinimumSystemVersion': '26.0',
    'NSHighResolutionCapable': True, 'NSSupportsAutomaticGraphicsSwitching': True,
    'NSHumanReadableCopyright': 'DBI0 protocol: duckbill / dev#Mikami. Original GUI: CAI (Hanlin Cai).',
    'NSDownloadsFolderUsageDescription': '读取你选择的 Switch 安装包。',
    'NSDocumentsFolderUsageDescription': '读取你选择的 Switch 安装包。',
    'NSRemovableVolumesUsageDescription': '读取你选择的外置磁盘上的安装包。',
    'CFBundleDocumentTypes': [{
        'CFBundleTypeName': 'Switch 安装包', 'CFBundleTypeRole': 'Viewer',
        'LSHandlerRank': 'Alternate', 'CFBundleTypeExtensions': ['nsp', 'nsz', 'xci', 'xcz'],
    }],
}
with (app/'Contents/Info.plist').open('wb') as file:
    plistlib.dump(info, file)
notices = resources/'Notices'; notices.mkdir()
shutil.copy2(source/'THIRD-PARTY.txt', notices/'THIRD-PARTY.txt')
pyusb = importlib.metadata.distribution('pyusb')
for file in pyusb.files or []:
    if str(file).endswith('.dist-info/LICENSE'):
        shutil.copy2(pyusb.locate_file(file), notices/'PyUSB-LICENSE.txt')
if (libusb.parent.parent/'COPYING').exists():
    shutil.copy2(libusb.parent.parent/'COPYING', notices/'libusb-COPYING.txt')
python_license = Path(sys.base_prefix)/'lib/python3.12/LICENSE.txt'
if python_license.exists(): shutil.copy2(python_license, notices/'Python-LICENSE.txt')
pyinstaller = importlib.metadata.distribution('pyinstaller')
for file in pyinstaller.files or []:
    if str(file).endswith('/COPYING.txt'):
        shutil.copy2(pyinstaller.locate_file(file), notices/'PyInstaller-COPYING.txt')
run('codesign', '--force', '--deep', '--sign', '-', app)
run('codesign', '--verify', '--deep', '--strict', app)
run(resources/'backend/dbi-worker', '--self-check')
print(app)
if make_dmg:
    dmg = destination / f'SwitchTransfer-{version}-macOS26-arm64.dmg'
    staging = build / 'dmg'
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    run('ditto', app, staging / app.name)
    (staging / 'Applications').symlink_to('/Applications')
    dmg.unlink(missing_ok=True)
    run('hdiutil', 'create', '-volname', f'Switch 传输助手 {version}', '-srcfolder', staging,
        '-fs', 'HFS+', '-format', 'UDZO', '-ov', dmg)
    shutil.rmtree(staging)
    print(dmg)
