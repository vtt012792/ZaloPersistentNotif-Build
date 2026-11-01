#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

static NSString *const kPrefGroupModeKey = @"ZaloNotif_GroupMode";

// Group modes:
// 0: Tách riêng từng Cá nhân & Nhóm
// 1: Gom tất cả vào 1 mục Zalo chung
// 2: Xếp theo dòng thời gian (Không gom)

static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL swizSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    if (origMethod && swizMethod) {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

// ==========================================
// 1. GIAO DIỆN CÀI ĐẶT (POPUP MENU)
// ==========================================
static void ShowGroupingSettings() {
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
        while (rootVC.presentedViewController) {
            rootVC = rootVC.presentedViewController;
        }
        if (!rootVC) return;

        NSInteger currentMode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefGroupModeKey];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚙️ Cài đặt Thông báo Zalo"
                                                                       message:@"Chọn cách sắp xếp thông báo trên Lockscreen / Màn hình khóa:"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];

        NSString *title0 = [NSString stringWithFormat:@"%@ Tách riêng từng Cá nhân & Nhóm", currentMode == 0 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:title0 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        NSString *title1 = [NSString stringWithFormat:@"%@ Gom tất cả vào 1 mục Zalo chung", currentMode == 1 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:title1 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        NSString *title2 = [NSString stringWithFormat:@"%@ Xếp theo thời gian (Không gom cụm)", currentMode == 2 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:title2 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
    if (motion == UIEventSubtypeMotionShake) {
        ShowGroupingSettings();
    }
}

@end

// ==========================================
// 2. HOOK UNUserNotificationCenter (CHỐNG XOÁ TUYỆT ĐỐI)
// ==========================================
@interface UNUserNotificationCenter (ZaloKeepNotif)
@end

@implementation UNUserNotificationCenter (ZaloKeepNotif)

- (void)zk_removeAllDeliveredNotifications {
    NSLog(@"[ZaloKeepNotif] Blocked removeAllDeliveredNotifications");
}

- (void)zk_removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    NSLog(@"[ZaloKeepNotif] Blocked removeDeliveredNotificationsWithIdentifiers count=%lu", (unsigned long)identifiers.count);
}

- (void)zk_removeAllPendingNotificationRequests {
    NSLog(@"[ZaloKeepNotif] Blocked removeAllPendingNotificationRequests");
}

- (void)zk_removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    NSLog(@"[ZaloKeepNotif] Blocked removePendingNotificationRequestsWithIdentifiers");
}

// iOS 16+ setBadgeCount:withCompletionHandler:
- (void)zk_setBadgeCount:(NSInteger)newBadgeCount withCompletionHandler:(void (^)(NSError *error))completionHandler {
    if (newBadgeCount <= 0) {
        NSLog(@"[ZaloKeepNotif] Suppressed setBadgeCount:%ld to prevent lockscreen wipe", (long)newBadgeCount);
        if (completionHandler) completionHandler(nil);
        return;
    }
    [self zk_setBadgeCount:newBadgeCount withCompletionHandler:completionHandler];
}

- (void)zk_addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *error))completionHandler {
    UNMutableNotificationContent *mutableContent = [request.content mutableCopy];
    NSInteger mode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefGroupModeKey];

    if (mode == 0) {
        // Tách riêng từng cá nhân & nhóm
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

        if (!threadId || threadId.length == 0) {
            if (request.content.title.length > 0) {
                threadId = [NSString stringWithFormat:@"title_%@", request.content.title];
            } else {
                threadId = @"zalo_general";
            }
        }
        mutableContent.threadIdentifier = threadId;
    } else if (mode == 1) {
        mutableContent.threadIdentifier = @"com.vng.zalo.all";
    } else if (mode == 2) {
        mutableContent.threadIdentifier = [[NSUUID UUID] UUIDString];
    }

    UNNotificationRequest *newReq = [UNNotificationRequest requestWithIdentifier:request.identifier
                                                                         content:mutableContent
                                                                         trigger:request.trigger];
    [self zk_addNotificationRequest:newReq withCompletionHandler:completionHandler];
}

@end

// ==========================================
// 3. HOOK UIApplication (Badge)
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
// 4. HOOK DELEGATE (HIỂN THỊ + GIỮ LẠI KHI CLICK ĐỌC)
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions));
static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void));

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBanner | 
                                               UNNotificationPresentationOptionSound | 
                                               UNNotificationPresentationOptionBadge | 
                                               UNNotificationPresentationOptionList;
    if (completionHandler) {
        completionHandler(options);
    }
}

