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
// 3. QUẢN LÝ GHIM THÔNG BÁO KHI VÀO BACKGROUND (KHÔNG POPUP, GIỮ NGUYÊN THỨ TỰ)
// ==========================================
static NSMutableDictionary<NSString *, NSDictionary *> *sPendingRePost = nil;

static void repostPendingNotifications() {
    if (!sPendingRePost || sPendingRePost.count == 0) return;

    NSDictionary *toPost = nil;
    @synchronized (sPendingRePost) {
        toPost = [sPendingRePost copy];
        [sPendingRePost removeAllObjects];
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    for (NSString *key in toPost) {
        NSDictionary *item = toPost[key];
        UNNotificationRequest *req = item[@"request"];
        NSDate *origDate = item[@"date"];
        if (!req || !req.content) continue;

        UNMutableNotificationContent *mc = [req.content mutableCopy];
        mc.sound = nil; // Không âm thanh
        mc.attachments = @[]; // Tránh lỗi file temp bị xóa

        // Khôi phục ngày gốc qua KVC để iOS giữ nguyên thứ tự thời gian trên Lockscreen
        if (origDate) {
            @try {
                [mc setValue:origDate forKey:@"date"];
            } @catch (NSException *e) {}
        }
        mc.threadIdentifier = req.content.threadIdentifier;

        NSString *keptId = req.identifier;
        if (![keptId containsString:@"_kept"]) {
            keptId = [NSString stringWithFormat:@"%@_kept", req.identifier];
        }

        UNNotificationRequest *keptReq = [UNNotificationRequest requestWithIdentifier:keptId
                                                                              content:mc
                                                                              trigger:nil];

        [center addNotificationRequest:keptReq withCompletionHandler:^(NSError * _Nullable error) {
            if (!error) {
                NSLog(@"[ZaloKeepNotif] Successfully restored notification to Lockscreen in original order: %@", keptId);
            } else {
                NSLog(@"[ZaloKeepNotif] Failed to restore notification: %@", error);
            }
        }];
    }
}

// ==========================================
// 4. HOOK DELEGATE
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>) = NULL;
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)) = NULL;
static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)) = NULL;

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    // Nếu có thông báo re-post: TUYỆT ĐỐI KHÔNG BẬT BANNER/POPUP
    if ([notification.request.identifier containsString:@"_kept"]) {
        if (completionHandler) {
            completionHandler((1 << 3)); // Chỉ list, không banner, không alert, không popup
        }
        return;
    }

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
        if (req && sPendingRePost) {
            @synchronized (sPendingRePost) {
                [sPendingRePost removeObjectForKey:req.identifier];
            }
        }
        return;
    }

    // Khi người dùng bấm vào xem thông báo: lưu lại thông tin thông báo kèm thời gian gốc (date)
    // KHÔNG đăng thông báo ngay lúc này (tránh hiện popup banner khi đang đọc tin nhắn)
    if (req && req.content) {
        NSDate *origDate = response.notification.date;
        if (!origDate) origDate = [NSDate date];

        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"request"] = req;
        item[@"date"] = origDate;

        if (!sPendingRePost) {
            sPendingRePost = [[NSMutableDictionary alloc] init];
        }
        @synchronized (sPendingRePost) {
            sPendingRePost[req.identifier] = item;
        }
        NSLog(@"[ZaloKeepNotif] Queued notification for Lockscreen restoration on background: %@", req.identifier);
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
    // Hook TRƯỚC KHI gọi orig_setDelegate để Apple ghi nhận các phương thức delegate đã được cài đặt
    if (delegate) {
        hookDelegate([delegate class]);
    }
    orig_setDelegate(self, _cmd, delegate);
}

// ==========================================
// 5. CONSTRUCTOR
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Initializing v5 tweak...");

        sPendingRePost = [[NSMutableDictionary alloc] init];

        // Lắng nghe khi app chuẩn bị vào Background (khóa màn hình hoặc thoát app)
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            repostPendingNotifications();
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            repostPendingNotifications();
        }];

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
