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
// 3. HOOK DELEGATE (TRIỆT TIÊU POPUP & GOM NHÓM STACK)
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>) = NULL;
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)) = NULL;
static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)) = NULL;
static BOOL (*orig_respondsToSelector)(id, SEL, SEL) = NULL;

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    // Với tin nhắn re-post (_kept): TUYỆT ĐỐI KHÔNG BẬT POPUP/BANNER/SOUND
    if ([notification.request.identifier containsString:@"_kept"]) {
        UNNotificationPresentationOptions keptOpts = 0;
        if (@available(iOS 14.0, *)) {
            // Chỉ gửi vào danh sách Notification Center, không popup banner, không sound
            keptOpts = (1 << 3); // UNNotificationPresentationOptionList
        }
        if (completionHandler) {
            completionHandler(keptOpts);
        }
        return;
    }

    // Tin nhắn mới đến bình thường: cho phép hiển thị
    if (orig_willPresent) {
        orig_willPresent(self, _cmd, center, notification, ^(UNNotificationPresentationOptions options) {
            options |= (1 << 3);
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

    if (orig_didReceive) {
        orig_didReceive(self, _cmd, center, response, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }

    // Nếu người dùng chủ động vuốt xóa trên Lockscreen: không ghim lại
    if ([actionId isEqualToString:UNNotificationDismissActionIdentifier]) {
        NSLog(@"[ZaloKeepNotif] User manually dismissed notification. Not restoring.");
        return;
    }

    // Khi người dùng bấm vào xem thông báo (Default Action):
    // Tái tạo lại thông báo thầm lặng vào đúng nhóm stack của cuộc hội thoại
    if (req && req.content) {
        UNMutableNotificationContent *mc = [req.content mutableCopy];
        mc.sound = nil; // Tắt hoàn toàn âm thanh
        mc.attachments = @[]; // Xóa attachments tạm để tránh lỗi hệ thống xóa file temp

        // Chặn màn hình khóa sáng đèn hoặc bung banner khi thông báo được nạp lại
        @try {
            [mc setValue:@YES forKey:@"shouldSuppressScreenLightUp"];
        } @catch (NSException *e) {}
        @try {
            [mc setValue:@YES forKey:@"shouldSuppressDefaultAction"];
        } @catch (NSException *e) {}

        // Bảo tồn nguyên vẹn nhóm hội thoại (threadIdentifier) và category để iOS gộp vào trong Stack cũ
        mc.threadIdentifier = req.content.threadIdentifier;
        mc.categoryIdentifier = req.content.categoryIdentifier;

        // Dùng identifier ổn định, không cộng dồn timestamp
        NSString *baseId = [req.identifier stringByReplacingOccurrencesOfString:@"_kept" withString:@""];
        NSString *keptId = [NSString stringWithFormat:@"%@_kept", baseId];

        UNNotificationRequest *keptReq = [UNNotificationRequest requestWithIdentifier:keptId
                                                                              content:mc
                                                                              trigger:nil];

        // Nạp lại sau 0.3s khi SpringBoard hoàn tất chuyển cảnh
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:keptReq withCompletionHandler:^(NSError * _Nullable error) {
                if (!error) {
                    NSLog(@"[ZaloKeepNotif] Successfully re-pinned quiet notification in stack: %@", keptId);
                } else {
                    NSLog(@"[ZaloKeepNotif] Re-pin failed: %@", error);
                }
            }];
        });
    }
}

static BOOL swiz_respondsToSelector(id self, SEL _cmd, SEL aSelector) {
    if (aSelector == @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:) ||
        aSelector == @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)) {
        return YES;
    }
    if (orig_respondsToSelector) {
        return orig_respondsToSelector(self, _cmd, aSelector);
    }
    return class_respondsToSelector([self class], aSelector);
}

static NSMutableSet *sHookedClasses = nil;
static void hookDelegate(Class delClass) {
    if (!delClass) return;
    if (!sHookedClasses) {
        sHookedClasses = [[NSMutableSet alloc] init];
    }
    if ([sHookedClasses containsObject:delClass]) return;
    [sHookedClasses addObject:delClass];

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

    SEL respSel = @selector(respondsToSelector:);
    Method mResp = class_getInstanceMethod(delClass, respSel);
    if (mResp) {
        orig_respondsToSelector = (BOOL (*)(id, SEL, SEL))method_getImplementation(mResp);
        method_setImplementation(mResp, (IMP)swiz_respondsToSelector);
    }
}

static void swiz_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    // Luôn hook delegate TRƯỚC KHI Apple ghi nhận con trỏ delegate
    if (delegate) {
        hookDelegate([delegate class]);
    }
    if (orig_setDelegate) {
        orig_setDelegate(self, _cmd, delegate);
    }
}

// ==========================================
// 4. CONSTRUCTOR
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Initializing v6 tweak...");

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
