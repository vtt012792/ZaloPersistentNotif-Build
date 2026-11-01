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
// CẤU HÌNH & GIAO DIỆN TÙY CHỌN GOM NHÓM
// ==========================================
static NSString *const kPrefGroupModeKey = @"ZaloNotif_GroupMode";

/*
 Các chế độ gom nhóm (Group Modes):
 Mode 0: 👥 Tách riêng từng Cá nhân & Nhóm chat (Mỗi người/nhóm 1 xấp riêng) [Mặc định]
 Mode 1: 📦 Gom tất cả thông báo Zalo vào chung 1 xấp duy nhất
 Mode 2: ⏱️ Không gom cụm (Hiển thị từng tin riêng lẻ theo thời gian)
 Mode 3: 💬 Chỉ gom nhóm chat, tin cá nhân để riêng lẻ
*/

@interface ZKSettingsWindow : UIWindow
@property (nonatomic, strong) UIButton *settingsButton;
+ (void)zk_openSettings;
@end

static ZKSettingsWindow *sSettingsWindow = nil;

static void ShowGroupingSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = nil;
        if (sSettingsWindow && sSettingsWindow.rootViewController) {
            presenter = sSettingsWindow.rootViewController;
            while (presenter.presentedViewController) {
                presenter = presenter.presentedViewController;
            }
        }

        if (!presenter) {
            UIWindow *activeWin = nil;
            if (@available(iOS 13.0, *)) {
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                        for (UIWindow *w in scene.windows) {
                            if (w != sSettingsWindow && (w.isKeyWindow || [w isKindOfClass:[UIWindow class]])) {
                                activeWin = w;
                                break;
                            }
                        }
                    }
                }
            }
            if (!activeWin) {
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    if (w != sSettingsWindow) {
                        activeWin = w;
                        break;
                    }
                }
            }
            presenter = activeWin.rootViewController;
            while (presenter.presentedViewController) {
                presenter = presenter.presentedViewController;
            }
        }

        if (!presenter) return;

        NSInteger currentMode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefGroupModeKey];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚙️ Cài đặt Gom Thông Báo Zalo"
                                                                       message:@"Chọn cách sắp xếp và gom cụm thông báo trên Màn hình khóa (Lockscreen):"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];

        NSString *title0 = [NSString stringWithFormat:@"%@ 👥 Tách riêng từng Cá nhân & Nhóm chat", currentMode == 0 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:title0 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        NSString *title1 = [NSString stringWithFormat:@"%@ 📦 Gom tất cả vào 1 mục Zalo chung", currentMode == 1 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:title1 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        NSString *title2 = [NSString stringWithFormat:@"%@ ⏱️ Không gom cụm (Hiển thị từng tin riêng lẻ)", currentMode == 2 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:title2 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSUserDefaults standardUserDefaults] setInteger:2 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        NSString *title3 = [NSString stringWithFormat:@"%@ 💬 Chỉ gom nhóm chat, cá nhân để riêng", currentMode == 3 ? @"✅" : @"   "];
        [alert addAction:[UIAlertAction actionWithTitle:title3 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSUserDefaults standardUserDefaults] setInteger:3 forKey:kPrefGroupModeKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];

        if (alert.popoverPresentationController) {
            alert.popoverPresentationController.sourceView = sSettingsWindow.settingsButton ?: presenter.view;
            alert.popoverPresentationController.sourceRect = sSettingsWindow.settingsButton ? sSettingsWindow.settingsButton.bounds : CGRectMake(presenter.view.bounds.size.width / 2, presenter.view.bounds.size.height / 2, 1, 1);
        }

        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

@implementation ZKSettingsWindow

+ (void)zk_openSettings {
    ShowGroupingSettings();
}

// Xuyên thấu toàn bộ touch ngoại trừ nút ⚙️ và Alert đang hiển thị
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.settingsButton && !self.settingsButton.hidden) {
        CGPoint pInBtn = [self.settingsButton convertPoint:point fromView:self];
        if ([self.settingsButton pointInside:pInBtn withEvent:event]) {
            return [self.settingsButton hitTest:pInBtn withEvent:event];
        }
    }
    if (self.rootViewController.presentedViewController) {
        return [super hitTest:point withEvent:event];
    }
    return nil; // Cho phép toàn bộ thao tác bàn phím/mã khóa của Zalo diễn ra bình thường
}

@end

