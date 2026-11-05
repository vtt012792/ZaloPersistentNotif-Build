#!/bin/bash
# Test v1.2.2 (Roothide) truoc khi gui. Chay: bash test_v2.sh
# FAIL o bat ky buoc nao -> dung lai, sua roi chay lai.
set -u
cd "$(dirname "$0")"
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== 1. Code cu v1.0.0 phai bien mat hoan toan =="
# Luu y: "withdrawBulletinWithPublisherBulletinID:" KHONG con cam tu v1.2,
# vi no la selector THAT cua BBDataProviderProxy/BBRemoteDataProvider o daemon
# (v1.0 hook sai no len BBServer - cai do moi la loi). Chi cam cac pattern sau:
for pat in "callStackSymbols" "removeNotificationRequestWithIdentifier" "ZKL_ShouldBlockSpringBoardRemoval" "StackContains"; do
  if grep -q "$pat" Tweak.m; then bad "con sot pattern v1: $pat"; else ok "khong con: $pat"; fi
done
# Dam bao selector withdraw cua daemon khong bi hook len BBServer
grep -A2 'objc_getClass("BBServer")' Tweak.m | grep -q "withdrawBulletinWithPublisherBulletinID" && bad "van hook withdraw len BBServer (loi v1)" || ok "khong hook withdraw len BBServer"

echo "== 2. Selector v2 phai co trong source =="
for sel in "shouldDismissNotification" "shouldDismissBulletin" "postNotificationWithRequest:" "addNotificationRequest:" "removeNotificationRequest:" "withdrawNotificationWithRequest:" "withdrawBulletinRequestsWithPublisherBulletinID:forSectionID:" "withdrawBulletinID:" "executeAction:fromOrigin:withParameters:completion:" "destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:" "destination:requestsClearingNotificationRequests:" "removeNotificationRequest:forCoalescedNotification:" "removeBulletins:inSection:" "removeBulletins:inSection:fromFeed:" "clearBulletins:inSection:" "sendResponse:" "_queue_withdrawBulletinForNotification:" "withdrawBulletinWithPublisherBulletinID:"; do
  if grep -q "$sel" Tweak.m; then ok "selector: $sel"; else bad "thieu selector: $sel"; fi
done
# v1.2 phai co re-add + daemon branch, khong duoc chi hook SpringBoard
grep -q "ZKL_ScheduleReadd" Tweak.m && ok "co re-add (lop C)" || bad "thieu re-add"
grep -q "usernotificationsd" Tweak.m && ok "co daemon branch" || bad "thieu daemon branch"
grep -q "getprogname" Tweak.m && ok "nhan dien process bang getprogname" || bad "thieu getprogname"

echo "== 3. Build sach =="
rm -rf build packages
bash build.sh > /tmp/build_v2.log 2>&1
if [ -f packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb ]; then ok "build ra .deb 1.2.2"; else bad "khong ra .deb"; cat /tmp/build_v2.log | tail -n 30; fi

DYLIB=build/ZaloKeepNotif.dylib
echo "== 4. Kiem tra dylib =="
lipo -info "$DYLIB" 2>/dev/null | grep -q "arm64" && ok "arch arm64" || bad "arch khong phai arm64"
llvm-objdump-18 --macho --all-headers "$DYLIB" | grep -A5 "LC_BUILD_VERSION" | grep -q "minos 16.1" && ok "minos 16.1" || bad "minos khong phai 16.1"
llvm-objdump-18 --macho --all-headers "$DYLIB" | grep -q "LC_CODE_SIGNATURE" && ok "co LC_CODE_SIGNATURE (adhoc)" || bad "thieu LC_CODE_SIGNATURE"
llvm-objdump-18 --macho --all-headers "$DYLIB" | grep -q "__mod_init_func" && ok "co constructor (__mod_init_func)" || bad "thieu constructor"
for sym in ZKL_ncShouldDismiss ZKL_bbShouldDismiss ZKL_dispPost ZKL_storeAdd ZKL_storeRemove ZKL_runnerExecute ZKL_dispExecute ZKL_MutateRequestForZalo ZKL_ScheduleReadd ZKL_ReaddRequest ZKL_obsRemove ZKL_unsWithdraw ZKL_proxyWithdraw ZKL_HookUserNotificationsDaemon; do
  llvm-nm-18 "$DYLIB" 2>/dev/null | grep -q "$sym" && ok "symbol $sym" || bad "thieu symbol $sym"
done
echo "== 5. Selector v2 phai co trong binary (strings / __objc_methname) =="
METH=$(strings "$DYLIB")
for sel in "shouldDismissNotification" "shouldDismissBulletin" "postNotificationWithRequest" "removeNotificationRequest" "withdrawBulletinRequestsWithPublisherBulletinID" "withdrawBulletinID"; do
  echo "$METH" | grep -q "$sel" && ok "binary co $sel" || bad "binary thieu $sel"
