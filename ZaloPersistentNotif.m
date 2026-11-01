#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

// Swizzling helper
static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL swizSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    if (origMethod && swizMethod) {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

@interface UNUserNotificationCenter (ZaloKeepNotif)
@end

@implementation UNUserNotificationCenter (ZaloKeepNotif)

- (void)zk_removeAllDeliveredNotifications {
    // Chặn xoá toàn bộ thông báo đang hiển thị
    NSLog(@"[ZaloKeepNotif] Blocked removeAllDeliveredNotifications");
}

- (void)zk_removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    // Chặn xoá thông báo theo id khi mở cuộc trò chuyện
    NSLog(@"[ZaloKeepNotif] Blocked removeDeliveredNotificationsWithIdentifiers: count=%lu", (unsigned long)identifiers.count);
}

@end

@interface UIApplication (ZaloKeepNotif)
@end

@implementation UIApplication (ZaloKeepNotif)

- (void)zk_setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    // Trên iOS, gọi setApplicationIconBadgeNumber: 0 sẽ tự động clear sạch Trung tâm thông báo.
    // Nếu badgeNumber == 0, ta bỏ qua không gọi hàm gốc để không bị mất thông báo trên lockscreen.
    // Tuyệt đối không truyền số âm (-1) vì SpringBoard sẽ báo lỗi.
    if (badgeNumber <= 0) {
        NSLog(@"[ZaloKeepNotif] Suppressed setApplicationIconBadgeNumber:%ld to prevent lockscreen clear", (long)badgeNumber);
        return;
    }
    [self zk_setApplicationIconBadgeNumber:badgeNumber];
}

@end

// Hook delegate để đảm bảo tin nhắn nhóm và tin nhắn mới luôn hiển thị banner + danh sách
static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);
static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions));

static void swiz_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
    // Đảm bảo thông báo (cả tin nhắn 1-1 và tin nhóm) luôn được hiện banner, âm thanh và lưu vào Notification List
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
        NSLog(@"[ZaloKeepNotif] Hooked willPresentNotification on delegate: %@", NSStringFromClass(delClass));
    }
}

static void swiz_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    orig_setDelegate(self, _cmd, delegate);
    if (delegate) {
        hookDelegateClass([delegate class]);
    }
}

__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Initializing for Zalo...");

        // 1. Hook UNUserNotificationCenter methods
        Class uncClass = objc_getClass("UNUserNotificationCenter");
        if (uncClass) {
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeAllDeliveredNotifications),
                                  @selector(zk_removeAllDeliveredNotifications));
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeDeliveredNotificationsWithIdentifiers:),
                                  @selector(zk_removeDeliveredNotificationsWithIdentifiers:));

            // Hook setDelegate: to catch Zalo's notification delegate
            Method setDelMethod = class_getInstanceMethod(uncClass, @selector(setDelegate:));
            if (setDelMethod) {
                orig_setDelegate = (void (*)(id, SEL, id<UNUserNotificationCenterDelegate>))method_getImplementation(setDelMethod);
                method_setImplementation(setDelMethod, (IMP)swiz_setDelegate);
            }

            // If delegate already assigned
            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            if (center.delegate) {
                hookDelegateClass([center.delegate class]);
            }

            NSLog(@"[ZaloKeepNotif] Successfully hooked UNUserNotificationCenter");
        }

        // 2. Hook UIApplication badge number
        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            SwizzleInstanceMethod(appClass,
                                  @selector(setApplicationIconBadgeNumber:),
                                  @selector(zk_setApplicationIconBadgeNumber:));
            NSLog(@"[ZaloKeepNotif] Successfully hooked UIApplication");
        }
    }
}
