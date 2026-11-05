// ZaloKeepNotif 1.2.2 (Roothide)
// iOS 16.1.1, Roothide (rootless, dựa trên Dopamine), Zalo mới nhất
// Mục tiêu: noti Zalo ở lockscreen KHÔNG mất khi nhấn mở app,
// không đổi thứ tự, chỉ mất khi người dùng tự vuốt/xóa.
//
// --- Vì sao 1.1.0 vẫn mất khi nhấn (phân tích lại toàn bộ flow) ---
// Nhấn noti không chỉ đi qua SpringBoard. Flow thật trên iOS 16:
//   SpringBoard NC list -> NCBulletinActionRunner.executeAction
//     -> BBObserver.sendResponse: (BBResponse)
//     -> BBServer._didReceiveResponseForBulletin:
//     -> XPC -> usernotificationsd UNSDefaultDataProvider
//        .handleBulletinActionResponse:
//     -> _queue_withdrawBulletinForNotification:
//     -> BBDataProviderProxy.withdrawBulletinWithPublisherBulletinID:
//     -> XPC -> BBServer.withdrawBulletinID: / removeBulletin:
//     -> BBObserver._queue_updateRemoveBulletin:
//     -> NCNotificationDispatcher.withdraw / NCNotificationStore.remove
// 1.1.0 chỉ inject vào Zalo + SpringBoard, nên đường rút ở
// usernotificationsd (daemon, không có bundleIdentifier, phải filter
// bằng Executables) hoàn toàn không bị chặn. Đó là đường còn sót.
// Ngoài ra, chặn (block) không phải lúc nào cũng đủ: nếu 1 đường rút
// nào đó không qua hook, noti vẫn mất. Vì vậy 1.2.0 thêm lớp C:
//   RE-ADD: lưu lại request gốc (giữ nguyên notificationIdentifier
//   và timestamp nên giữ nguyên thứ tự), khi noti bị rút sau 1 lần
//   nhấn thì đăng lại chính request đó vào store. Đăng lại cùng
//   identifier sẽ replace, không tạo bản sao, không nhảy thứ tự.
//   Vuốt xóa / clear-all không có lần nhấn trước đó nên không re-add.
//
// Các lớp của 1.2.0 (giữ nguyên lớp A+B của 1.1.0):
//  (A) Lật cờ shouldDismiss -> NO cho noti Zalo lúc post và lúc chạy action.
//  (B) Cửa sổ tap 3 giây: chỉ trong 3s sau nhấn mới chặn remove/withdraw Zalo.
//  (C) Re-add request gốc sau khi nhấn (0.5s và 1.5s), dùng đúng timestamp gốc.
//  (D) Inject thêm vào usernotificationsd: chặn withdraw ở UNSDefaultDataProvider
//      và BBDataProviderProxy/BBRemoteDataProvider (per-section = Zalo).
//  (E) SpringBoard: chặn thêm BBObserver.remove/clearBulletins:inSection:
//      (đường vuốt/xóa ở UI đi qua đây, nhưng chỉ chặn khi vừa nhấn xong).
//
// File này là Objective-C thuần, KHÔNG dùng Logos/Substrate header,
// chỉ dùng objc/runtime + framework công khai, build được cả bằng Theos
// lẫn clang trực tiếp trên Linux (xem build.sh).
// Lưu ý biên dịch: các receiver đều được ép kiểu về đúng class private đã
// khai báo dưới đây, vì clang sẽ lỗi nếu gọi method private trên receiver
// kiểu id khi có nhiều method cùng tên nhưng khác kiểu trả về.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <stdio.h>

#define ZKL_TAG @"[ZaloKeepNotif]"
#define ZKL_ZALO @"com.zing.zalo"
#define ZKL_TAP_WINDOW 3.0

static void ZKLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@ %@", ZKL_TAG, msg);
}

