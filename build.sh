#!/bin/bash
# Build ZaloKeepNotif .deb trên Linux (Ubuntu) bằng clang + iPhoneOS SDK.
# Đã test trên Ubuntu 24.04, clang 18, SDK 16.5, target iOS 16.1 Roothide rootless.
# Cách dùng: bash build.sh   -> ra packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb
set -euo pipefail
cd "$(dirname "$0")"

SDK_DIR="${SDK_DIR:-$PWD/../sdks/iPhoneOS16.5.sdk}"
if [ ! -d "$SDK_DIR" ]; then
  echo "Chua co SDK, dang tai iPhoneOS16.5.sdk ..."
  mkdir -p ../sdks
  git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git ../sdks
  (cd ../sdks && git sparse-checkout set iPhoneOS16.5.sdk)
fi

mkdir -p build packages
echo "== Compile Tweak.m (arm64, iOS 16.1 min) =="
# Chi build arm64 (khong dual arm64+arm64e: llvm-lipo tren Linux coi 2 arch
# nay la trung nhau va fail; arm64 chay binh thuong tren may arm64e A12+).
clang -target arm64-apple-ios16.1 \
  -isysroot "$SDK_DIR" \
  -arch arm64 \
  -fobjc-arc \
  -framework Foundation -framework UIKit -framework UserNotifications \
  -dynamiclib \
  -install_name "@rpath/ZaloKeepNotif.dylib" \
  -o build/ZaloKeepNotif.dylib Tweak.m \
  -fuse-ld=lld

echo "== Kiem tra dylib =="
lipo -info build/ZaloKeepNotif.dylib 2>/dev/null || llvm-lipo-18 -info build/ZaloKeepNotif.dylib 2>/dev/null || true

echo "== Sign adhoc (ldid neu co, neu khong thi zsign) =="
# zsign sign in-place cho file dylib (khong dung -o), ldid thi -S.
if command -v ldid >/dev/null 2>&1; then
  ldid -S build/ZaloKeepNotif.dylib && echo "signed with ldid"
elif command -v zsign >/dev/null 2>&1; then
  zsign -a -f build/ZaloKeepNotif.dylib && echo "signed with zsign"
elif [ -x ../zsign-src/bin/zsign ]; then
  ../zsign-src/bin/zsign -a -f build/ZaloKeepNotif.dylib && echo "signed with local zsign"
else
  echo "CANH BAO: khong tim thay ldid/zsign tren may nay, dylib chua sign."
  echo "Tren iPhone Roothide, ElleKit can dylib co adhoc signature."
  echo "Cai ldid (Procursus) hoac build zsign (xem README) roi chay lai build.sh."
fi

echo "== Dong goi .deb rootless (Roothide: /var/jb/...) =="
PKGDIR=build/pkgroot
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR/var/jb/Library/MobileSubstrate/DynamicLibraries" "$PKGDIR/DEBIAN"
cp build/ZaloKeepNotif.dylib "$PKGDIR/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp ZaloKeepNotif.plist "$PKGDIR/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp control "$PKGDIR/DEBIAN/control"
chmod 755 "$PKGDIR" "$PKGDIR/DEBIAN" "$PKGDIR/var" "$PKGDIR/var/jb" "$PKGDIR/var/jb/Library" "$PKGDIR/var/jb/Library/MobileSubstrate" "$PKGDIR/var/jb/Library/MobileSubstrate/DynamicLibraries"
chmod 644 "$PKGDIR/DEBIAN/control" "$PKGDIR/var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.plist"
chmod 755 "$PKGDIR/var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.dylib"
# control trong deb khong duoc co ky tu tieng Viet co dau o Description (de tranh loi dpkg), file control goc da de khong dau.
dpkg-deb --build "$PKGDIR" packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb
echo "== Xong =="
ls -lh packages/
dpkg-deb --contents packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb
dpkg-deb --info packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb
