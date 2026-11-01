#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

static NSString *const kPrefGroupModeKey = @"ZaloNotif_GroupMode";

// Lưu trữ tất cả thông báo đã nhận để có thể re-post bất cứ lúc nào
static NSMutableDictionary<NSString *, UNNotificationContent *> *savedNotifications = nil;
static NSObject *savedLock = nil;

// ==========================================
// SWIZZLE HELPER
// ==========================================
static void SafeSwizzle(Class cls, SEL origSel, SEL swizSel) {
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
// RE-POST: Đăng lại TẤT CẢ thông báo đã lưu lên Lockscreen
// ==========================================
static void RepostAllSavedNotifications(void) {
    @synchronized(savedLock) {
        if (savedNotifications.count == 0) return;
        NSLog(@"[ZaloKeepNotif] Re-posting %lu saved notifications", (unsigned long)savedNotifications.count);

        [savedNotifications enumerateKeysAndObjectsUsingBlock:^(NSString *key, UNNotificationContent *content, BOOL *stop) {
            UNMutableNotificationContent *mc = [content mutableCopy];
            mc.sound = nil; // Không phát lại âm thanh

            // Phải dùng local trigger, KHÔNG dùng Push trigger
            UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.5 repeats:NO];

            // Dùng identifier mới hoàn toàn để iOS không coi là duplicate
            NSString *newId = [NSString stringWithFormat:@"zk_%@_%u", key, arc4random()];
            UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:newId
                                                                              content:mc
                                                                              trigger:trigger];

            // Gọi TRỰC TIẾP method gốc, KHÔNG đi qua swizzle của mình (tránh vòng lặp)
            SEL origAddSel = @selector(zk_addNotificationRequest:withCompletionHandler:);
            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            if ([center respondsToSelector:origAddSel]) {
                // swizzled -> zk_ gọi original
                ((void (*)(id, SEL, UNNotificationRequest *, id))objc_msgSend)(center, origAddSel, req, nil);
            }
        }];
    }
}

// ==========================================
// GIAO DIỆN CÀI ĐẶT (POPUP MENU)
// ==========================================
static void ShowGroupingSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
        }
        if (!window) window = [UIApplication sharedApplication].windows.firstObject;

        UIViewController *rootVC = window.rootViewController;
        while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
        if (!rootVC) return;

        NSInteger currentMode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefGroupModeKey];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚙️ Cài đặt Thông báo Zalo"
                                                                       message:@"Chọn cách sắp xếp thông báo trên Lockscreen:"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];

        NSString *t0 = [NSString stringWithFormat:@"%@ Tách riêng từng Cá nhân & Nhóm", currentMode == 0 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:t0 style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        NSString *t1 = [NSString stringWithFormat:@"%@ Gom tất cả vào 1 mục Zalo chung", currentMode == 1 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:t1 style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        NSString *t2 = [NSString stringWithFormat:@"%@ Xếp theo thời gian (Không gom)", currentMode == 2 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:t2 style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[NSUserDefaults standardUserDefaults] setInteger:2 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];

        if (alert.popoverPresentationController) {
            alert.popoverPresentationController.sourceView = window;
            alert.popoverPresentationController.sourceRect = CGRectMake(window.bounds.size.width / 2, window.bounds.size.height / 2, 1, 1);
        }
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

@interface UIWindow (ZaloNotifMenu)
@end
@implementation UIWindow (ZaloNotifMenu)
- (void)zk_motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    [self zk_motionEnded:motion withEvent:event];
    if (motion == UIEventSubtypeMotionShake) ShowGroupingSettings();
}
@end

// ==========================================
// HOOK UNUserNotificationCenter
// ==========================================
@interface UNUserNotificationCenter (ZaloKeepNotif)
@end

@implementation UNUserNotificationCenter (ZaloKeepNotif)

- (void)zk_removeAllDeliveredNotifications {
    NSLog(@"[ZaloKeepNotif] BLOCKED removeAllDeliveredNotifications - re-posting all");
    // Không xóa, và lập tức đăng lại tất cả để chắc ăn
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RepostAllSavedNotifications();
    });
}

- (void)zk_removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    NSLog(@"[ZaloKeepNotif] BLOCKED removeDeliveredNotificationsWithIdentifiers:%lu - re-posting", (unsigned long)identifiers.count);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RepostAllSavedNotifications();
    });
}

- (void)zk_removeAllPendingNotificationRequests {
    NSLog(@"[ZaloKeepNotif] BLOCKED removeAllPendingNotificationRequests");
}

- (void)zk_removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    NSLog(@"[ZaloKeepNotif] BLOCKED removePendingNotificationRequestsWithIdentifiers");
}

- (void)zk_setBadgeCount:(NSInteger)newBadgeCount withCompletionHandler:(void (^)(NSError *))completionHandler {
    if (newBadgeCount <= 0) {
        NSLog(@"[ZaloKeepNotif] BLOCKED setBadgeCount:%ld", (long)newBadgeCount);
        if (completionHandler) completionHandler(nil);
        return;
    }
    [self zk_setBadgeCount:newBadgeCount withCompletionHandler:completionHandler];
}

- (void)zk_addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *))completionHandler {
    UNMutableNotificationContent *mc = [request.content mutableCopy];

    // Lưu thông báo vào bộ nhớ (dùng title làm key vì identifier có thể thay đổi)
    NSString *storeKey = request.content.title ?: request.identifier;
    if (storeKey && mc && ![request.identifier hasPrefix:@"zk_"]) {
        @synchronized(savedLock) {
            savedNotifications[storeKey] = [mc copy];
        }
        NSLog(@"[ZaloKeepNotif] Saved notification: %@ (total: %lu)", storeKey, (unsigned long)savedNotifications.count);
    }

    // Áp dụng chế độ sắp xếp
    NSInteger mode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefGroupModeKey];
    if (mode == 0) {
        NSString *threadId = nil;
        NSDictionary *userInfo = request.content.userInfo;
        if (userInfo) {
            if (userInfo[@"grid"] && [userInfo[@"grid"] description].length > 0) {
                threadId = [NSString stringWithFormat:@"group_%@", userInfo[@"grid"]];
            } else if (userInfo[@"from_uid"] && [userInfo[@"from_uid"] description].length > 0) {
                threadId = [NSString stringWithFormat:@"user_%@", userInfo[@"from_uid"]];
            } else if (userInfo[@"thread_id"] && [userInfo[@"thread_id"] description].length > 0) {
                threadId = [NSString stringWithFormat:@"thread_%@", userInfo[@"thread_id"]];
            }
        }
        if (!threadId) threadId = request.content.title ?: @"zalo_general";
        mc.threadIdentifier = threadId;
    } else if (mode == 1) {
        mc.threadIdentifier = @"com.vng.zalo.all";
    } else if (mode == 2) {
        mc.threadIdentifier = [[NSUUID UUID] UUIDString];
    }

    UNNotificationRequest *newReq = [UNNotificationRequest requestWithIdentifier:request.identifier
                                                                         content:mc
                                                                         trigger:request.trigger];
    [self zk_addNotificationRequest:newReq withCompletionHandler:completionHandler];
}

@end

// ==========================================
// HOOK UIApplication
// ==========================================
@interface UIApplication (ZaloKeepNotif)
@end
@implementation UIApplication (ZaloKeepNotif)
- (void)zk_setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber <= 0) {
        NSLog(@"[ZaloKeepNotif] BLOCKED setApplicationIconBadgeNumber:%ld", (long)badgeNumber);
        return;
    }
    [self zk_setApplicationIconBadgeNumber:badgeNumber];
}
@end

// ==========================================
// HOOK DELEGATE
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    UNNotificationPresentationOptions opts = UNNotificationPresentationOptionList | UNNotificationPresentationOptionBadge;
    // Thông báo re-post (zk_) không phát âm thanh/banner
    if (![notification.request.identifier hasPrefix:@"zk_"]) {
        opts |= (UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
    }
    if (completionHandler) completionHandler(opts);
}

static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void));

static void swiz_didReceive(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotificationResponse *response, void (^completionHandler)(void)) {
    // Gọi hàm gốc để Zalo mở đúng cuộc trò chuyện
    if (orig_didReceive) {
        orig_didReceive(self, _cmd, center, response, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }

    // Khi user click vào notification, iOS tự xóa nó.
    // Đợi 1 giây rồi re-post LẠI TẤT CẢ thông báo đã lưu
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[ZaloKeepNotif] User tapped notification - re-posting ALL saved notifications");
        RepostAllSavedNotifications();
    });
}