// ---------- Khai báo tối thiểu cho các class private (chỉ để biên dịch) ----------
@interface NCNotificationAction : NSObject
@property (nonatomic, readonly, copy) NSString *launchBundleID;
@property (nonatomic, readonly) BOOL shouldDismissNotification;
@property (nonatomic, readonly, getter=isDestructiveAction) BOOL destructiveAction;
@property (nonatomic, readonly, copy) NSString *identifier;
@end
@interface NCMutableNotificationAction : NCNotificationAction
@property (nonatomic) BOOL shouldDismissNotification;
@end
@interface NCNotificationOptions : NSObject
@property (nonatomic, readonly) BOOL dismissAutomatically;
@end
@interface NCMutableNotificationOptions : NCNotificationOptions
@property (nonatomic) BOOL dismissAutomatically;
@end
@class BBBulletin;
@interface NCNotificationRequest : NSObject
@property (nonatomic, readonly, copy) NSString *sectionIdentifier;
@property (nonatomic, readonly, copy) NSString *notificationIdentifier;
@property (nonatomic, readonly) NCNotificationAction *defaultAction;
@property (nonatomic, readonly) NCNotificationOptions *options;
@property (nonatomic, readonly) NSDate *timestamp;
@property (nonatomic, readonly) BBBulletin *bulletin;
@end
@interface NCMutableNotificationRequest : NCNotificationRequest
@property (nonatomic, retain) NCNotificationAction *defaultAction;
@property (nonatomic, retain) NCNotificationOptions *options;
@end
@interface BBAction : NSObject
@property (nonatomic, copy) NSString *launchBundleID;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) BOOL shouldDismissBulletin;
@end
@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *publisherBulletinID;
@property (nonatomic, copy) NSString *recordID;
@end
@interface NCBulletinActionRunner : NSObject
@property (nonatomic, readonly) BBAction *action;
@property (nonatomic, readonly) BBBulletin *bulletin;
@end
@interface BBResponse : NSObject
@property (nonatomic, copy) NSString *bulletinID;
@property (nonatomic, copy) NSString *actionID;
@end
@interface BBDataProviderIdentity : NSObject
@property (nonatomic, copy) NSString *sectionIdentifier;
@end
@interface NCNotificationStore : NSObject
- (id)addNotificationRequest:(NCNotificationRequest *)request;
- (id)removeNotificationRequest:(NCNotificationRequest *)request;
@end
@interface BBDataProviderProxy : NSObject
@property (nonatomic, retain) BBDataProviderIdentity *identity;
@end
@interface BBRemoteDataProvider : NSObject
@property (nonatomic, readonly, copy) NSString *sectionIdentifier;
@end
@interface UNSDefaultDataProvider : NSObject
@property (nonatomic, readonly, copy) NSString *sectionIdentifier;
@end

// ---------- Swizzle helper (chỉ swizzle 1 lần / selector) ----------
static BOOL ZKL_Swizzle(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls || !sel || !newIMP) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, newIMP);
    return YES;
}

static void ZKL_LoadFramework(const char *path) {
    void *h = dlopen(path, RTLD_NOW);
    ZKLLog(@"dlopen %s -> %p", path, h);
}

// ---------- Trạng thái tap + request đã lưu (lớp B + C) ----------
static NSTimeInterval ZKL_lastTapTime = 0;
static NSString *ZKL_lastTapBulletinID = nil;
static NSMutableDictionary *ZKL_savedByNotifID = nil;   // notificationIdentifier -> NCNotificationRequest
static NSMutableDictionary *ZKL_savedByBulletinID = nil; // publisherBulletinID -> NCNotificationRequest
static id ZKL_savedStore = nil; // NCNotificationStore instance (SpringBoard)