done
strings "$DYLIB" | grep -q "removeNotificationRequestWithIdentifier" && bad "binary con sot selector v1" || ok "binary khong con selector v1"

echo "== 6. Kiem tra .deb =="
dpkg-deb --contents packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb > /tmp/debcontents.txt 2>/dev/null
grep -q "var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.dylib" /tmp/debcontents.txt && ok "deb co dylib rootless" || bad "deb thieu dylib"
grep -q "ZaloKeepNotif.plist" /tmp/debcontents.txt && ok "deb co plist" || bad "deb thieu plist"
dpkg-deb --info packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb | grep -q "Version: 1.2.2" && ok "deb version 1.2.2" || bad "deb version sai"
mkdir -p /tmp/debcheck2 && dpkg-deb -x packages/com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb /tmp/debcheck2
grep -q "com.zing.zalo" /tmp/debcheck2/var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.plist && grep -q "com.apple.springboard" /tmp/debcheck2/var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.plist && ok "plist filter Zalo + SpringBoard" || bad "plist filter sai"
grep -q "usernotificationsd" /tmp/debcheck2/var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.plist && grep -q "Executables" /tmp/debcheck2/var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.plist && ok "plist co Executables=usernotificationsd" || bad "plist thieu Executables daemon"

echo "== 7. Logic test (mo phong dung luat trong Tweak.m) =="
python3 - <<'PYEOF'
import sys
TAP_WINDOW = 3.0
def tapped_recently(last_tap, now):
    return last_tap is not None and (now - last_tap) < TAP_WINDOW
def should_block_remove(section, last_tap, now):
    return section == "com.zing.zalo" and tapped_recently(last_tap, now)
def should_dismiss(bid, destructive, orig):
    return False if (bid == "com.zing.zalo" and not destructive) else orig
def clearing_filter(requests, last_tap, now):
    # requests: list of (section, id)
    if not tapped_recently(last_tap, now):
        return requests, False
    kept = [r for r in requests if r[0] != "com.zing.zalo"]
    return kept, len(kept) != len(requests)
cases = []
# (ten, ket_qua, ky_vong)
cases.append(("tap 1s + Zalo remove -> BLOCK", should_block_remove("com.zing.zalo", 100.0, 101.0), True))
cases.append(("khong tap + Zalo remove -> ALLOW (vuot xoa)", should_block_remove("com.zing.zalo", None, 101.0), False))
cases.append(("tap 10s truoc + Zalo remove -> ALLOW", should_block_remove("com.zing.zalo", 100.0, 110.0), False))
cases.append(("tap 1s + app khac remove -> ALLOW", should_block_remove("com.apple.mobilesms", 100.0, 101.0), False))
cases.append(("tap dung 3.0s -> ALLOW (het cua so)", should_block_remove("com.zing.zalo", 100.0, 103.0), False))
cases.append(("shouldDismiss Zalo default -> NO", should_dismiss("com.zing.zalo", False, True), False))
cases.append(("shouldDismiss Zalo clear (destructive) -> giu YES", should_dismiss("com.zing.zalo", True, True), True))
cases.append(("shouldDismiss app khac -> giu YES", should_dismiss("com.apple.mobilesms", False, True), True))
kept, filt = clearing_filter([("com.zing.zalo","z1"),("com.apple.mobilesms","s1")], 100.0, 101.0)
cases.append(("clearing trong tap window: loc Zalo, giu SMS", (kept, filt), ([("com.apple.mobilesms","s1")], True)))
kept2, filt2 = clearing_filter([("com.zing.zalo","z1")], None, 101.0)
cases.append(("clearing khong tap: giu nguyen", (kept2, filt2), ([("com.zing.zalo","z1")], False)))
fails = 0
for name, got, want in cases:
    if got == want:
        print(f"PASS: {name}")
    else:
        print(f"FAIL: {name} got={got} want={want}"); fails += 1
sys.exit(1 if fails else 0)
PYEOF
[ $? -eq 0 ] && ok "logic test 10/10 case" || bad "logic test co case fail"

echo "== 8. May ao mo phong flow iOS day du (sim/sim_ios.py) =="
python3 sim/sim_ios.py > /tmp/sim.log 2>&1
if [ $? -eq 0 ]; then ok "sim 9/9 scenario (v1.2 tap giu, v1.1 tap mat, swipe/clear-all van mat)"; else bad "sim co scenario fail"; cat /tmp/sim.log; fi
grep -q "daemon: BLOCKED UNS.withdraw Zalo" /tmp/sim.log && ok "sim: daemon withdraw bi chan" || bad "sim: khong thay daemon block"

echo ""
echo "== TONG KET: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] && echo "ALL PASS - duoc phep gui" || echo "CO FAIL - chua duoc gui"
exit $FAIL