static void EnsureSettingsWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)s;
                    if (ws.activationState == UISceneActivationStateForegroundActive) {
                        activeScene = ws;
                        break;
                    }
                    if (!activeScene) activeScene = ws;
                }
            }
        }

        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat topInset = 54.0;
        if (@available(iOS 11.0, *)) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w != sSettingsWindow && w.safeAreaInsets.top > 20) {
                    topInset = w.safeAreaInsets.top + 6.0;
                    break;
                }
            }
        }

        CGRect btnFrame = CGRectMake(screenBounds.size.width - 54, topInset, 44, 44);

        if (!sSettingsWindow) {
            if (@available(iOS 13.0, *)) {
                if (activeScene) {
                    sSettingsWindow = [[ZKSettingsWindow alloc] initWithWindowScene:activeScene];
                }
            }
            if (!sSettingsWindow) {
                sSettingsWindow = [[ZKSettingsWindow alloc] initWithFrame:screenBounds];
            } else {
                sSettingsWindow.frame = screenBounds;
            }

            sSettingsWindow.windowLevel = UIWindowLevelAlert + 1000;
            sSettingsWindow.backgroundColor = [UIColor clearColor];

            UIViewController *rootVC = [[UIViewController alloc] init];
            rootVC.view.backgroundColor = [UIColor clearColor];
            rootVC.view.userInteractionEnabled = YES;

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = btnFrame;
            btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.41 blue:0.95 alpha:0.92];
            btn.layer.cornerRadius = 22.0;
            btn.layer.masksToBounds = YES;
            btn.layer.borderWidth = 2.0;
            btn.layer.borderColor = [UIColor whiteColor].CGColor;
            [btn setTitle:@"⚙️" forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:22];
            [btn addTarget:[ZKSettingsWindow class] action:@selector(zk_openSettings) forControlEvents:UIControlEventTouchUpInside];

            [rootVC.view addSubview:btn];
            sSettingsWindow.rootViewController = rootVC;
            sSettingsWindow.settingsButton = btn;
        } else {
            if (@available(iOS 13.0, *)) {
                if (activeScene && sSettingsWindow.windowScene != activeScene) {
                    sSettingsWindow.windowScene = activeScene;
                }
            }
            sSettingsWindow.frame = screenBounds;
            if (sSettingsWindow.settingsButton) {
                sSettingsWindow.settingsButton.frame = btnFrame;
            }
        }

        sSettingsWindow.hidden = NO;
        if (sSettingsWindow.superview) {
            [sSettingsWindow.superview bringSubviewToFront:sSettingsWindow];
        }
    });
}

// Hook UIViewController viewDidAppear để đảm bảo xuất hiện cố định ngay cả khi vào màn hình khóa Zalo
@interface UIViewController (ZKLockscreenHook)
@end

@implementation UIViewController (ZKLockscreenHook)

- (void)zk_viewDidAppear:(BOOL)animated {
    [self zk_viewDidAppear:animated];
    EnsureSettingsWindow();
}

@end

// Hàm tính toán threadIdentifier dựa trên mode đã chọn
static NSString *zk_determineThreadIdentifier(UNNotificationContent *content) {
    NSInteger mode = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefGroupModeKey];
    NSDictionary *userInfo = content.userInfo;

    if (mode == 1) {
        // Mode 1: Gom tất cả thông báo Zalo vào chung 1 xấp duy nhất
        return @"com.vng.zalo.all";
    }

    if (mode == 2) {
        // Mode 2: Không gom cụm, mỗi tin nhắn là 1 stack riêng biệt theo thời gian
        return [[NSUUID UUID] UUIDString];
    }

    NSString *groupId = nil;
    NSString *userUid = nil;

    if (userInfo) {
        if (userInfo[@"grid"] && [userInfo[@"grid"] description].length > 0) {
            groupId = [NSString stringWithFormat:@"group_%@", userInfo[@"grid"]];
        } else if (userInfo[@"conv_id"] && [userInfo[@"conv_id"] description].length > 0) {
            groupId = [NSString stringWithFormat:@"conv_%@", userInfo[@"conv_id"]];
        }

        if (userInfo[@"from_uid"] && [userInfo[@"from_uid"] description].length > 0) {
            userUid = [NSString stringWithFormat:@"user_%@", userInfo[@"from_uid"]];
        } else if (userInfo[@"uid"] && [userInfo[@"uid"] description].length > 0) {
            userUid = [NSString stringWithFormat:@"user_%@", userInfo[@"uid"]];
        }
    }

    if (mode == 3) {
        // Mode 3: Chỉ gom nhóm chat, tin cá nhân để riêng lẻ
        if (groupId) return groupId;
        return [[NSUUID UUID] UUIDString];
    }

    // Mode 0 (Mặc định): Tách riêng từng cá nhân và từng nhóm chat
    if (groupId) return groupId;
    if (userUid) return userUid;

    if (content.threadIdentifier && content.threadIdentifier.length > 0) {
        return content.threadIdentifier;
    }

    if (content.title.length > 0) {
        return [NSString stringWithFormat:@"zalo_chat_%lu", (unsigned long)[content.title hash]];
    }

    return @"zalo_general";
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
    NSLog(@"[ZaloKeepNotif] Blocked removePendingNotificationRequestsWithIdentifiers: count=%lu", (unsigned long)identifiers.count);
}