static BOOL ZKL_TappedRecently(void) {
    if (ZKL_lastTapTime == 0) return NO;
    return ([[NSDate date] timeIntervalSince1970] - ZKL_lastTapTime) < ZKL_TAP_WINDOW;
}
static void ZKL_RecordTap(NSString *bulletinID) {
    ZKL_lastTapTime = [[NSDate date] timeIntervalSince1970];
    ZKL_lastTapBulletinID = [bulletinID copy];
}
static NSString *ZKL_SectionOfRequest(id request) {
    if (!request) return nil;
    NSString *section = nil;
    @try { section = [(NCNotificationRequest *)request sectionIdentifier]; } @catch (NSException *e) {}
    return section;
}
static void ZKL_SaveRequest(NCNotificationRequest *request) {
    if (!request) return;
    if (!ZKL_savedByNotifID) ZKL_savedByNotifID = [NSMutableDictionary dictionary];
    if (!ZKL_savedByBulletinID) ZKL_savedByBulletinID = [NSMutableDictionary dictionary];
    NSString *nid = nil, *bid = nil;
    @try { nid = [request notificationIdentifier]; } @catch (NSException *e) {}
    @try { BBBulletin *b = [request bulletin]; if (b) bid = [b publisherBulletinID]; } @catch (NSException *e) {}
    if (nid) ZKL_savedByNotifID[nid] = request;
    if (bid) ZKL_savedByBulletinID[bid] = request;
    if (nid || bid) ZKLLog(@"SpringBoard: saved Zalo req notif=%@ bulletin=%@ ts=%@", nid, bid, [request timestamp]);
}
// Re-add request gốc vào store (lớp C). Gọi qua method đã hook nên sẽ
// lật cờ shouldDismiss lại 1 lần nữa (idempotent). Cùng identifier nên
// store replace, không tạo bản sao, timestamp gốc giữ nguyên thứ tự.
static void ZKL_ReaddRequest(NCNotificationRequest *request) {
    if (!request || !ZKL_savedStore) return;
    @try {
        ZKLLog(@"SpringBoard: RE-ADD Zalo req %@ ts=%@", [request notificationIdentifier], [request timestamp]);
        [(NCNotificationStore *)ZKL_savedStore addNotificationRequest:request];
    } @catch (NSException *e) { ZKLLog(@"SpringBoard: re-add failed %@", e); }
}
static void ZKL_ScheduleReadd(NCNotificationRequest *request) {
    if (!request) return;
    // 0.5s: rút ngay sau nhấn. 1.5s: rút muộn qua XPC daemon.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ZKL_ReaddRequest(request); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ZKL_ReaddRequest(request); });
}

// ---------- Lớp A: lật cờ shouldDismiss lúc post noti ----------
static NCNotificationRequest *ZKL_MutateRequestForZalo(NCNotificationRequest *request) {
    if (!request) return request;
    NSString *section = nil;
    @try { section = [request sectionIdentifier]; } @catch (NSException *e) { return request; }
    if (![section isEqualToString:ZKL_ZALO]) return request;

    BOOL origDismiss = YES;
    NCNotificationAction *def = nil;
    @try {
        def = [request defaultAction];
        if (def) origDismiss = [def shouldDismissNotification];
    } @catch (NSException *e) {}
    ZKLLog(@"SpringBoard: post Zalo req %@ default.shouldDismiss=%d", [request notificationIdentifier], origDismiss);

    NCMutableNotificationRequest *mut = nil;
    @try { mut = (NCMutableNotificationRequest *)[request mutableCopy]; } @catch (NSException *e) { return request; }
    if (!mut) return request;
    @try {
        NCNotificationAction *d = [mut defaultAction];
        if (d) {
            NCMutableNotificationAction *md = (NCMutableNotificationAction *)[d mutableCopy];
            if (md) { [md setShouldDismissNotification:NO]; [mut setDefaultAction:md]; }
        }
        NCNotificationOptions *o = [mut options];
        if (o) {
            NCMutableNotificationOptions *mo = (NCMutableNotificationOptions *)[o mutableCopy];
            if (mo) { [mo setDismissAutomatically:NO]; [mut setOptions:mo]; }
        }
    } @catch (NSException *e) {
        ZKLLog(@"SpringBoard: mutate failed %@, using original", e);
        return request;
    }
    ZKL_SaveRequest(mut);
    return mut;
}

// ============================================================
// NHÁNH 1: Zalo - chặn app tự clear (API công khai)
// ============================================================
static void (*orig_removeAllDelivered)(id, SEL);
static void ZKL_removeAllDelivered(id self, SEL _cmd) {
    ZKLLog(@"Zalo: blocked removeAllDeliveredNotifications");
}
static void (*orig_removeDeliveredIDs)(id, SEL, NSArray *);
static void ZKL_removeDeliveredIDs(id self, SEL _cmd, NSArray *identifiers) {
    ZKLLog(@"Zalo: blocked removeDeliveredNotificationsWithIdentifiers: %@", identifiers);
}
static void ZKL_HookZalo(void) {
    Class cls = objc_getClass("UNUserNotificationCenter");
    if (!cls) { ZKLLog(@"Zalo: UNUserNotificationCenter not found"); return; }
    BOOL ok1 = ZKL_Swizzle(cls, @selector(removeAllDeliveredNotifications),
                           (IMP)ZKL_removeAllDelivered, (IMP *)&orig_removeAllDelivered);
    BOOL ok2 = ZKL_Swizzle(cls, @selector(removeDeliveredNotificationsWithIdentifiers:),
                           (IMP)ZKL_removeDeliveredIDs, (IMP *)&orig_removeDeliveredIDs);
    ZKLLog(@"Zalo: hook removeAll=%d removeIDs=%d", ok1, ok2);
}

