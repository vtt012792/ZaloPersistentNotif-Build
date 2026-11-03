#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

// ==========================================
// ZaloKeepNotif — Phase 1: Pure Persistence
// Thiết bị đích: iPhone iOS 16.5 (Dopamine roothide, arm64e)
// Filter: com.apple.springboard
// Mục tiêu:
//   1. Thông báo Zalo không bao giờ mất khi nhấn vào (tap opens Zalo, notif stays).
//   2. Giữ nguyên vị trí và mốc thời gian gốc (không xóa, không đăng lại, không đổi giờ).
//   3. Chặn triệt để mọi lệnh rút/xóa từ Zalo app, usernoted, push thu hồi, web.
//   4. CHỈ XÓA KHI NGƯỜI DÙNG CHỦ ĐỘNG XÓA (vuốt xóa hoặc bấm nút "Xóa tất cả").
//   5. Thông báo mới gộp/thay thế sẽ được giữ cả cũ lẫn mới như thông báo độc lập.
// ==========================================

static NSString *const kZaloSectionID = @"com.vng.zalo";

// Trạng thái thread-local đánh dấu hành động do người dùng chủ động xóa
static __thread BOOL t_isUserClearing = NO;

// Trạng thái thread-local đánh dấu đang thực thi action bấm mở app Zalo
static __thread BOOL t_isExecutingZaloAction = NO;

// Danh sách lưu các notificationIdentifier do người dùng chủ động vuốt xóa
static NSMutableSet<NSString *> *sUserDismissedNotificationIDs = nil;

// Danh sách theo dõi các notificationIdentifier Zalo đang tồn tại để giữ cả cũ lẫn mới
static NSMutableSet<NSString *> *sActiveZaloNotificationIDs = nil;

static inline void ZKInitSets(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sUserDismissedNotificationIDs = [[NSMutableSet alloc] init];
        sActiveZaloNotificationIDs = [[NSMutableSet alloc] init];
    });
}

// ==========================================
// ROOTHIDE LOG PATH RESOLVER
// ==========================================
static NSString *ZKGetLogPath(void) {
    static NSString *sCachedLogPath = nil;
    if (sCachedLogPath) return sCachedLogPath;

    typedef const char *(*jbroot_c_func)(const char *);
    jbroot_c_func jbroot_fn = (jbroot_c_func)dlsym(RTLD_DEFAULT, "jbroot");
    if (jbroot_fn) {
        const char *p = jbroot_fn("/var/mobile/Library/Logs/ZaloKeepNotif.log");
        if (p && strlen(p) > 0) {
            sCachedLogPath = [NSString stringWithUTF8String:p];
            return sCachedLogPath;
        }
    }

    sCachedLogPath = @"/var/mobile/Library/Logs/ZaloKeepNotif.log";
    return sCachedLogPath;
}

