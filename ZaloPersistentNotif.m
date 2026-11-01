#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

// ==========================================
// SWIZZLING HELPER
// ==========================================
static void SwizzleMethod(Class cls, SEL origSel, SEL swizSel) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    if (!origMethod || !swizMethod) return;

    BOOL didAdd = class_addMethod(cls, origSel,
                                  method_getImplementation(swizMethod),
                                  method_getTypeEncoding(swizMethod));
    if (didAdd) {
        class_replaceMethod(cls, swizSel,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

// ==========================================
// 1. CHẶN XÓA THÔNG BÁO TỪ UNUserNotificationCenter
// ==========================================
@interface UNUserNotificationCenter (ZaloKeepNotif)
@end

@implementation UNUserNotificationCenter (ZaloKeepNotif)

- (void)zk_removeAllDeliveredNotifications {
    NSLog(@"[ZaloKeepNotif] Blocked removeAllDeliveredNotifications");
}

- (void)zk_removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    NSLog(@"[ZaloKeepNotif] Blocked removeDeliveredNotificationsWithIdentifiers: count=%lu", (unsigned long)identifiers.count);
}

- (void)zk_removeAllPendingNotificationRequests {
    NSLog(@"[ZaloKeepNotif] Blocked removeAllPendingNotificationRequests");
}

- (void)zk_removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    NSLog(@"[ZaloKeepNotif] Blocked removePendingNotificationRequestsWithIdentifiers");
}

- (void)zk_setBadgeCount:(NSInteger)newBadgeCount withCompletionHandler:(void (^)(NSError *))completionHandler {
    if (newBadgeCount <= 0) {
        NSLog(@"[ZaloKeepNotif] Suppressed setBadgeCount:%ld", (long)newBadgeCount);
        if (completionHandler) completionHandler(nil);
        return;
    }
    [self zk_setBadgeCount:newBadgeCount withCompletionHandler:completionHandler];
}

@end

// ==========================================
// 2. CHẶN XÓA THÔNG BÁO TỪ UIApplication (Badge)
// ==========================================
@interface UIApplication (ZaloKeepNotif)
@end

@implementation UIApplication (ZaloKeepNotif)

- (void)zk_setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber <= 0) {
        NSLog(@"[ZaloKeepNotif] Suppressed setApplicationIconBadgeNumber:%ld", (long)badgeNumber);
        return;
    }
    [self zk_setApplicationIconBadgeNumber:badgeNumber];
}

@end

// ==========================================
// 3. HOOK DELEGATE (HIỂN THỊ VÀ GHIM LẠI KHI CLICK ĐỌC)
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>) = NULL;
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)) = NULL;
static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)) = NULL;

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    // Với tin nhắn re-post (_kept): KHÔNG phát âm thanh, nhưng BẮT BUỘC phải bật Banner + List để hiện lên Lockscreen!
    if ([notification.request.identifier containsString:@"_kept"]) {
        // UNNotificationPresentationOptionList (1<<3) | UNNotificationPresentationOptionBanner (1<<4) | UNNotificationPresentationOptionAlert (1<<2) | UNNotificationPresentationOptionBadge (1<<0)
        UNNotificationPresentationOptions keptOpts = (1 << 4) | (1 << 3) | (1 << 2) | (1 << 0);
        if (completionHandler) {
            completionHandler(keptOpts);
        }
        return;
    }

    // Tin nhắn mới đến bình thường: gọi delegate gốc hoặc cho phép hiển thị đầy đủ
    if (orig_willPresent) {
        orig_willPresent(self, _cmd, center, notification, ^(UNNotificationPresentationOptions options) {
            options |= ((1 << 4) | (1 << 3) | (1 << 2) | (1 << 0));
            if (completionHandler) {
                completionHandler(options);
            }
        });
    } else {
        UNNotificationPresentationOptions opts = (1 << 4) | (1 << 3) | (1 << 2) | (1 << 1) | (1 << 0);
        if (completionHandler) {
            completionHandler(opts);
        }
    }
}