// ============================================================
// NHÁNH 2: SpringBoard (giữ nguyên 1.1.0 + thêm BBObserver + re-add)
// ============================================================
// --- A1: NCNotificationAction.shouldDismissNotification ---
static BOOL (*orig_ncShouldDismiss)(id, SEL);
static BOOL ZKL_ncShouldDismiss(id self, SEL _cmd) {
    BOOL orig = orig_ncShouldDismiss(self, _cmd);
    NCNotificationAction *act = (NCNotificationAction *)self;
    NSString *bid = nil; BOOL dest = NO;
    @try { bid = [act launchBundleID]; dest = [act isDestructiveAction]; } @catch (NSException *e) {}
    if ([bid isEqualToString:ZKL_ZALO] && !dest) {
        ZKLLog(@"SpringBoard: NCAction.shouldDismiss Zalo -> NO (was %d)", orig);
        return NO;
    }
    return orig;
}
// --- A2: BBAction.shouldDismissBulletin ---
static BOOL (*orig_bbShouldDismiss)(id, SEL);
static BOOL ZKL_bbShouldDismiss(id self, SEL _cmd) {
    BOOL orig = orig_bbShouldDismiss(self, _cmd);
    BBAction *act = (BBAction *)self;
    NSString *bid = nil;
    @try { bid = [act launchBundleID]; } @catch (NSException *e) {}
    if ([bid isEqualToString:ZKL_ZALO]) {
        ZKLLog(@"SpringBoard: BBAction.shouldDismiss Zalo -> NO (was %d)", orig);
        return NO;
    }
    return orig;
}
// --- A3: dispatcher post ---
static void (*orig_dispPost)(id, SEL, id);
static void ZKL_dispPost(id self, SEL _cmd, id request) {
    orig_dispPost(self, _cmd, ZKL_MutateRequestForZalo((NCNotificationRequest *)request));
}
// --- A4: store add ---
static id (*orig_storeAdd)(id, SEL, id);
static id ZKL_storeAdd(id self, SEL _cmd, id request) {
    ZKL_savedStore = self;
    return orig_storeAdd(self, _cmd, ZKL_MutateRequestForZalo((NCNotificationRequest *)request));
}
// --- Tap ghi nhận: NCBulletinActionRunner executeAction ---
static void (*orig_runnerExecute)(id, SEL, id, id, id, id);
static void ZKL_runnerExecute(id self, SEL _cmd, id action, id origin, id params, id completion) {
    @try {
        NCBulletinActionRunner *runner = (NCBulletinActionRunner *)self;
        BBAction *bbAction = [runner action];
        NSString *bid = nil;
        if (bbAction) bid = [bbAction launchBundleID];
        if (!bid && action) bid = [(BBAction *)action launchBundleID];
        if ([bid isEqualToString:ZKL_ZALO]) {
            NSString *bulletinID = nil;
            BBBulletin *bulletin = [runner bulletin];
            if (bulletin) bulletinID = [bulletin publisherBulletinID];
            ZKL_RecordTap(bulletinID);
            if (bbAction) [bbAction setShouldDismissBulletin:NO];
            if (action && action != bbAction) [(BBAction *)action setShouldDismissBulletin:NO];
            ZKLLog(@"SpringBoard: TAP Zalo runner action %@ bulletin %@", [(BBAction *)action identifier], bulletinID);
            NCNotificationRequest *saved = ZKL_savedByBulletinID[bulletinID];
            if (saved) ZKL_ScheduleReadd(saved);
        }
    } @catch (NSException *e) { ZKLLog(@"SpringBoard: runner tap check failed %@", e); }
    orig_runnerExecute(self, _cmd, action, origin, params, completion);
}
// --- Tap ghi nhận: dispatcher executeAction ---
static void (*orig_dispExecute)(id, SEL, id, id, id, BOOL, id, id);
static void ZKL_dispExecute(id self, SEL _cmd, id dest, id action, id request, BOOL auth, id params, id completion) {
    @try {
        NCNotificationRequest *req = (NCNotificationRequest *)request;
        NSString *section = [req sectionIdentifier];
        if ([section isEqualToString:ZKL_ZALO]) {
            ZKL_RecordTap([req notificationIdentifier]);
            if (action && [action respondsToSelector:@selector(setShouldDismissNotification:)])
                [(NCMutableNotificationAction *)action setShouldDismissNotification:NO];
            ZKLLog(@"SpringBoard: TAP Zalo dispatcher req %@", [req notificationIdentifier]);
            ZKL_ScheduleReadd(req);
        }
    } @catch (NSException *e) { ZKLLog(@"SpringBoard: dispatcher tap check failed %@", e); }
    orig_dispExecute(self, _cmd, dest, action, request, auth, params, completion);
}
// --- Tap ghi nhận: BBObserver.sendResponse: (đường response đi qua đây) ---
static void (*orig_observerSendResponse)(id, SEL, id);
static void ZKL_observerSendResponse(id self, SEL _cmd, id response) {
    @try {
        BBResponse *resp = (BBResponse *)response;
        NSString *bid = [resp bulletinID];
        NCNotificationRequest *saved = ZKL_savedByBulletinID[bid];
        if (saved) {
            ZKL_RecordTap(bid);
            ZKLLog(@"SpringBoard: TAP Zalo via BBObserver.sendResponse bulletin %@", bid);
            ZKL_ScheduleReadd(saved);
        }
    } @catch (NSException *e) {}
    orig_observerSendResponse(self, _cmd, response);
}
// --- B1: store remove + re-add ---
static id (*orig_storeRemove)(id, SEL, id);
static id ZKL_storeRemove(id self, SEL _cmd, id request) {
    NSString *section = ZKL_SectionOfRequest(request);
    if ([section isEqualToString:ZKL_ZALO]) {
        if (ZKL_TappedRecently()) {
            ZKLLog(@"SpringBoard: BLOCKED store.remove Zalo %@ (tap)", [(NCNotificationRequest *)request notificationIdentifier]);
            return request;
        }
        ZKLLog(@"SpringBoard: allow store.remove Zalo %@ (no recent tap -> swipe/clear)", [(NCNotificationRequest *)request notificationIdentifier]);
    }
    return orig_storeRemove(self, _cmd, request);
}
// --- B2: dispatcher withdraw ---
static void (*orig_dispWithdraw)(id, SEL, id);
static void ZKL_dispWithdraw(id self, SEL _cmd, id request) {
    NSString *section = ZKL_SectionOfRequest(request);
    if ([section isEqualToString:ZKL_ZALO] && ZKL_TappedRecently()) {
        ZKLLog(@"SpringBoard: BLOCKED dispatcher.withdraw Zalo %@ (tap)", [(NCNotificationRequest *)request notificationIdentifier]);
        return;
    }
    orig_dispWithdraw(self, _cmd, request);
}
// --- B3: BBServer withdraw requests ---
static void (*orig_bbWithdrawReqs)(id, SEL, id, id);
static void ZKL_bbWithdrawReqs(id self, SEL _cmd, id pubBulletinID, id sectionID) {
    if ([sectionID isEqualToString:ZKL_ZALO] && ZKL_TappedRecently()) {
        ZKLLog(@"SpringBoard: BLOCKED BB.withdrawReqs Zalo %@ (tap)", pubBulletinID);
        return;
    }
    orig_bbWithdrawReqs(self, _cmd, pubBulletinID, sectionID);
}
// --- B4: BBServer withdrawBulletinID: ---
static void (*orig_bbWithdrawID)(id, SEL, id);
static void ZKL_bbWithdrawID(id self, SEL _cmd, id bulletinID) {
    if (ZKL_TappedRecently() && bulletinID && ZKL_lastTapBulletinID &&
        [bulletinID isEqualToString:ZKL_lastTapBulletinID]) {
        ZKLLog(@"SpringBoard: BLOCKED BB.withdrawBulletinID %@ (tap)", bulletinID);
        return;
    }
    orig_bbWithdrawID(self, _cmd, bulletinID);
}
// --- B5: dispatcher requestsClearing ---
static void (*orig_dispClearing)(id, SEL, id, id);
static void ZKL_dispClearing(id self, SEL _cmd, id dest, id requests) {
    if (!ZKL_TappedRecently() || !requests) { orig_dispClearing(self, _cmd, dest, requests); return; }
    NSMutableArray *kept = [NSMutableArray array];
    BOOL filtered = NO;
    for (id r in (NSArray *)requests) {
        NSString *s = ZKL_SectionOfRequest(r);
        if ([s isEqualToString:ZKL_ZALO]) {
            filtered = YES;
            ZKLLog(@"SpringBoard: BLOCKED clearing Zalo %@ in tap window", [(NCNotificationRequest *)r notificationIdentifier]);
        } else [kept addObject:r];
    }
    if (!filtered) { orig_dispClearing(self, _cmd, dest, requests); return; }
    if (kept.count == 0) return;
    orig_dispClearing(self, _cmd, dest, kept);
}
// --- B6: list UI remove ---
static void (*orig_listRemove)(id, SEL, id, id);
static void ZKL_listRemove(id self, SEL _cmd, id request, id coalesced) {
    NSString *section = ZKL_SectionOfRequest(request);
    if ([section isEqualToString:ZKL_ZALO] && ZKL_TappedRecently()) {
        ZKLLog(@"SpringBoard: BLOCKED list.remove Zalo %@ (tap)", [(NCNotificationRequest *)request notificationIdentifier]);
        return;
    }
    orig_listRemove(self, _cmd, request, coalesced);
}
// --- E1: BBObserver.removeBulletins:inSection: ---
static void (*orig_obsRemove)(id, SEL, id, id);
static void ZKL_obsRemove(id self, SEL _cmd, id bulletins, id sectionID) {
    if ([sectionID isEqualToString:ZKL_ZALO] && ZKL_TappedRecently()) {
        ZKLLog(@"SpringBoard: BLOCKED BBObserver.removeBulletins Zalo section %@ (tap)", sectionID);
        return;
    }
    if ([sectionID isEqualToString:ZKL_ZALO]) ZKLLog(@"SpringBoard: allow BBObserver.removeBulletins Zalo (swipe/clear)");
    orig_obsRemove(self, _cmd, bulletins, sectionID);
}
// --- E2: BBObserver.removeBulletins:inSection:fromFeed: ---
static void (*orig_obsRemoveFeed)(id, SEL, id, id, unsigned long long);
static void ZKL_obsRemoveFeed(id self, SEL _cmd, id bulletins, id sectionID, unsigned long long feed) {
    if ([sectionID isEqualToString:ZKL_ZALO] && ZKL_TappedRecently()) {
        ZKLLog(@"SpringBoard: BLOCKED BBObserver.removeBulletins:fromFeed Zalo (tap)");
        return;
    }
    orig_obsRemoveFeed(self, _cmd, bulletins, sectionID, feed);
}
// --- E3: BBObserver.clearBulletins:inSection: ---
static void (*orig_obsClear)(id, SEL, id, id);
static void ZKL_obsClear(id self, SEL _cmd, id bulletins, id sectionID) {
    if ([sectionID isEqualToString:ZKL_ZALO] && ZKL_TappedRecently()) {
        ZKLLog(@"SpringBoard: BLOCKED BBObserver.clearBulletins Zalo (tap)");
        return;
    }
    orig_obsClear(self, _cmd, bulletins, sectionID);
}

static void ZKL_HookSpringBoard(void) {
    if (!objc_getClass("NCNotificationStore"))
        ZKL_LoadFramework("/System/Library/PrivateFrameworks/UserNotificationsKit.framework/UserNotificationsKit");
    if (!objc_getClass("NCBulletinActionRunner"))
        ZKL_LoadFramework("/System/Library/PrivateFrameworks/UserNotificationsUIKit.framework/UserNotificationsUIKit");
    if (!objc_getClass("BBServer"))
        ZKL_LoadFramework("/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard");

    static BOOL h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16;
    Class c;
    c = objc_getClass("NCNotificationAction");
    if (c && !h1) h1 = ZKL_Swizzle(c, @selector(shouldDismissNotification), (IMP)ZKL_ncShouldDismiss, (IMP *)&orig_ncShouldDismiss);
    c = objc_getClass("BBAction");
    if (c && !h2) h2 = ZKL_Swizzle(c, @selector(shouldDismissBulletin), (IMP)ZKL_bbShouldDismiss, (IMP *)&orig_bbShouldDismiss);
    c = objc_getClass("NCNotificationDispatcher");
    if (c && !h3) h3 = ZKL_Swizzle(c, @selector(postNotificationWithRequest:), (IMP)ZKL_dispPost, (IMP *)&orig_dispPost);
    if (c && !h6) h6 = ZKL_Swizzle(c, NSSelectorFromString(@"destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:"), (IMP)ZKL_dispExecute, (IMP *)&orig_dispExecute);
    if (c && !h8) h8 = ZKL_Swizzle(c, @selector(withdrawNotificationWithRequest:), (IMP)ZKL_dispWithdraw, (IMP *)&orig_dispWithdraw);
    if (c && !h11) h11 = ZKL_Swizzle(c, NSSelectorFromString(@"destination:requestsClearingNotificationRequests:"), (IMP)ZKL_dispClearing, (IMP *)&orig_dispClearing);
    c = objc_getClass("NCNotificationStore");
    if (c && !h4) h4 = ZKL_Swizzle(c, @selector(addNotificationRequest:), (IMP)ZKL_storeAdd, (IMP *)&orig_storeAdd);
    if (c && !h7) h7 = ZKL_Swizzle(c, @selector(removeNotificationRequest:), (IMP)ZKL_storeRemove, (IMP *)&orig_storeRemove);
    c = objc_getClass("NCBulletinActionRunner");
    if (c && !h5) h5 = ZKL_Swizzle(c, NSSelectorFromString(@"executeAction:fromOrigin:withParameters:completion:"), (IMP)ZKL_runnerExecute, (IMP *)&orig_runnerExecute);
    c = objc_getClass("BBServer");
    if (c && !h9) h9 = ZKL_Swizzle(c, NSSelectorFromString(@"withdrawBulletinRequestsWithPublisherBulletinID:forSectionID:"), (IMP)ZKL_bbWithdrawReqs, (IMP *)&orig_bbWithdrawReqs);
    if (c && !h10) h10 = ZKL_Swizzle(c, @selector(withdrawBulletinID:), (IMP)ZKL_bbWithdrawID, (IMP *)&orig_bbWithdrawID);
    c = objc_getClass("NCNotificationListViewController");
    if (c && !h12) h12 = ZKL_Swizzle(c, NSSelectorFromString(@"removeNotificationRequest:forCoalescedNotification:"), (IMP)ZKL_listRemove, (IMP *)&orig_listRemove);
    c = objc_getClass("BBObserver");
    if (c && !h13) h13 = ZKL_Swizzle(c, NSSelectorFromString(@"removeBulletins:inSection:"), (IMP)ZKL_obsRemove, (IMP *)&orig_obsRemove);
    if (c && !h14) h14 = ZKL_Swizzle(c, NSSelectorFromString(@"removeBulletins:inSection:fromFeed:"), (IMP)ZKL_obsRemoveFeed, (IMP *)&orig_obsRemoveFeed);
    if (c && !h15) h15 = ZKL_Swizzle(c, NSSelectorFromString(@"clearBulletins:inSection:"), (IMP)ZKL_obsClear, (IMP *)&orig_obsClear);
    if (c && !h16) h16 = ZKL_Swizzle(c, @selector(sendResponse:), (IMP)ZKL_observerSendResponse, (IMP *)&orig_observerSendResponse);

    ZKLLog(@"SpringBoard: hooks NCAction=%d BBAction=%d dispPost=%d storeAdd=%d runner=%d dispExec=%d storeRemove=%d dispWithdraw=%d bbReqs=%d bbID=%d clearing=%d listRemove=%d obsRemove=%d obsRemoveFeed=%d obsClear=%d obsSendResp=%d",
           h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16);
}

// ============================================================
// NHÁNH 3: usernotificationsd (daemon, không có bundleIdentifier)
// Mỗi UNSDefaultDataProvider instance là của 1 app, nên
// [self sectionIdentifier] == Zalo là đủ để nhận diện, không cần tap window:
// đường withdraw ở daemon chỉ chạy khi tap mở app hoặc khi app tự clear,
// còn vuốt xóa ở lockscreen đi qua BBServer trực tiếp, không qua đây.
// ============================================================
static void (*orig_unsWithdraw)(id, SEL, id);
static void ZKL_unsWithdraw(id self, SEL _cmd, id notification) {
    NSString *section = nil;
    @try { section = [self sectionIdentifier]; } @catch (NSException *e) {}
    if ([section isEqualToString:ZKL_ZALO]) {
        ZKLLog(@"usernotificationsd: BLOCKED UNS.withdraw Zalo notif %@", notification);
        return;
    }
    orig_unsWithdraw(self, _cmd, notification);
}
static void (*orig_proxyWithdraw)(id, SEL, id);
static void ZKL_proxyWithdraw(id self, SEL _cmd, id pubBulletinID) {
    NSString *section = nil;
    @try {
        BBDataProviderIdentity *ident = [(BBDataProviderProxy *)self identity];
        if (ident) section = [ident sectionIdentifier];
    } @catch (NSException *e) {}
    if ([section isEqualToString:ZKL_ZALO]) {
        ZKLLog(@"usernotificationsd: BLOCKED BBDataProviderProxy.withdraw Zalo %@", pubBulletinID);
        return;
    }
    orig_proxyWithdraw(self, _cmd, pubBulletinID);
}
static void (*orig_remoteWithdraw)(id, SEL, id);
static void ZKL_remoteWithdraw(id self, SEL _cmd, id pubBulletinID) {
    NSString *section = nil;
    @try { section = [self sectionIdentifier]; } @catch (NSException *e) {}
    if ([section isEqualToString:ZKL_ZALO]) {
        ZKLLog(@"usernotificationsd: BLOCKED BBRemoteDataProvider.withdraw Zalo %@", pubBulletinID);
        return;
    }
    orig_remoteWithdraw(self, _cmd, pubBulletinID);
}
static void ZKL_HookUserNotificationsDaemon(void) {
    if (!objc_getClass("UNSDefaultDataProvider"))
        ZKL_LoadFramework("/System/Library/PrivateFrameworks/UserNotificationsServer.framework/UserNotificationsServer");
    if (!objc_getClass("BBDataProviderProxy"))
        ZKL_LoadFramework("/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard");

    static BOOL d1, d2, d3;
    Class c;
    c = objc_getClass("UNSDefaultDataProvider");
    if (c && !d1) d1 = ZKL_Swizzle(c, NSSelectorFromString(@"_queue_withdrawBulletinForNotification:"), (IMP)ZKL_unsWithdraw, (IMP *)&orig_unsWithdraw);
    c = objc_getClass("BBDataProviderProxy");
    if (c && !d2) d2 = ZKL_Swizzle(c, @selector(withdrawBulletinWithPublisherBulletinID:), (IMP)ZKL_proxyWithdraw, (IMP *)&orig_proxyWithdraw);
    c = objc_getClass("BBRemoteDataProvider");
    if (c && !d3) d3 = ZKL_Swizzle(c, @selector(withdrawBulletinWithPublisherBulletinID:), (IMP)ZKL_remoteWithdraw, (IMP *)&orig_remoteWithdraw);
    ZKLLog(@"usernotificationsd: hooks unsWithdraw=%d proxyWithdraw=%d remoteWithdraw=%d", d1, d2, d3);
}

// ============================================================
// Constructor - nhận diện process bằng bundleIdentifier, nếu không
// có thì bằng tên executable (daemon không có bundle).
// ============================================================
__attribute__((constructor)) static void ZaloKeepNotif_init(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        const char *prog = getprogname();
        NSString *progName = prog ? [NSString stringWithUTF8String:prog] : @"";
        ZKLLog(@"loaded in bid=%@ prog=%@ iOS %@ (v1.2.2 roothide)", bid, progName, [[NSProcessInfo processInfo] operatingSystemVersionString]);
        if ([bid isEqualToString:ZKL_ZALO]) {
            ZKL_HookZalo();
        } else if ([bid isEqualToString:@"com.apple.springboard"] || [progName isEqualToString:@"SpringBoard"]) {
            ZKL_HookSpringBoard();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ZKL_HookSpringBoard(); });
        } else if ([progName isEqualToString:@"usernotificationsd"]) {
            ZKL_HookUserNotificationsDaemon();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ZKL_HookUserNotificationsDaemon(); });
        } else {
            ZKLLog(@"not Zalo/SpringBoard/usernotificationsd, no hook");
        }
    }
}
