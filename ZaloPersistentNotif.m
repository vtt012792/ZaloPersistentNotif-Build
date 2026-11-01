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
    // Intercept and do nothing: prevents Zalo from clearing delivered notifications on launch/resume
    NSLog(@"[ZaloKeepNotif] Blocked removeAllDeliveredNotifications");
}

- (void)zk_removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers {
    // Intercept automatic batch removal when opening conversations
    NSLog(@"[ZaloKeepNotif] Blocked removeDeliveredNotificationsWithIdentifiers: count=%lu", (unsigned long)identifiers.count);
}

@end

@interface UIApplication (ZaloKeepNotif)
@end

@implementation UIApplication (ZaloKeepNotif)

- (void)zk_setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    // In older iOS versions, setting badge to 0 clears Notification Center notifications.
    // If badge is 0, we set it to -1 internally or avoid the system call that clears notifications if needed.
    // Actually, calling original with -1 or keeping badge without clearing delivered notifs:
    if (badgeNumber == 0) {
        NSLog(@"[ZaloKeepNotif] Blocked setApplicationIconBadgeNumber:0 to preserve Notification Center");
        // We can pass -1 or call original with 0 only if it doesn't clear, but on iOS 0 clears NC.
        // Let's pass -1 or suppress:
        [self zk_setApplicationIconBadgeNumber:-1];
        return;
    }
    [self zk_setApplicationIconBadgeNumber:badgeNumber];
}

@end

__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        NSLog(@"[ZaloKeepNotif] Loaded into process: %@", [[NSProcessInfo processInfo] processName]);

        // Hook UNUserNotificationCenter
        Class uncClass = objc_getClass("UNUserNotificationCenter");
        if (uncClass) {
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeAllDeliveredNotifications),
                                  @selector(zk_removeAllDeliveredNotifications));
            SwizzleInstanceMethod(uncClass,
                                  @selector(removeDeliveredNotificationsWithIdentifiers:),
                                  @selector(zk_removeDeliveredNotificationsWithIdentifiers:));
            NSLog(@"[ZaloKeepNotif] Successfully hooked UNUserNotificationCenter");
        }

        // Hook UIApplication badge clearing
        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            SwizzleInstanceMethod(appClass,
                                  @selector(setApplicationIconBadgeNumber:),
                                  @selector(zk_setApplicationIconBadgeNumber:));
            NSLog(@"[ZaloKeepNotif] Successfully hooked UIApplication");
        }
    }
}