// Khi người dùng click vào thông báo từ Lockscreen để đọc:
static void swiz_didReceive(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotificationResponse *response, void (^completionHandler)(void)) {
    // Lưu lại request thông báo trước khi hệ thống xóa
    UNNotificationRequest *req = response.notification.request;

    // Gọi hàm xử lý gốc của Zalo để mở đúng cuộc trò chuyện
    if (orig_didReceive) {
        orig_didReceive(self, _cmd, center, response, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }

    // Sau khi hệ thống iOS tự động xóa thông báo vừa click, ta lập tức đăng lại (re-post)
    // để thông báo tiếp tục nằm nguyên trên Lockscreen / Notification Center cho đến khi tự tay vuốt xóa!
    if (req) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[ZaloKeepNotif] Re-posting clicked notification to keep it on Lockscreen: %@", req.identifier);
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:nil];
        });
    }
}

static void hookDelegateClass(Class delClass) {
    if (!delClass) return;
    
    // 1. Hook willPresentNotification:
    SEL willPresentSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method mWillPresent = class_getInstanceMethod(delClass, willPresentSel);
    if (mWillPresent) {
        orig_willPresent = (void (*)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)))method_getImplementation(mWillPresent);
        method_setImplementation(mWillPresent, (IMP)swiz_willPresent);
    }

    // 2. Hook didReceiveNotificationResponse:
    SEL didRecvSel = @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:);
    Method mDidRecv = class_getInstanceMethod(delClass, didRecvSel);
    if (mDidRecv) {
        orig_didReceive = (void (*)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)))method_getImplementation(mDidRecv);
        method_setImplementation(mDidRecv, (IMP)swiz_didReceive);
        NSLog(@"[ZaloKeepNotif] Hooked didReceiveNotificationResponse on %@", NSStringFromClass(delClass));
    }
}

static void swiz_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    orig_setDelegate(self, _cmd, delegate);
    if (delegate) {
        hookDelegateClass([delegate class]);
    }
}

// Cử chỉ chạm 2 ngón tay x 2 lần
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
    if (gesture.state == UIGestureRecognizerStateEnded) {
        ShowGroupingSettings();
    }
}
@end

// ==========================================
// 5. CONSTRUCTOR
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Initializing complete persistent notification tweak...");

        Class uncClass = objc_getClass("UNUserNotificationCenter");
        if (uncClass) {
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeAllDeliveredNotifications),
                                  @selector(zk_removeAllDeliveredNotifications));
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeDeliveredNotificationsWithIdentifiers:),
                                  @selector(zk_removeDeliveredNotificationsWithIdentifiers:));
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeAllPendingNotificationRequests),
                                  @selector(zk_removeAllPendingNotificationRequests));
            SwizzleInstanceMethod(uncClass,
                                  @selector(removePendingNotificationRequestsWithIdentifiers:),
                                  @selector(zk_removePendingNotificationRequestsWithIdentifiers:));
            SwizzleInstanceMethod(uncClass,
                                  @selector(addNotificationRequest:withCompletionHandler:),
                                  @selector(zk_addNotificationRequest:withCompletionHandler:));

            // Hook setBadgeCount:withCompletionHandler: (iOS 16+)
            SEL setBadgeSel = @selector(setBadgeCount:withCompletionHandler:);
            if (class_getInstanceMethod(uncClass, setBadgeSel)) {
                SwizzleInstanceMethod(uncClass, setBadgeSel, @selector(zk_setBadgeCount:withCompletionHandler:));
                NSLog(@"[ZaloKeepNotif] Hooked setBadgeCount:withCompletionHandler:");
            }

            // Hook setDelegate:
            Method setDelMethod = class_getInstanceMethod(uncClass, @selector(setDelegate:));
            if (setDelMethod) {
                orig_setDelegate = (void (*)(id, SEL, id<UNUserNotificationCenterDelegate>))method_getImplementation(setDelMethod);
                method_setImplementation(setDelMethod, (IMP)swiz_setDelegate);
            }

            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            if (center.delegate) {
                hookDelegateClass([center.delegate class]);
            }
        }

        // Hook UIApplication badge
        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            SwizzleInstanceMethod(appClass,
                                  @selector(setApplicationIconBadgeNumber:),
                                  @selector(zk_setApplicationIconBadgeNumber:));
        }

        // Hook UIWindow shake
        Class winClass = objc_getClass("UIWindow");
        if (winClass) {
            SwizzleInstanceMethod(winClass,
                                  @selector(motionEnded:withEvent:),
                                  @selector(zk_motionEnded:withEvent:));
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in scene.windows) {
                        AddGestureToWindow(w);
                    }
                }
            }
        }];
    }
}