static void swiz_didReceive(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotificationResponse *response, void (^completionHandler)(void)) {
    UNNotificationRequest *req = response.notification.request;
    NSString *actionId = response.actionIdentifier;

    // Cho Zalo xử lý chuyển vào phòng chat bình thường
    if (orig_didReceive) {
        orig_didReceive(self, _cmd, center, response, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }

    // Nếu người dùng chủ động vuốt xóa thông báo (Dismiss Action), thì để hệ thống xóa, KHÔNG ghim lại!
    if ([actionId isEqualToString:UNNotificationDismissActionIdentifier]) {
        NSLog(@"[ZaloKeepNotif] User manually dismissed notification. Not reposting.");
        return;
    }

    // Khi người dùng bấm vào xem thông báo (Default Action): SpringBoard tự xóa noti gốc khỏi Lockscreen.
    // Ta clone nội dung notification và ghim lại lên Lockscreen ngay lập tức:
    if (req && req.content) {
        UNMutableNotificationContent *mc = [req.content mutableCopy];
        mc.sound = nil; // Tắt âm thanh để không kêu hay rung lại khi đang xem
        mc.attachments = @[]; // Xóa attachments tạm thời để tránh lỗi UNErrorDomain Code 100 nếu file ảnh temp bị iOS dọn dẹp

        // Đặt ID mới duy nhất
        NSString *baseId = req.identifier;
        if ([baseId containsString:@"_kept_"]) {
            NSArray *parts = [baseId componentsSeparatedByString:@"_kept_"];
            baseId = parts.firstObject;
        }
        NSString *keptId = [NSString stringWithFormat:@"%@_kept_%llu", baseId, (unsigned long long)[[NSDate date] timeIntervalSince1970]];

        // Không dùng timer trễ (trigger = nil để post ngay lập tức)
        UNNotificationRequest *keptReq = [UNNotificationRequest requestWithIdentifier:keptId
                                                                              content:mc
                                                                              trigger:nil];

        // Trễ 0.6s để SpringBoard hoàn tất việc đóng view noti gốc trước khi nạp noti ghim lại
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:keptReq withCompletionHandler:^(NSError * _Nullable error) {
                if (!error) {
                    NSLog(@"[ZaloKeepNotif] Successfully re-pinned notification: %@", keptId);
                } else {
                    NSLog(@"[ZaloKeepNotif] Failed to re-pin notification: %@", error);
                }
            }];
        });
    }
}

static void hookDelegate(Class delClass) {
    if (!delClass) return;
    static Class sHookedClass = Nil;
    if (sHookedClass == delClass) return;
    sHookedClass = delClass;

    SEL wpSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method mWP = class_getInstanceMethod(delClass, wpSel);
    if (mWP) {
        orig_willPresent = (void (*)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)))method_getImplementation(mWP);
        method_setImplementation(mWP, (IMP)swiz_willPresent);
    } else {
        class_addMethod(delClass, wpSel, (IMP)swiz_willPresent, "v@:@@@?");
    }

    SEL drSel = @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:);
    Method mDR = class_getInstanceMethod(delClass, drSel);
    if (mDR) {
        orig_didReceive = (void (*)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)))method_getImplementation(mDR);
        method_setImplementation(mDR, (IMP)swiz_didReceive);
    } else {
        class_addMethod(delClass, drSel, (IMP)swiz_didReceive, "v@:@@@?");
    }
}

static void swiz_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    orig_setDelegate(self, _cmd, delegate);
    if (delegate) {
        hookDelegate([delegate class]);
    }
}

// ==========================================
// 4. CONSTRUCTOR
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Initializing persistent notification tweak...");

        Class uncClass = objc_getClass("UNUserNotificationCenter");
        if (uncClass) {
            SwizzleMethod(uncClass,
                          @selector(removeAllDeliveredNotifications),
                          @selector(zk_removeAllDeliveredNotifications));
            SwizzleMethod(uncClass,
                          @selector(removeDeliveredNotificationsWithIdentifiers:),
                          @selector(zk_removeDeliveredNotificationsWithIdentifiers:));
            SwizzleMethod(uncClass,
                          @selector(removeAllPendingNotificationRequests),
                          @selector(zk_removeAllPendingNotificationRequests));
            SwizzleMethod(uncClass,
                          @selector(removePendingNotificationRequestsWithIdentifiers:),
                          @selector(zk_removePendingNotificationRequestsWithIdentifiers:));

            SEL setBadgeSel = @selector(setBadgeCount:withCompletionHandler:);
            if (class_getInstanceMethod(uncClass, setBadgeSel)) {
                SwizzleMethod(uncClass, setBadgeSel, @selector(zk_setBadgeCount:withCompletionHandler:));
            }

            Method setDelMethod = class_getInstanceMethod(uncClass, @selector(setDelegate:));
            if (setDelMethod) {
                orig_setDelegate = (void (*)(id, SEL, id<UNUserNotificationCenterDelegate>))method_getImplementation(setDelMethod);
                method_setImplementation(setDelMethod, (IMP)swiz_setDelegate);
            }

            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            if (center.delegate) {
                hookDelegate([center.delegate class]);
            }
        }

        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            SwizzleMethod(appClass,
                          @selector(setApplicationIconBadgeNumber:),
                          @selector(zk_setApplicationIconBadgeNumber:));
        }

        NSLog(@"[ZaloKeepNotif] Ready.");
    }
}
