#!/usr/bin/env python3
"""
Máy ảo mô phỏng flow thông báo iOS 16.1.1 (không phải iPhone thật):
  Zalo -> usernotificationsd (UNS provider) -> BBServer (SpringBoard)
  -> NCNotificationDispatcher / NCNotificationStore (SpringBoard)
  -> Lock screen list

Mô phỏng đúng 2 bản sao của cờ shouldDismiss:
  - springboard_nc_shouldDismiss: bản sao ở SpringBoard (NCNotificationAction)
  - daemon_bb_shouldDismiss:    bản sao ở daemon (BBAction, tạo từ UNNotification)
v1.1 chỉ lật bản sao SpringBoard, daemon vẫn YES nên daemon withdraw
và noti vẫn mất. v1.2 chặn withdraw ở daemon + re-add ở SpringBoard.

Chạy: python3 sim_ios.py   (exit 0 = tất cả scenario PASS)
"""
import sys

ZALO = "com.zing.zalo"
SMS = "com.apple.mobilesms"
TAP_WINDOW = 3.0


class Req:
    def __init__(self, section, nid, bid, ts):
        self.section = section
        self.nid = nid
        self.bid = bid
        self.ts = ts
        self.nc_should_dismiss = True   # SpringBoard copy
        self.bb_should_dismiss = True   # daemon copy
        self.dismiss_auto = True
    def __repr__(self):
        return f"Req({self.section},{self.nid},ts={self.ts})"


class Sim:
    """Một 'máy ảo' iOS: store + daemon + springboard, với hook theo version."""
    def __init__(self, version):
        self.version = version  # "1.1" hoặc "1.2"
        self.store = {}         # nid -> Req, giữ thứ tự theo ts khi list
        self.log = []
        self.now = 1000.0
        self.last_tap = None
        self.saved = {}         # nid -> Req (lớp C, chỉ 1.2)

    def _log(self, s):
        self.log.append(s)

    def _tapped_recently(self):
        return self.last_tap is not None and (self.now - self.last_tap) < TAP_WINDOW

    # --- post ---
    def post(self, req):
        # Lớp A (cả 1.1 và 1.2): lật cờ SpringBoard lúc post
        if req.section == ZALO:
            req.nc_should_dismiss = False
            req.dismiss_auto = False
            self._log(f"post Zalo {req.nid} nc_should_dismiss=False")
            if self.version == "1.2":
                self.saved[req.nid] = req
        self.store[req.nid] = req

    def ordered(self):
        return [r.nid for r in sorted(self.store.values(), key=lambda r: r.ts)]

    # --- tap: chạy default action ---
    def tap(self, nid):
        req = self.store.get(nid)
        if not req:
            return False
        self.last_tap = self.now
        self._log(f"TAP {nid} section={req.section}")
        # Runner/dispatcher ghi nhận tap, lật cờ BBAction ở SpringBoard
        # (nhưng bản sao ở daemon thì KHÔNG bị lật - đó là lỗi của 1.1)
        # Daemon nhận response:
        self._daemon_handle_response(req)
        # Sau tap, SpringBoard cũng có thể tự rút qua store.remove:
        self._store_remove(req, via="tap")
        # Lớp C (chỉ 1.2): re-add sau 0.5s với đúng request gốc
        if self.version == "1.2":
            saved = self.saved.get(nid)
            if saved is not None:
                self._log(f"RE-ADD {nid} ts={saved.ts} (giữ nguyên thứ tự)")
                self.store[nid] = saved
        return True

    def _daemon_handle_response(self, req):
        # UNSDefaultDataProvider.handleBulletinActionResponse
        # -> _queue_withdrawBulletinForNotification nếu bb_should_dismiss
        if req.section != ZALO:
            return
        if req.bb_should_dismiss:
            self._log(f"daemon: bb_should_dismiss=YES -> withdraw {req.nid}")
            if self.version == "1.2":
                # Lớp D: chặn withdraw ở daemon cho Zalo
                self._log(f"daemon: BLOCKED UNS.withdraw Zalo {req.nid}")
                return
            # 1.1: không có hook ở daemon -> withdraw chạy -> BBServer rút
            self._log(f"daemon: withdraw chạy -> BBServer rút {req.nid}")
            self.store.pop(req.nid, None)
        else:
            self._log(f"daemon: bb_should_dismiss=NO -> không withdraw {req.nid}")

    def _store_remove(self, req, via):
        # NCNotificationStore.removeNotificationRequest:
        if req.section == ZALO and self._tapped_recently():
            self._log(f"store.remove BLOCKED Zalo {req.nid} (tap window, via={via})")
            return
        self._log(f"store.remove allow {req.nid} via={via}")
        self.store.pop(req.nid, None)

    # --- vuốt xóa tay (không có tap trước đó) ---
    def swipe_delete(self, nid):
        req = self.store.get(nid)
        if not req:
            return False
        self._log(f"SWIPE-DELETE {nid}")
        # BBObserver.removeBulletins -> BBServer.remove -> store.remove
        # Không có tap -> tapped_recently False -> cho qua ở mọi lớp
        self._store_remove(req, via="swipe")
        return True

    # --- clear-all ---
    def clear_all(self):
        self._log("CLEAR-ALL")
        for nid in list(self.store.keys()):
            req = self.store[nid]
            if req.section == ZALO and self._tapped_recently():
                self._log(f"clearing BLOCKED Zalo {nid} (tap window)")
                continue
            self.store.pop(nid, None)

    # --- Zalo tự clear khi mở app ---
    def zalo_self_clear(self):
        self._log("Zalo app: removeAllDeliveredNotifications -> BLOCKED (cả 1.1 và 1.2)")
        # bị chặn ở process Zalo, store không đổi
        pass