// ==========================================
// THREAD-SAFE LOGGER (os_log + file)
// ==========================================
static void ZKLog(NSString *category, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static os_log_t sOSLog = nil;
    static dispatch_once_t onceOS;
    dispatch_once(&onceOS, ^{
        sOSLog = os_log_create("com.vtt.zalokeepnotif", "SpringBoard");
    });
    os_log(sOSLog, "[%{public}@] %{public}@", category, body);

    static dispatch_queue_t sLogQueue = nil;
    static dispatch_once_t onceQueue;
    dispatch_once(&onceQueue, ^{
        sLogQueue = dispatch_queue_create("com.vtt.zalokeepnotif.logger", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(sLogQueue, ^{
        @autoreleasepool {
            NSString *logPath = ZKGetLogPath();
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            [df setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
            NSString *timeStr = [df stringFromDate:[NSDate date]];

            NSString *line = [NSString stringWithFormat:@"[%@] [%@] %@\n", timeStr, category, body];

            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *logDir = [logPath stringByDeletingLastPathComponent];
            if (![fm fileExistsAtPath:logDir]) {
                [fm createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
            }

            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (!handle) {
                [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [handle seekToEndOfFile];
                [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [handle closeFile];
            }
        }
    });
}

// ==========================================
// SWIZZLING HELPER
// ==========================================
static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL swizSel) {
    if (!cls) return;
    Method orig = class_getInstanceMethod(cls, origSel);
    Method swiz = class_getInstanceMethod(cls, swizSel);
    if (!orig || !swiz) return;

    BOOL didAdd = class_addMethod(cls, origSel,
                                  method_getImplementation(swiz),
                                  method_getTypeEncoding(swiz));
    if (didAdd) {
        class_replaceMethod(cls, swizSel,
                            method_getImplementation(orig),
                            method_getTypeEncoding(orig));
    } else {
        method_exchangeImplementations(orig, swiz);
    }
}

// ==========================================
// 1. HOOK NCNotificationAction
// Chặn SpringBoard tự đóng thông báo khi bấm mở app
// ==========================================
@interface ZKHook_NCNotificationAction : NSObject
@end

@implementation ZKHook_NCNotificationAction

- (BOOL)zk_shouldDismissNotification {
    if (t_isExecutingZaloAction) {
        ZKLog(@"ACTION", @"Forced shouldDismissNotification = NO during Zalo action execution.");
        return NO;
    }

    NSString *bundle = nil;
    @try { bundle = [self valueForKey:@"launchBundleID"]; } @catch (NSException *e) {}
    if ([bundle isEqualToString:kZaloSectionID]) {
        ZKLog(@"ACTION", @"Forced shouldDismissNotification = NO for Zalo launchBundleID.");
        return NO;
    }

    return [self zk_shouldDismissNotification];
}

@end

// ==========================================
// 2. HOOK NCNotificationOptions
// Giữ thông báo luôn nằm trên Lockscreen và không bao giờ tự đóng
// ==========================================
@interface ZKHook_NCNotificationOptions : NSObject
@end

@implementation ZKHook_NCNotificationOptions

- (BOOL)zk_dismissAutomatically {
    id isZalo = objc_getAssociatedObject(self, "kIsZaloOptions");
    if ([isZalo boolValue]) {
        return NO;
    }
    return [self zk_dismissAutomatically];
}

- (unsigned long long)zk_lockScreenPersistence {
    id isZalo = objc_getAssociatedObject(self, "kIsZaloOptions");
    if ([isZalo boolValue]) {
        // 1 = Persistent (luôn giữ trên màn hình khóa)
        return 1;
    }
    return [self zk_lockScreenPersistence];
}

@end

// ==========================================
// 3. HOOK NCNotificationDispatcher
// Trung tâm điều phối hiển thị và thu hồi thông báo trong SpringBoard
// ==========================================
@interface ZKHook_NCNotificationDispatcher : NSObject
@end

@implementation ZKHook_NCNotificationDispatcher

// A. Thông báo mới tới
- (void)zk_postNotificationWithRequest:(id)request {
    ZKInitSets();
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        NSString *notifId = nil;
        @try { notifId = [request valueForKey:@"notificationIdentifier"]; } @catch (NSException *e) {}

        // Đánh dấu options để không tự dismiss và giữ persistent
        id options = nil;
        @try { options = [request valueForKey:@"options"]; } @catch (NSException *e) {}
        if (options) {
            objc_setAssociatedObject(options, "kIsZaloOptions", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { [options setValue:@(NO) forKey:@"dismissAutomatically"]; } @catch (NSException *e) {}
            @try { [options setValue:@(1) forKey:@"lockScreenPersistence"]; } @catch (NSException *e) {}
        }

        // Đánh dấu defaultAction không dismiss
        id defaultAction = nil;
        @try { defaultAction = [request valueForKey:@"defaultAction"]; } @catch (NSException *e) {}
        if (defaultAction) {
            @try { [defaultAction setValue:@(NO) forKey:@"shouldDismissNotification"]; } @catch (NSException *e) {}
        }

        // Nếu thông báo với ID này đã tồn tại, biến nó thành ID mới độc lập để giữ cả cũ lẫn mới
        if (notifId) {
            @synchronized(sActiveZaloNotificationIDs) {
                if ([sActiveZaloNotificationIDs containsObject:notifId]) {
                    NSString *uniqueId = [NSString stringWithFormat:@"%@#%llu", notifId, mach_absolute_time()];
                    @try { [request setValue:uniqueId forKey:@"notificationIdentifier"]; } @catch (NSException *e) {}
                    ZKLog(@"POST_COLLAPSE", @"Zalo duplicate notifId=%@ -> generated uniqueId=%@ to retain both!", notifId, uniqueId);
                    notifId = uniqueId;
                }
                [sActiveZaloNotificationIDs addObject:notifId];
            }
        }

        ZKLog(@"POST_ZALO", @"Posted persistent Zalo notification: notifId=%@", notifId);
    }

    [self zk_postNotificationWithRequest:request];
}

// B. Thông báo được sửa đổi/thay thế (gộp tin, cập nhật)
- (void)zk_modifyNotificationWithRequest:(id)request {
    ZKInitSets();
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        // Thay vì ghi đè thông báo cũ làm mất tin cũ hoặc đổi giờ,
        // ta tạo ID độc lập và post như một thông báo mới toanh!
        NSString *origId = nil;
        @try { origId = [request valueForKey:@"notificationIdentifier"]; } @catch (NSException *e) {}
        NSString *uniqueId = [NSString stringWithFormat:@"%@#mod_%llu", origId ?: @"zalo", mach_absolute_time()];
        @try { [request setValue:uniqueId forKey:@"notificationIdentifier"]; } @catch (NSException *e) {}

        id options = nil;
        @try { options = [request valueForKey:@"options"]; } @catch (NSException *e) {}
        if (options) {
            objc_setAssociatedObject(options, "kIsZaloOptions", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { [options setValue:@(NO) forKey:@"dismissAutomatically"]; } @catch (NSException *e) {}
            @try { [options setValue:@(1) forKey:@"lockScreenPersistence"]; } @catch (NSException *e) {}
        }

        id defaultAction = nil;
        @try { defaultAction = [request valueForKey:@"defaultAction"]; } @catch (NSException *e) {}
        if (defaultAction) {
            @try { [defaultAction setValue:@(NO) forKey:@"shouldDismissNotification"]; } @catch (NSException *e) {}
        }

        @synchronized(sActiveZaloNotificationIDs) {
            [sActiveZaloNotificationIDs addObject:uniqueId];
        }

        ZKLog(@"MODIFY_CONVERT", @"Converted modifyNotification for Zalo to new post: origId=%@ -> newId=%@", origId, uniqueId);
        [self zk_postNotificationWithRequest:request];
        return;
    }

    [self zk_modifyNotificationWithRequest:request];
}

// C. LỆNH RÚT/XÓA THÔNG BÁO — CHẶN TRIỆT ĐỂ NẾU KHÔNG PHẢI DO NGƯỜI DÙNG XÓA
- (void)zk_withdrawNotificationWithRequest:(id)request {
    ZKInitSets();
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        NSString *notifId = nil;
        @try { notifId = [request valueForKey:@"notificationIdentifier"]; } @catch (NSException *e) {}

        BOOL isExplicitUserDismiss = NO;
        if (t_isUserClearing) {
            isExplicitUserDismiss = YES;
        } else if (notifId) {
            @synchronized(sUserDismissedNotificationIDs) {
                if ([sUserDismissedNotificationIDs containsObject:notifId]) {
                    isExplicitUserDismiss = YES;
                    [sUserDismissedNotificationIDs removeObject:notifId];
                }
            }
        }

        if (!isExplicitUserDismiss) {
            // ĐÂY LÀ LỆNH RÚT TỰ ĐỘNG (DO ZALO MỞ, ĐỌC TRÊN WEB, HOẶC IOS BẤM MỞ).
            // CHẶN HOÀN TOÀN! KHÔNG GỌI HÀM GỐC!
            ZKLog(@"BLOCK_WITHDRAW", @"[BLOCKED] Suppressed withdrawal of Zalo notification: notifId=%@", notifId);
            return;
        }

        // Người dùng tự xóa -> Cho phép xóa và dọn khỏi danh sách theo dõi
        @synchronized(sActiveZaloNotificationIDs) {
            if (notifId) [sActiveZaloNotificationIDs removeObject:notifId];
        }
        ZKLog(@"USER_WITHDRAW", @"[ALLOWED] Permitted user-initiated withdrawal: notifId=%@", notifId);
    }

    [self zk_withdrawNotificationWithRequest:request];
}

// D. Bấm vào thông báo (Default Action)
- (void)zk_destination:(id)destination executeAction:(id)action forNotificationRequest:(id)request requestAuthentication:(BOOL)auth withParameters:(id)params completion:(id)completion {
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    BOOL isZalo = [secId isEqualToString:kZaloSectionID];
    if (isZalo) {
        t_isExecutingZaloAction = YES;
        NSString *notifId = nil;
        @try { notifId = [request valueForKey:@"notificationIdentifier"]; } @catch (NSException *e) {}
        ZKLog(@"EXEC_TAP", @"User tapped Zalo notification (launching Zalo, keeping notif): notifId=%@", notifId);
    }

    @try {
        [self zk_destination:destination executeAction:action forNotificationRequest:request requestAuthentication:auth withParameters:params completion:completion];
    } @finally {
        if (isZalo) {
            t_isExecutingZaloAction = NO;
        }
    }
}

// E. Người dùng vuốt xóa 1 thông báo
- (void)zk_destination:(id)destination didDismissNotificationRequest:(id)request {
    ZKInitSets();
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        NSString *notifId = nil;
        @try { notifId = [request valueForKey:@"notificationIdentifier"]; } @catch (NSException *e) {}
        if (notifId) {
            @synchronized(sUserDismissedNotificationIDs) {
                [sUserDismissedNotificationIDs addObject:notifId];
            }
        }
        ZKLog(@"USER_SWIPE", @"User swiped to delete Zalo notification: notifId=%@", notifId);
    }

    t_isUserClearing = YES;
    @try {
        [self zk_destination:destination didDismissNotificationRequest:request];
    } @finally {
        t_isUserClearing = NO;
    }
}

// F. Người dùng bấm nút "Xóa tất cả" / Xóa một nhóm
- (void)zk_destination:(id)destination requestsClearingNotificationRequests:(id)requests {
    ZKInitSets();
    if ([requests isKindOfClass:[NSArray class]]) {
        for (id req in (NSArray *)requests) {
            NSString *sec = nil;
            @try { sec = [req valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}
            if ([sec isEqualToString:kZaloSectionID]) {
                NSString *nid = nil;
                @try { nid = [req valueForKey:@"notificationIdentifier"]; } @catch (NSException *e) {}
                if (nid) {
                    @synchronized(sUserDismissedNotificationIDs) {
                        [sUserDismissedNotificationIDs addObject:nid];
                    }
                }
            }
        }
    }

    t_isUserClearing = YES;
    @try {
        [self zk_destination:destination requestsClearingNotificationRequests:requests];
    } @finally {
        t_isUserClearing = NO;
    }
}

- (void)zk_destination:(id)destination requestsClearingNotificationRequests:(id)requests fromDestinations:(id)dests {
    ZKInitSets();
    if ([requests isKindOfClass:[NSArray class]]) {
        for (id req in (NSArray *)requests) {
            NSString *sec = nil;
            @try { sec = [req valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}
            if ([sec isEqualToString:kZaloSectionID]) {
                NSString *nid = nil;
                @try { nid = [req valueForKey:@"notificationIdentifier"]; } @catch (NSException *e) {}
                if (nid) {
                    @synchronized(sUserDismissedNotificationIDs) {
                        [sUserDismissedNotificationIDs addObject:nid];
                    }
                }
            }
        }
    }

    t_isUserClearing = YES;
    @try {
        [self zk_destination:destination requestsClearingNotificationRequests:requests fromDestinations:dests];
    } @finally {
        t_isUserClearing = NO;
    }
}

@end

// ==========================================
// 4. HOOK BBServer (BulletinBoard)
// Chặn lệnh rút thông báo từ tầng BulletinBoard
// ==========================================
@interface ZKHook_BBServer : NSObject
@end

@implementation ZKHook_BBServer

- (void)zk_withdrawBulletinsWithRecordID:(NSString *)recordID forSectionID:(NSString *)sectionID {
    if ([sectionID isEqualToString:kZaloSectionID]) {
        if (!t_isUserClearing) {
            ZKLog(@"BB_BLOCK", @"[BLOCKED] BBServer withdrawBulletinsWithRecordID: %@ for section: %@", recordID, sectionID);
            return;
        }
        ZKLog(@"BB_ALLOW", @"[ALLOWED] BBServer withdrawBulletinsWithRecordID: %@ (user cleared)", recordID);
    }
    [self zk_withdrawBulletinsWithRecordID:recordID forSectionID:sectionID];
}

- (void)zk_withdrawBulletinRequestsWithBulletinID:(NSString *)bulletinID {
    if (!t_isUserClearing) {
        ZKLog(@"BB_BLOCK_ID", @"[SUPPRESS] BBServer withdrawBulletinRequestsWithBulletinID: %@", bulletinID);
    }
    [self zk_withdrawBulletinRequestsWithBulletinID:bulletinID];
}

@end

// ==========================================
// 5. HOOK SBApplication (Icon Badge)
// Giữ số badge theo số thông báo Zalo thực tế còn lưu, không cho Zalo tự reset về 0
// ==========================================
@interface ZKHook_SBApplication : NSObject
@end

@implementation ZKHook_SBApplication

- (void)zk_setBadgeValue:(id)badgeValue {
    NSString *bundleId = nil;
    @try { bundleId = [self valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) {}

    if ([bundleId isEqualToString:kZaloSectionID]) {
        ZKInitSets();
        NSUInteger activeCount = 0;
        @synchronized(sActiveZaloNotificationIDs) {
            activeCount = sActiveZaloNotificationIDs.count;
        }

        // Nếu Zalo cố xóa badge về 0 / nil nhưng ta vẫn còn thông báo chưa đọc trên lockscreen:
        if ((!badgeValue || [badgeValue isEqual:@0] || [badgeValue isEqual:@"0"] || [badgeValue isEqual:@""]) && activeCount > 0) {
            ZKLog(@"BADGE_OVERRIDE", @"Zalo tried to reset badge to 0, overridden with activeCount=%lu", (unsigned long)activeCount);
            badgeValue = [NSNumber numberWithUnsignedInteger:activeCount];
        }
    }

    [self zk_setBadgeValue:badgeValue];
}

@end

// ==========================================
// 6. CONSTRUCTOR (Nạp vào SpringBoard)
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotif() {
    @autoreleasepool {
        ZKLog(@"INIT", @"=======================================================");
        ZKLog(@"INIT", @"ZaloKeepNotif (Phase 1: Persistent Lockscreen) Loaded!");
        ZKLog(@"INIT", @"Target: iOS 16.5 Dopamine RootHide (arm64e)");
        ZKLog(@"INIT", @"Section: %@", kZaloSectionID);
        ZKLog(@"INIT", @"=======================================================");

        // 1. Hook NCNotificationAction
        Class actionClass = objc_getClass("NCNotificationAction");
        if (actionClass) {
            SwizzleInstanceMethod(actionClass,
                                  @selector(shouldDismissNotification),
                                  @selector(zk_shouldDismissNotification));
            ZKLog(@"INIT", @"Hooked NCNotificationAction shouldDismissNotification");
        }

        // 2. Hook NCNotificationOptions
        Class optionsClass = objc_getClass("NCNotificationOptions");
        if (optionsClass) {
            SwizzleInstanceMethod(optionsClass,
                                  @selector(dismissAutomatically),
                                  @selector(zk_dismissAutomatically));
            SwizzleInstanceMethod(optionsClass,
                                  @selector(lockScreenPersistence),
                                  @selector(zk_lockScreenPersistence));
            ZKLog(@"INIT", @"Hooked NCNotificationOptions dismissAutomatically & lockScreenPersistence");
        }

        // 3. Hook NCNotificationDispatcher
        Class dispClass = objc_getClass("NCNotificationDispatcher");
        if (dispClass) {
            SwizzleInstanceMethod(dispClass,
                                  @selector(postNotificationWithRequest:),
                                  @selector(zk_postNotificationWithRequest:));
            SwizzleInstanceMethod(dispClass,
                                  @selector(modifyNotificationWithRequest:),
                                  @selector(zk_modifyNotificationWithRequest:));
            SwizzleInstanceMethod(dispClass,
                                  @selector(withdrawNotificationWithRequest:),
                                  @selector(zk_withdrawNotificationWithRequest:));
            SwizzleInstanceMethod(dispClass,
                                  @selector(destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:),
                                  @selector(zk_destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:));
            SwizzleInstanceMethod(dispClass,
                                  @selector(destination:didDismissNotificationRequest:),
                                  @selector(zk_destination:didDismissNotificationRequest:));
            SwizzleInstanceMethod(dispClass,
                                  @selector(destination:requestsClearingNotificationRequests:),
                                  @selector(zk_destination:requestsClearingNotificationRequests:));
            SwizzleInstanceMethod(dispClass,
                                  @selector(destination:requestsClearingNotificationRequests:fromDestinations:),
                                  @selector(zk_destination:requestsClearingNotificationRequests:fromDestinations:));
            ZKLog(@"INIT", @"Hooked NCNotificationDispatcher successfully.");
        }

        // 4. Hook BBServer
        Class bbServerClass = objc_getClass("BBServer");
        if (bbServerClass) {
            SwizzleInstanceMethod(bbServerClass,
                                  @selector(withdrawBulletinsWithRecordID:forSectionID:),
                                  @selector(zk_withdrawBulletinsWithRecordID:forSectionID:));
            SwizzleInstanceMethod(bbServerClass,
                                  @selector(withdrawBulletinRequestsWithBulletinID:),
                                  @selector(zk_withdrawBulletinRequestsWithBulletinID:));
            ZKLog(@"INIT", @"Hooked BBServer successfully.");
        }

        // 5. Hook SBApplication
        Class appClass = objc_getClass("SBApplication");
        if (appClass) {
            SwizzleInstanceMethod(appClass,
                                  @selector(setBadgeValue:),
                                  @selector(zk_setBadgeValue:));
            ZKLog(@"INIT", @"Hooked SBApplication setBadgeValue successfully.");
        }
    }
}