static void hookDelegateClass(Class delClass) {
    if (!delClass) return;

    // willPresentNotification
    SEL wpSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method mWP = class_getInstanceMethod(delClass, wpSel);
    if (mWP) {
        method_setImplementation(mWP, (IMP)swiz_willPresent);
        NSLog(@"[ZaloKeepNotif] Hooked willPresentNotification on %@", NSStringFromClass(delClass));
    }

    // didReceiveNotificationResponse
    SEL drSel = @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:);
    Method mDR = class_getInstanceMethod(delClass, drSel);
    if (mDR) {
        orig_didReceive = (void (*)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)))method_getImplementation(mDR);
        method_setImplementation(mDR, (IMP)swiz_didReceive);
        NSLog(@"[ZaloKeepNotif] Hooked didReceiveNotificationResponse on %@", NSStringFromClass(delClass));
    }
}

static void swiz_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    orig_setDelegate(self, _cmd, delegate);
    if (delegate) hookDelegateClass([delegate class]);
}

// Cử chỉ 2 ngón
static void AddGestureToWindow(UIWindow *window) {
    if (!window) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[UIWindow class] action:@selector(zk_handleTwoFingerTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    [window addGestureRecognizer:tap];
}

@interface UIWindow (ZaloGesture)
+ (void)zk_handleTwoFingerTap:(UITapGestureRecognizer *)gesture;
@end
@implementation UIWindow (ZaloGesture)
+ (void)zk_handleTwoFingerTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) ShowGroupingSettings();
}
@end

// ==========================================
// CONSTRUCTOR
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] v3.0 - Ultimate persistent notification tweak loading...");

        savedNotifications = [NSMutableDictionary new];
        savedLock = [NSObject new];

        Class uncClass = objc_getClass("UNUserNotificationCenter");
        if (uncClass) {
            SafeSwizzle(uncClass, @selector(removeAllDeliveredNotifications), @selector(zk_removeAllDeliveredNotifications));
            SafeSwizzle(uncClass, @selector(removeDeliveredNotificationsWithIdentifiers:), @selector(zk_removeDeliveredNotificationsWithIdentifiers:));
            SafeSwizzle(uncClass, @selector(removeAllPendingNotificationRequests), @selector(zk_removeAllPendingNotificationRequests));
            SafeSwizzle(uncClass, @selector(removePendingNotificationRequestsWithIdentifiers:), @selector(zk_removePendingNotificationRequestsWithIdentifiers:));
            SafeSwizzle(uncClass, @selector(addNotificationRequest:withCompletionHandler:), @selector(zk_addNotificationRequest:withCompletionHandler:));

            SEL setBadgeSel = @selector(setBadgeCount:withCompletionHandler:);
            if (class_getInstanceMethod(uncClass, setBadgeSel)) {
                SafeSwizzle(uncClass, setBadgeSel, @selector(zk_setBadgeCount:withCompletionHandler:));
            }

            Method setDelMethod = class_getInstanceMethod(uncClass, @selector(setDelegate:));
            if (setDelMethod) {
                orig_setDelegate = (void (*)(id, SEL, id<UNUserNotificationCenterDelegate>))method_getImplementation(setDelMethod);
                method_setImplementation(setDelMethod, (IMP)swiz_setDelegate);
            }

            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            if (center.delegate) hookDelegateClass([center.delegate class]);
        }

        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            SafeSwizzle(appClass, @selector(setApplicationIconBadgeNumber:), @selector(zk_setApplicationIconBadgeNumber:));
        }

        Class winClass = objc_getClass("UIWindow");
        if (winClass) {
            SafeSwizzle(winClass, @selector(motionEnded:withEvent:), @selector(zk_motionEnded:withEvent:));
        }

        // Khi app mở xong: add gesture + hook delegate (nếu chưa)
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in scene.windows) AddGestureToWindow(w);
                }
            }
        }];

        // LƯỚI AN TOÀN: Mỗi khi Zalo trở lại foreground (bấm vào app, mở từ lockscreen, v.v.)
        // → Đợi 1.5 giây rồi re-post lại TẤT CẢ thông báo đã lưu
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            NSLog(@"[ZaloKeepNotif] App became active - scheduling re-post safety net");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                RepostAllSavedNotifications();
            });
        }];

        // LƯỚI AN TOÀN 2: Khi Zalo về background (khóa màn hình, chuyển app khác)
        // → Đăng lại ngay để notification chắc chắn có trên lockscreen
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            NSLog(@"[ZaloKeepNotif] App resigning active - re-posting to ensure lockscreen presence");
            RepostAllSavedNotifications();
        }];

        NSLog(@"[ZaloKeepNotif] v3.0 loaded successfully. All hooks installed.");
    }
}
