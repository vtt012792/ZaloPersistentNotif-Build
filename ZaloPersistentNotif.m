#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

static NSString *const kPrefGroupModeKey = @"ZaloNotif_GroupMode";

// Group modes:
// 0: Tách riêng từng Cá nhân & Nhóm (Stack theo từng người / group)
// 1: Gom chung tất cả vào 1 mục Zalo duy nhất
// 2: Xếp theo dòng thời gian (Mỗi tin riêng lẻ, không gom)

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

        // iPad support
        if (alert.popoverPresentationController) {
            alert.popoverPresentationController.sourceView = window;
            alert.popoverPresentationController.sourceRect = CGRectMake(window.bounds.size.width / 2, window.bounds.size.height / 2, 1, 1);
        }

        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

// Hook UIWindow motionEnded:withEvent: để kích hoạt menu bằng cách LẮC MÁY
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
    // Chặn xoá sạch thông báo khi mở app
    NSLog(@"[ZaloKeepNotif] Blocked removeAllDeliveredNotifications");
}

- (void)zk_removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    // Chặn xoá thông báo khi mở từng hội thoại
    NSLog(@"[ZaloKeepNotif] Blocked removeDeliveredNotificationsWithIdentifiers");
}

- (void)zk_addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *error))completionHandler {
    UNMutableNotificationContent *mutableContent = [request.content mutableCopy];
    NSInteger mode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefGroupModeKey];

    if (mode == 0) {
        // Mode 0: Tách riêng từng cá nhân & nhóm
        // Tìm định danh người gửi hoặc nhóm từ userInfo hoặc title
        NSString *threadId = nil;
        NSDictionary *userInfo = request.content.userInfo;
        if (userInfo) {
            // Zalo notification packet keys
            if (userInfo[@"grid"] && [userInfo[@"grid"] description].length > 0) {
                threadId = [NSString stringWithFormat:@"group_%@", userInfo[@"grid"]];
            } else if (userInfo[@"from_uid"] && [userInfo[@"from_uid"] description].length > 0) {
                threadId = [NSString stringWithFormat:@"user_%@", userInfo[@"from_uid"]];
            } else if (userInfo[@"thread_id"] && [userInfo[@"thread_id"] description].length > 0) {
                threadId = [NSString stringWithFormat:@"thread_%@", userInfo[@"thread_id"]];
            }
        }

        if (!threadId || threadId.length == 0) {
            // Fallback theo tiêu đề người gửi hoặc nhóm
            if (request.content.title.length > 0) {
                threadId = [NSString stringWithFormat:@"title_%@", request.content.title];
            } else {
                threadId = @"zalo_general";
            }
        }
        mutableContent.threadIdentifier = threadId;
    } else if (mode == 1) {
        // Mode 1: Gom tất cả vào 1 mục Zalo chung
        mutableContent.threadIdentifier = @"com.vng.zalo.all";
    } else if (mode == 2) {
        // Mode 2: Không gom cụm, mỗi tin nhắn là 1 stack riêng biệt
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
        // Suppress calling 0 to prevent iOS from clearing Lockscreen notifications
        return;
    }
    [self zk_setApplicationIconBadgeNumber:badgeNumber];
}

@end

// ==========================================
// 4. FORCED NOTIFICATION PRESENTATION DELEGATE
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions));

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBanner | 
                                               UNNotificationPresentationOptionSound | 
                                               UNNotificationPresentationOptionBadge | 
                                               UNNotificationPresentationOptionList;
    if (completionHandler) {
        completionHandler(options);
    }
}

static void hookDelegateClass(Class delClass) {
    if (!delClass) return;
    SEL willPresentSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method m = class_getInstanceMethod(delClass, willPresentSel);
    if (m) {
        orig_willPresent = (void (*)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)))method_getImplementation(m);
        method_setImplementation(m, (IMP)swiz_willPresent);
    }
}

static void swiz_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    orig_setDelegate(self, _cmd, delegate);
    if (delegate) {
        hookDelegateClass([delegate class]);
    }
}

// Thêm nhận diện cử chỉ chạm 2 ngón tay x 2 lần (2-finger double tap) để mở menu dễ dàng
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
        NSLog(@"[ZaloKeepNotif] Loaded with grouping options support.");

        // Hook UNUserNotificationCenter
        Class uncClass = objc_getClass("UNUserNotificationCenter");
        if (uncClass) {
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeAllDeliveredNotifications),
                                  @selector(zk_removeAllDeliveredNotifications));
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeDeliveredNotificationsWithIdentifiers:),
                                  @selector(zk_removeDeliveredNotificationsWithIdentifiers:));
            SwizzleInstanceMethod(uncClass,
                                  @selector(addNotificationRequest:withCompletionHandler:),
                                  @selector(zk_addNotificationRequest:withCompletionHandler:));

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

        // Đăng ký cử chỉ 2 ngón tay khi app khởi động xong
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