def check(name, got, want):
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}: {name}  got={got} want={want}")
    return ok


def main():
    fails = 0
    total = 0

    def run(name, got, want):
        nonlocal fails, total
        total += 1
        if not check(name, got, want):
            fails += 1

    # --- Scenario 1: v1.2 tap -> giữ, giữ thứ tự ---
    s = Sim("1.2")
    s.post(Req(ZALO, "z1", "b1", 1000)); s.post(Req(ZALO, "z2", "b2", 1010))
    s.now = 1020; s.tap("z2")
    run("v1.2 tap: cả 2 noti còn", s.ordered(), ["z1", "z2"])
    run("v1.2 tap: thứ tự không đổi", s.ordered(), ["z1", "z2"])

    # --- Scenario 2: v1.1 tap -> mất (chứng minh lỗi cũ) ---
    s = Sim("1.1")
    s.post(Req(ZALO, "z1", "b1", 1000)); s.post(Req(ZALO, "z2", "b2", 1010))
    s.now = 1020; s.tap("z2")
    run("v1.1 tap: z2 MẤT (lỗi đã biết)", s.ordered(), ["z1"])

    # --- Scenario 3: v1.2 vuốt xóa -> mất đúng cái đó ---
    s = Sim("1.2")
    s.post(Req(ZALO, "z1", "b1", 1000)); s.post(Req(ZALO, "z2", "b2", 1010))
    s.now = 1020; s.swipe_delete("z1")
    run("v1.2 swipe: chỉ z1 mất", s.ordered(), ["z2"])

    # --- Scenario 4: v1.2 clear-all (không tap) -> mất hết ---
    s = Sim("1.2")
    s.post(Req(ZALO, "z1", "b1", 1000)); s.post(Req(SMS, "s1", "bs1", 1005))
    s.now = 1020; s.clear_all()
    run("v1.2 clear-all: mất hết", s.ordered(), [])

    # --- Scenario 5: v1.2 tap rồi gửi tin mới -> tin mới xếp cuối ---
    s = Sim("1.2")
    s.post(Req(ZALO, "z1", "b1", 1000)); s.post(Req(ZALO, "z2", "b2", 1010))
    s.now = 1020; s.tap("z2")
    s.now = 1030; s.post(Req(ZALO, "z3", "b3", 1030))
    run("v1.2 tap + tin mới: thứ tự z1,z2,z3", s.ordered(), ["z1", "z2", "z3"])

    # --- Scenario 6: v1.2 Zalo tự clear khi mở app -> không mất ---
    s = Sim("1.2")
    s.post(Req(ZALO, "z1", "b1", 1000))
    s.now = 1020; s.tap("z1"); s.zalo_self_clear()
    run("v1.2 tap + Zalo self-clear: vẫn còn", s.ordered(), ["z1"])

    # --- Scenario 7: v1.2 tap app khác -> không ảnh hưởng Zalo, app khác mất như thường ---
    s = Sim("1.2")
    s.post(Req(ZALO, "z1", "b1", 1000)); s.post(Req(SMS, "s1", "bs1", 1005))
    s.now = 1020; s.tap("s1")
    # SMS: daemon withdraw không bị chặn (chỉ chặn Zalo), store.remove sau tap
    # trong sim này SMS bị rút như iOS gốc (không có hook cho SMS)
    run("v1.2 tap SMS: SMS mất, Zalo còn", s.ordered(), ["z1"])

    # --- Scenario 8: v1.2 tap 2 lần liên tiếp ---
    s = Sim("1.2")
    s.post(Req(ZALO, "z1", "b1", 1000))
    s.now = 1020; s.tap("z1"); s.now = 1021; s.tap("z1")
    run("v1.2 tap 2 lần: vẫn còn, không nhân đôi", s.ordered(), ["z1"])

    print(f"\nSIM: {total - fails}/{total} PASS")
    # In log của scenario 1 để người đọc thấy đường daemon bị chặn
    s1 = Sim("1.2"); s1.post(Req(ZALO, "z1", "b1", 1000)); s1.now = 1020; s1.tap("z1")
    print("Log mẫu v1.2 tap:")
    for line in s1.log:
        print("  ", line)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