- (void)zk_setBadgeCount:(NSInteger)newBadgeCount withCompletionHandler:(void(^)(NSError *error))completionHandler {
    if (newBadgeCount <= 0) {
        NSLog(@"[ZaloKeepNotif] Suppressed setBadgeCount:%ld (to prevent Lockscreen bulletin wipe)", (long)newBadgeCount);
        if (completionHandler) completionHandler(nil);
        return;
    }
    [self zk_setBadgeCount:newBadgeCount withCompletionHandler:completionHandler];
}

@end

// ==========================================
// 2. CHẶN XÓA BADGE CỦA UIApplication
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
// 3. TẠO BẢN SAO CONTENT HOÀN HẢO (KHÔNG BANNER / KHÔNG SOUND)
// ==========================================
static UNMutableNotificationContent *zk_prepareContentCopy(UNNotificationContent *origContent) {
    UNMutableNotificationContent *newContent = [[UNMutableNotificationContent alloc] init];

    newContent.title = origContent.title ?: @"";
    newContent.subtitle = origContent.subtitle ?: @"";
    newContent.body = origContent.body ?: @"";
    newContent.categoryIdentifier = origContent.categoryIdentifier ?: @"";
    newContent.attachments = origContent.attachments ?: @[];

    // Tự động gom cụm theo Mode đã chọn trong cài đặt
    newContent.threadIdentifier = zk_determineThreadIdentifier(origContent);

    // QUAN TRỌNG:
    // sound = nil để SpringBoard hoàn toàn im lặng, không rung chuông
    newContent.sound = nil;

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (origContent.userInfo) {
        [dict addEntriesFromDictionary:origContent.userInfo];
    }
    // Cờ đánh dấu thông báo này được dylib phục hồi, chặn willPresentNotification tạo popup
    dict[@"zk_kept"] = @YES;
    dict[@"zk_restored_at"] = [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]];
    newContent.userInfo = dict;

    return newContent;
}

// ==========================================
// 4. CASCADE MONOTONIC RE-ORDERING ENGINE (20ms tuần tự)
// ==========================================
static void zk_sequentialRepost(NSArray<UNNotificationRequest *> *queue, NSUInteger index, void (^onComplete)(void)) {
    if (index >= queue.count) {
        if (onComplete) onComplete();
        return;
    }

    UNNotificationRequest *req = queue[index];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[ZaloKeepNotif] Error reposting request [%lu/%lu] id=%@: %@", (unsigned long)index, (unsigned long)queue.count, req.identifier, error);
        } else {
            NSLog(@"[ZaloKeepNotif] Successfully reposted request [%lu/%lu] id=%@", (unsigned long)index, (unsigned long)queue.count, req.identifier);
        }

        // Delay 20ms giữa mỗi thông báo để usernoted gán monotonic timestamp tăng dần
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            zk_sequentialRepost(queue, index + 1, onComplete);
        });
    }];
}

// ==========================================
// 5. HOOK DELEGATE CỦA UNUserNotificationCenter
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>) = NULL;
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)) = NULL;
static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)) = NULL;
static BOOL (*orig_respondsToSelector)(id, SEL, SEL) = NULL;

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    NSDictionary *userInfo = notification.request.content.userInfo;

    // Chặn triệt để popup banner khi thông báo được dylib ghim lại
    if (userInfo && userInfo[@"zk_kept"]) {
        NSLog(@"[ZaloKeepNotif] Suppressed in-app popup banner for restored notification id=%@", notification.request.identifier);
        if (completionHandler) {
            completionHandler((1 << 3)); // Chỉ hiển thị trong danh sách thông báo, 0 banner, 0 sound
        }
        return;
    }

    if (orig_willPresent) {
        orig_willPresent(self, _cmd, center, notification, completionHandler);
    } else if (completionHandler) {
        completionHandler(UNNotificationPresentationOptionBadge | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionAlert);
    }
}

