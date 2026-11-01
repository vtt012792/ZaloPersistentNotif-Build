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

static void ShowGroupingSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) { window = w; break; }
                    }
                }
            }
        }
        if (!window) window = [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;

        UIViewController *rootVC = window.rootViewController;
        while (rootVC.presentedViewController) {
            rootVC = rootVC.presentedViewController;
        }
        if (!rootVC) return;

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
            alert.popoverPresentationController.sourceView = window;
            alert.popoverPresentationController.sourceRect = CGRectMake(window.bounds.size.width / 2, window.bounds.size.height / 2, 1, 1);
        }

        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

// NÚT BẤM NỔI (FLOATING BUTTON) TRỰC QUAN ĐỂ MỞ MENU CÀI ĐẶT
@interface ZKFloatingButton : UIButton
@end

@implementation ZKFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.95 alpha:0.85]; // Màu xanh Zalo
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 2.0;
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        [self setTitle:@"⚙️" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:22];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        [self addTarget:self action:@selector(btnTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [pan translationInView:superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW, MIN(newCenter.x, superview.bounds.size.width - halfW));
    newCenter.y = MAX(halfH + 44, MIN(newCenter.y, superview.bounds.size.height - halfH - 34));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:superview];

    if (pan.state == UIGestureRecognizerStateEnded) {
        CGFloat snapX = (newCenter.x < superview.bounds.size.width / 2.0) ? (halfW + 10) : (superview.bounds.size.width - halfW - 10);
        [UIView animateWithDuration:0.2 animations:^{
            self.center = CGPointMake(snapX, newCenter.y);
        }];
    }
}

- (void)btnTapped {
    ShowGroupingSettings();
}

@end

static ZKFloatingButton *sFloatingBtn = nil;
static void ensureFloatingButton(UIWindow *window) {
    if (!window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sFloatingBtn && sFloatingBtn.superview == window) return;

        if (!sFloatingBtn) {
            CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
            CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
            sFloatingBtn = [[ZKFloatingButton alloc] initWithFrame:CGRectMake(screenW - 56, screenH - 180, 46, 46)];
        }

        [window addSubview:sFloatingBtn];
        [window bringSubviewToFront:sFloatingBtn];
    });
}

@interface UIWindow (ZKFloatingHook)
@end

@implementation UIWindow (ZKFloatingHook)

- (void)zk_makeKeyAndVisible {
    [self zk_makeKeyAndVisible];
    ensureFloatingButton(self);
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
// 3. CASCADING MONOTONIC RE-ORDERING ENGINE (BẢO TOÀN THỨ TỰ 100%)
// ==========================================
static UNMutableNotificationContent *zk_prepareContentCopy(UNNotificationContent *origContent) {
    UNMutableNotificationContent *mc = [origContent mutableCopy];
    mc.sound = nil; // Tắt âm thanh
    mc.attachments = @[]; // Xóa attachments tạm tránh lỗi file temp

    // Chống sáng màn hình và chống bung popup
    @try { [mc setValue:@YES forKey:@"shouldSuppressScreenLightUp"]; } @catch (NSException *e) {}
    @try { [mc setValue:@YES forKey:@"shouldSuppressDefaultAction"]; } @catch (NSException *e) {}

    // Bảo tồn gom nhóm theo mode đã chọn
    mc.threadIdentifier = zk_determineThreadIdentifier(origContent);
    mc.categoryIdentifier = origContent.categoryIdentifier;

    // Đánh dấu cờ nội bộ để willPresentNotification nhận diện và dập tắt hoàn toàn popup
    NSMutableDictionary *u = [mc.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    u[@"zk_kept"] = @YES;
    mc.userInfo = u;

    return mc;
}

// Hàm re-post tuần tự đơn điệu để đảm bảo thứ tự thời gian chuẩn xác trong SQLite của usernoted
static void zk_sequentialRepost(NSArray<UNNotificationRequest *> *requests, NSUInteger index, void (^allDone)(void)) {
    if (index >= requests.count) {
        if (allDone) allDone();
        return;
    }

    UNNotificationRequest *req = requests[index];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"[ZaloKeepNotif] Sequential re-post failed for id: %@, error: %@", req.identifier, error);
        } else {
            NSLog(@"[ZaloKeepNotif] Monotonic update success (%lu/%lu): %@", (unsigned long)(index + 1), (unsigned long)requests.count, req.identifier);
        }

        // Khoảng trễ 20ms để usernoted tạo mốc thời gian millisecond tăng dần tuyệt đối
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.020 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            zk_sequentialRepost(requests, index + 1, allDone);
        });
    }];
}

// ==========================================
// 4. HOOK DELEGATE
// ==========================================
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>) = NULL;
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)) = NULL;
static void (*orig_didReceive)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)) = NULL;
static BOOL (*orig_respondsToSelector)(id, SEL, SEL) = NULL;

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    // Với tin nhắn re-post: TUYỆT ĐỐI KHÔNG BẬT POPUP/BANNER/SOUND
    NSDictionary *userInfo = notification.request.content.userInfo;
    if (userInfo && userInfo[@"zk_kept"]) {
        UNNotificationPresentationOptions keptOpts = 0;
        if (@available(iOS 14.0, *)) {
            keptOpts = (1 << 3); // UNNotificationPresentationOptionList ONLY
        }
        if (completionHandler) {
            completionHandler(keptOpts);
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
    // 1. Cho Zalo xử lý chuyển vào phòng chat bình thường
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
// 5. CONSTRUCTOR
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Initializing v10 tweak (Floating Button + Pure Cascading Monotonic Engine)...");

        // Hook UIWindow makeKeyAndVisible để gắn Nút Nổi trực quan
        Class winClass = objc_getClass("UIWindow");
        if (winClass) {
            SwizzleMethod(winClass,
                          @selector(makeKeyAndVisible),
                          @selector(zk_makeKeyAndVisible));
        }

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
