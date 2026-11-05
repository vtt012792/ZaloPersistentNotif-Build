# ZaloKeepNotif 1.2.2 (Roothide)

> v1.2.2 = code hook giống hệt v1.2.1, chỉ hạ min iOS xuống 16.1 để chạy được trên iOS 16.1.1, target Roothide.

Giữ thông báo Zalo trên lockscreen khi nhấn mở app, không đổi thứ tự,
chỉ mất khi người dùng tự vuốt/xóa.

- iOS 16.1.1, **Roothide** (rootless, dựa trên Dopamine), Zalo mới nhất
- Package: `com.vtt012792.zalokeepnotif`, arch `iphoneos-arm64`
- 1 dylib duy nhất, inject vào `com.zing.zalo`, `com.apple.springboard`
  và daemon `usernotificationsd`
- Code hook giống hệt 1.2.1, chỉ đổi sang build cho Roothide
  (`THEOS_PACKAGE_SCHEME = roothide`). Đường dẫn vẫn là
  `var/jb/Library/MobileSubstrate/DynamicLibraries/` như Dopamine
  rootless, vì Roothide cũng dùng /var/jb và ElleKit.

## Lưu ý riêng Roothide

- Cài bằng Sileo trên Roothide như bản rootless bình thường.
- Roothide ẩn jailbreak khỏi app (root hide) nhưng tweak vẫn được
  inject qua ElleKit, code hook không đổi.
- Sau khi cài + respring, nếu noti vẫn mất, kiểm tra trong app
  Roothide xem tweak injection có bật cho Zalo và SpringBoard không.
  Daemon `usernotificationsd` cũng cần load lại dylib: chạy
  `killall usernotificationsd` (daemon tự khởi động lại) hoặc reboot.
- Kiểm tra log theo mục Log / debug dưới đây: phải thấy đủ 3 dòng
  load (SpringBoard, Zalo, usernotificationsd). Thiếu dòng nào thì
  đường đó chưa được inject trên Roothide, gửi log cho mình.

## Vì sao 1.1.0 vẫn mất khi nhấn

Nhấn noti không chỉ đi qua SpringBoard. Flow thật trên iOS 16:

```
SpringBoard NC list -> NCBulletinActionRunner.executeAction
  -> BBObserver.sendResponse: (BBResponse)
  -> BBServer -> XPC -> usernotificationsd
       UNSDefaultDataProvider.handleBulletinActionResponse:
  -> _queue_withdrawBulletinForNotification:
  -> BBDataProviderProxy.withdrawBulletinWithPublisherBulletinID:
  -> XPC -> BBServer.withdrawBulletinID: / removeBulletin:
  -> BBObserver._queue_updateRemoveBulletin:
  -> NCNotificationDispatcher.withdraw / NCNotificationStore.remove
```

1.1.0 chỉ inject vào Zalo + SpringBoard, nên đường rút ở
`usernotificationsd` (daemon, không có bundleIdentifier, phải filter
bằng `Executables`) hoàn toàn không bị chặn. Ngoài ra cờ
`shouldDismiss` có 2 bản sao: 1 ở SpringBoard (NCNotificationAction)
và 1 ở daemon (BBAction, tạo từ UNNotification). 1.1.0 chỉ lật bản
sao SpringBoard, bản sao daemon vẫn YES nên daemon vẫn rút.

## Cách 1.2.2 hoạt động (5 lớp, giữ nguyên A+B của 1.1.0)

- **Lớp A:** lật cờ shouldDismiss -> NO cho noti Zalo lúc post và lúc
  chạy action (NCNotificationAction / BBAction).
- **Lớp B:** cửa sổ tap 3 giây: chỉ trong 3s sau nhấn mới chặn
  remove/withdraw Zalo ở SpringBoard (store, dispatcher, BBServer,
  list UI, BBObserver.remove/clearBulletins).
- **Lớp C (mới): RE-ADD.** Lưu lại request gốc lúc post (giữ nguyên
  notificationIdentifier và timestamp nên giữ nguyên thứ tự). Khi
  nhấn xong, đăng lại chính request đó vào store ở 0.5s và 1.5s.
  Đăng lại cùng identifier sẽ replace, không tạo bản sao, không nhảy
  thứ tự. Vuốt xóa / clear-all không có lần nhấn trước đó nên không
  re-add. Lớp này là lưới cuối: dù đường rút nào lọt qua thì noti
  vẫn được đăng lại.
- **Lớp D (mới): inject vào `usernotificationsd`.** Chặn withdraw ở
  `UNSDefaultDataProvider._queue_withdrawBulletinForNotification:`,
  `BBDataProviderProxy.withdrawBulletinWithPublisherBulletinID:` và
  `BBRemoteDataProvider.withdrawBulletinWithPublisherBulletinID:` —
  mỗi provider instance là của 1 app nên
  `[self sectionIdentifier] == com.zing.zalo` là đủ để nhận diện.
  Vuốt xóa ở lockscreen đi qua BBServer trực tiếp, không qua đường
  này, nên không ảnh hưởng vuốt xóa.
- **Lớp E (mới):** SpringBoard chặn thêm
  `BBObserver.removeBulletins:inSection:`,
  `removeBulletins:inSection:fromFeed:`,
  `clearBulletins:inSection:` và ghi nhận tap ở `sendResponse:`.

Không re-post noti mới. Re-add ở lớp C dùng đúng request gốc nên
timestamp không đổi, khác với tạo noti mới.