static void swiz_didReceive(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotificationResponse *response, void (^completionHandler)(void)) {
    NSLog(@"[ZaloKeepNotif] Intercepted tap/action on notification id=%@", response.notification.request.identifier);

    // 1. Chạy logic xử lý gốc của Zalo để mở đúng cuộc trò chuyện
    if (orig_didReceive) {
        orig_didReceive(self, _cmd, center, response, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }

    // 2. Nếu người dùng chủ động vuốt xóa trên Lockscreen: tôn trọng thao tác, không ghim lại
    NSString *actionId = response.actionIdentifier;
    if ([actionId isEqualToString:UNNotificationDismissActionIdentifier]) {
        NSLog(@"[ZaloKeepNotif] User manually dismissed notification. Not restoring.");
        return;
    }

    UNNotification *tappedNotif = response.notification;
    UNNotificationRequest *tappedReq = tappedNotif.request;
    if (!tappedReq || !tappedReq.content) return;

    NSDate *tappedDate = tappedNotif.date ?: [NSDate dateWithTimeIntervalSinceNow:-60];

    // 3. Lấy danh sách toàn bộ thông báo đang có trên Lockscreen để tính toán thứ tự tương đối
    [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> * _Nonnull deliveredList) {
        NSMutableArray<UNNotification *> *newerNotifications = [NSMutableArray array];

        for (UNNotification *n in deliveredList) {
            // Lọc ra các thông báo vốn dĩ đến SAU thông báo vừa click
            if ([n.date compare:tappedDate] == NSOrderedDescending) {
                [newerNotifications addObject:n];
            }
        }

        // Sắp xếp các thông báo mới hơn theo thứ tự TĂNG DẦN (từ cũ đến mới)
        [newerNotifications sortUsingComparator:^NSComparisonResult(UNNotification *n1, UNNotification *n2) {
            return [n1.date compare:n2.date];
        }];

        // Xây dựng hàng đợi nạp tuần tự đơn điệu:
        // [0]: Thông báo vừa click (nhận mốc t0)
        // [1...m]: Các thông báo mới hơn lần lượt nhận t1 < t2 < ... < tm
        NSMutableArray<UNNotificationRequest *> *repostQueue = [NSMutableArray array];

        // A. Thêm thông báo vừa bấm vào hàng đợi đầu tiên
        UNMutableNotificationContent *tappedContent = zk_prepareContentCopy(tappedReq.content);
        UNNotificationRequest *repostTappedReq = [UNNotificationRequest requestWithIdentifier:tappedReq.identifier
                                                                                      content:tappedContent
                                                                                      trigger:nil];
        [repostQueue addObject:repostTappedReq];

        // B. Thêm các thông báo mới hơn vào sau để đảm bảo chúng luôn nằm TRÊN thông báo vừa bấm
        for (UNNotification *n in newerNotifications) {
            UNMutableNotificationContent *newerContent = zk_prepareContentCopy(n.request.content);
            UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:n.request.identifier
                                                                              content:newerContent
                                                                              trigger:nil];
            [repostQueue addObject:req];
        }

        NSLog(@"[ZaloKeepNotif] Executing Cascading Monotonic Re-order. Total items: %lu", (unsigned long)repostQueue.count);

        // Chạy quy trình nạp tuần tự trên main queue sau 0.25s khi SpringBoard đã ổn định view
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            zk_sequentialRepost(repostQueue, 0, ^{
                NSLog(@"[ZaloKeepNotif] Cascading Monotonic Re-order finished. Lockscreen order preserved perfectly!");
            });
        });
    }];
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
    if (delegate) {
        hookDelegate([delegate class]);
    }
    if (orig_setDelegate) {
        orig_setDelegate(self, _cmd, delegate);
    }
}

// ==========================================
// 6. CONSTRUCTOR
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Initializing v11 tweak (Fixed Overlay Button on Zalo Lockscreen + Cascading Monotonic Engine)...");

        // Hook UIViewController viewDidAppear để gắn nút cố định ngay trên màn hình khóa Zalo
        Class vcClass = objc_getClass("UIViewController");
        if (vcClass) {
            SwizzleMethod(vcClass,
                          @selector(viewDidAppear:),
                          @selector(zk_viewDidAppear:));
        }

        // Lắng nghe notification khi ứng dụng active hoặc window hiển thị
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            EnsureSettingsWindow();
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            EnsureSettingsWindow();
        }];

        // Đảm bảo hiển thị sớm trong chu kỳ khởi động
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EnsureSettingsWindow(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EnsureSettingsWindow(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EnsureSettingsWindow(); });

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
