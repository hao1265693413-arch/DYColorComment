#!/usr/bin/env python3
# 本地打 deb（不依赖 CI）：给 TrollFools / Filza 用的探针包
import hashlib, os, pathlib, shutil, subprocess, sys

VERSION = "0.1.0~probe5"
PKG = "com.ahao.dycolorcomment"
WORK = pathlib.Path("/tmp/dycolor-pkg")
SRC = pathlib.Path("/var/minis/attachments/DYColorComment/DYColorComment.dylib")
OUT = pathlib.Path("/var/minis/attachments/DYColorComment")

if WORK.exists():
    shutil.rmtree(WORK)
root = WORK / "root"
libdir = root / "Library/MobileSubstrate/DynamicLibraries"
libdir.mkdir(parents=True)
shutil.copy(SRC, libdir / "DYColorComment.dylib")

(libdir / "DYColorComment.plist").write_text(
    '{\n'
    '    Filter = {\n'
    '        Bundles = (com.ss.iphone.ugc.Aweme);\n'
    '    };\n'
    '}\n',
    encoding="utf-8",
)

debian = root / "DEBIAN"
debian.mkdir()
control = f"""Package: {PKG}
Name: 抖音评论黄字（探针）
Version: {VERSION}
Architecture: iphoneos-arm64
Description: 记录抖音评论提交时的数据结构，用于定位彩色评论落点。不改任何请求。TrollFools 可直接注入。
Maintainer: AHao
Author: AHao
Section: Tweaks
Depends: firmware (>= 15.0)
"""
(debian / "control").write_text(control, encoding="utf-8")

deb = OUT / f"{PKG}_{VERSION}_iphoneos-arm64.deb"
if deb.exists():
    deb.unlink()
subprocess.run(["dpkg-deb", "-Z", "gzip", "--build", "--root-owner-group", str(root), str(deb)], check=True)

print("built", deb, deb.stat().st_size)
print("sha256", hashlib.sha256(deb.read_bytes()).hexdigest())
print("--- ar ---")
subprocess.run(["ar", "t", str(deb)], check=True)
print("--- data.tar ---")
data = subprocess.check_output(["dpkg-deb", "-c", str(deb)], text=True)
print(data)
print("--- control ---")
print(subprocess.check_output(["dpkg-deb", "-I", str(deb)], text=True))