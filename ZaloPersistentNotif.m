#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

static NSString *const kPrefGroupModeKey = @"ZaloNotif_GroupMode";

// Group modes:
// 0: Tách riêng từng Cá nhân & Nhóm (Mặc định)
// 1: Gom tất cả vào 1 mục Zalo chung
// 2: Xếp theo dòng thời gian (Không gom)

static void SafeSwizzle(Class cls, SEL origSel, SEL swizSel) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    if (!origMethod || !swizMethod) return;

    BOOL didAdd = class_addMethod(cls,
                                  origSel,
                                  method_getImplementation(swizMethod),
                                  method_getTypeEncoding(swizMethod));
    if (didAdd) {
        class_replaceMethod(cls,
                            swizSel,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
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
// 2. HOOK UNUserNotificationCenter
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
    NSLog(@"[ZaloKeepNotif] Blocked removePendingNotificationRequestsWithIdentifiers count=%lu", (unsigned long)identifiers.count);
}

- (void)zk_setBadgeCount:(NSInteger)newBadgeCount withCompletionHandler:(void (^)(NSError *error))completionHandler {
    if (newBadgeCount <= 0) {
        NSLog(@"[ZaloKeepNotif] Suppressed setBadgeCount:%ld to prevent Lockscreen wipe", (long)newBadgeCount);
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
// 4. HOOK DELEGATE (GIỮ NGUYÊN NOTI KHI CLICK ĐỌC)
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions));
static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void));

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    // Mọi thông báo đều được lưu vào Notification List (Lockscreen / Notification Center)
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionList | UNNotificationPresentationOptionBadge;

    // Nếu không phải là thông báo re-post (_kept) thì cho hiện banner và phát âm thanh
    if (![notification.request.identifier hasSuffix:@"_kept"]) {
        options |= (UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
    }

    if (completionHandler) {
        completionHandler(options);
    }
}

// Bắt sự kiện khi người dùng CHẠM/CLICK vào thông báo trên Lockscreen để mở vào Zalo đọc:
static void swiz_didReceive(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotificationResponse *response, void (^completionHandler)(void)) {
    UNNotificationRequest *req = response.notification.request;

    // Cho Zalo mở đúng hội thoại bình thường
    if (orig_didReceive) {
        orig_didReceive(self, _cmd, center, response, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }

    // SpringBoard của iOS tự động xóa thông báo vừa click.
    // Tweak lập tức clone lại nội dung và re-post bằng Local Trigger để ghim lại trên Lockscreen:
    if (req && req.content) {
        UNMutableNotificationContent *newContent = [req.content mutableCopy];
        newContent.sound = nil; // Không phát lại âm thanh để không làm phiền khi đang đọc trong app

        if (req.content.threadIdentifier) {
            newContent.threadIdentifier = req.content.threadIdentifier;
        }

        // Tạo local trigger 0.2s (BẮT BUỘC để không bị iOS reject do UNPushNotificationTrigger)
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.2 repeats:NO];

        NSString *repostId = [NSString stringWithFormat:@"%@_kept", req.identifier];
        UNNotificationRequest *repostReq = [UNNotificationRequest requestWithIdentifier:repostId
                                                                                content:newContent
                                                                                trigger:trigger];

        // Dispatch sau 0.4s để chắc chắn SpringBoard đã hoàn thành animation mở app
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:repostReq withCompletionHandler:^(NSError * _Nullable error) {
                if (error) {
                    NSLog(@"[ZaloKeepNotif] Repost error: %@", error);
                } else {
                    NSLog(@"[ZaloKeepNotif] Successfully pinned notification back to Lockscreen: %@", repostId);
                }
            }];
        });
    }
}

static void hookDelegateClass(Class delClass) {
    if (!delClass) return;

    SEL willPresentSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method mWillPresent = class_getInstanceMethod(delClass, willPresentSel);
    if (mWillPresent) {
        orig_willPresent = (void (*)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)))method_getImplementation(mWillPresent);
        method_setImplementation(mWillPresent, (IMP)swiz_willPresent);
    }

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
        NSLog(@"[ZaloKeepNotif] Initializing v2.0 with persistent re-pinning on tap...");

        Class uncClass = objc_getClass("UNUserNotificationCenter");
        if (uncClass) {
            SafeSwizzle(uncClass,
                        @selector(removeAllDeliveredNotifications),
                        @selector(zk_removeAllDeliveredNotifications));
            SafeSwizzle(uncClass,
                        @selector(removeDeliveredNotificationsWithIdentifiers:),
                        @selector(zk_removeDeliveredNotificationsWithIdentifiers:));
            SafeSwizzle(uncClass,
                        @selector(removeAllPendingNotificationRequests),
                        @selector(zk_removeAllPendingNotificationRequests));
            SafeSwizzle(uncClass,
                        @selector(removePendingNotificationRequestsWithIdentifiers:),
                        @selector(zk_removePendingNotificationRequestsWithIdentifiers:));
            SafeSwizzle(uncClass,
                        @selector(addNotificationRequest:withCompletionHandler:),
                        @selector(zk_addNotificationRequest:withCompletionHandler:));

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
            if (center.delegate) {
                hookDelegateClass([center.delegate class]);
            }
        }

        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            SafeSwizzle(appClass,
                        @selector(setApplicationIconBadgeNumber:),
                        @selector(zk_setApplicationIconBadgeNumber:));
        }

        Class winClass = objc_getClass("UIWindow");
        if (winClass) {
            SafeSwizzle(winClass,
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