## Cài đặt (.deb)

1. Gỡ bản 1.1.0 cũ trong Sileo trước (nếu đã cài).
2. Import file `com.vtt012792.zalokeepnotif_1.2.2_iphoneos-arm64.deb`
   vào Sileo, cài, rồi respring.
3. Sau respring, daemon `usernotificationsd` cũng cần load lại dylib:
   nếu noti vẫn mất, chạy thêm `killall usernotificationsd` (daemon
   tự khởi động lại) rồi test lại. Hoặc reboot máy.
4. Mở Zalo một lần, khóa màn hình, test theo checklist dưới.

Đường dẫn trong .deb (rootless Dopamine):

```
var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.dylib
var/jb/Library/MobileSubstrate/DynamicLibraries/ZaloKeepNotif.plist
```

Filter trong plist:

```
Bundles = ( "com.zing.zalo", "com.apple.springboard" );
Executables = ( "usernotificationsd", "SpringBoard" );
```

## Test

1. Nhờ người khác gửi 2 tin Zalo, khóa màn hình — thấy 2 noti đúng thứ tự.
2. Nhấn vào noti thứ 2 để mở Zalo, khóa lại — cả 2 noti vẫn còn, không nhảy vị trí.
3. Vuốt trái 1 noti để xóa — chỉ noti đó mất.
4. Gửi tin thứ 3 — noti mới xếp cuối, không đẩy noti cũ lên đầu.
5. Nhấn "Xóa tất cả" ở Notification Center — noti Zalo mất như bình thường
   (chỉ khi không vừa nhấn mở app xong).

## Log / debug

Tweak ghi log bằng `NSLog` với tag `[ZaloKeepNotif]`, xem bằng:

```
log stream --predicate 'process == "SpringBoard" OR process == "Zalo" OR process == "usernotificationsd"' --info | grep ZaloKeepNotif
```

Phải thấy 3 dòng load, mỗi process 1 dòng:

- `loaded in bid=com.apple.springboard ... (v1.2.2)` rồi dòng
  `SpringBoard: hooks NCAction=1 BBAction=1 dispPost=1 storeAdd=1
  runner=1 dispExec=1 storeRemove=1 dispWithdraw=1 bbReqs=1 bbID=1
  clearing=1 listRemove=1 obsRemove=1 obsRemoveFeed=1 obsClear=1
  obsSendResp=1`
- `loaded in bid=com.zing.zalo ... (v1.2.2)` rồi
  `Zalo: hook removeAll=1 removeIDs=1`
- `loaded in bid= prog=usernotificationsd ... (v1.2.2)` rồi
  `usernotificationsd: hooks unsWithdraw=1 proxyWithdraw=1 remoteWithdraw=1`

Khi nhấn noti Zalo phải thấy `TAP Zalo ...`, `daemon: BLOCKED
UNS.withdraw Zalo ...` và `RE-ADD Zalo req ...`. Số nào = 0 hoặc
thiếu dòng nào thì gửi toàn bộ log cho mình, em chỉnh tiếp theo đúng
máy anh.

## Test đã làm trước khi gửi (test_v2.sh, 60/60 PASS + sim 9/9)

- Code v1.0.0 (call-stack, selector remove/withdraw sai) đã biến mất hẳn.
- 19 selector v1.2 có trong source và trong binary đã build, đủ symbol
  của 16 hook SpringBoard + 3 hook daemon + re-add.
- Build sạch từ đầu, dylib arm64, min iOS 16.1, có `LC_CODE_SIGNATURE`
  adhoc, có constructor.
- .deb 1.2.2 đúng đường dẫn rootless, plist filter Zalo + SpringBoard
  + Executables=usernotificationsd.
- Logic test 10/10 case (tap window, shouldDismiss, clear-all lọc đúng).
- **Máy ảo mô phỏng flow iOS (`sim/sim_ios.py`, 9/9 scenario):**
  v1.2 tap -> giữ cả 2 noti, giữ thứ tự; v1.1 tap -> mất (tái hiện đúng
  lỗi anh gặp); v1.2 vuốt xóa -> chỉ mất cái vuốt; clear-all -> mất
  hết; tap rồi gửi tin mới -> tin mới xếp cuối; tap 2 lần -> không
  nhân đôi; tap SMS -> SMS mất như thường, Zalo còn.

Lưu ý thẳng: trên Linux không có iOS simulator / máy ảo iPhone thật
(Apple chỉ cho chạy trên macOS, không có qemu iOS), nên phần "máy ảo"
là mô phỏng flow đầy đủ bằng Python với đúng 2 bản sao shouldDismiss
và đúng các đường rút qua daemon — không phải iPhone thật. Chốt cuối
cùng vẫn là log trên máy anh ở trên.

## Build lại

Trên Linux (đã test Ubuntu 24.04, clang 18):

```
bash build.sh
bash test_v2.sh   # phải ALL PASS mới gửi
```

Cần: clang, lld, dpkg-dev, iPhoneOS16.5.sdk (tự tải từ theos/sdks),
và `ldid` hoặc `zsign` để sign adhoc. Hoặc push lên GitHub, workflow
`.github/workflows/build.yml` sẽ build và up .deb lên Artifacts.

Build bằng Theos trên máy/macOS cũng được: `make package`
(`ARCHS = arm64 arm64e`, `THEOS_PACKAGE_SCHEME = roothide`).
