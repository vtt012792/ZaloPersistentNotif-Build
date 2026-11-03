#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dlfcn.h>

// ==========================================
// ZaloKeepNotif — Giai đoạn 0 (Phase 0: Probe)
// Thiết bị đích: iPhone iOS 16.5 (Dopamine roothide, arm64e)
// Hook: com.apple.springboard
// Mục đích: CHỈ GHI LOG chi tiết, KHÔNG CHẶN, để xác định:
//   1. Khóa dữ liệu trong push payload của Zalo (id, conv_id, grid, uid...)
//   2. Nguồn gọi và callstack khi thông báo bị rút/xóa
//   3. Sự kiện bấm (default action), vuốt xóa (dismiss), xóa cụm
//   4. Sự kiện cập nhật badge
// ==========================================

static NSString *const kZaloSectionID = @"com.vng.zalo";

// ==========================================
// ROOTHIDE LOG PATH RESOLVER
// ==========================================
static NSString *ZKGetLogPath(void) {
    static NSString *sCachedLogPath = nil;
    if (sCachedLogPath) return sCachedLogPath;

    // 1. Thử hàm jbroot() từ libroothide nếu có
    typedef const char *(*jbroot_c_func)(const char *);
    jbroot_c_func jbroot_fn = (jbroot_c_func)dlsym(RTLD_DEFAULT, "jbroot");
    if (jbroot_fn) {
        const char *p = jbroot_fn("/var/mobile/Library/Logs/ZaloKeepNotif.log");
        if (p && strlen(p) > 0) {
            sCachedLogPath = [NSString stringWithUTF8String:p];
            return sCachedLogPath;
        }
    }

    // 2. Mặc định ghi vào /var/mobile/Library/Logs/ZaloKeepNotif.log
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

    // 1. os_log (xem bằng Console.app hoặc oslog)
    static os_log_t sOSLog = nil;
    static dispatch_once_t onceOS;
    dispatch_once(&onceOS, ^{
        sOSLog = os_log_create("com.vtt.zalokeepnotif", "SpringBoard");
    });
    os_log(sOSLog, "[%{public}@] %{public}@", category, body);

    // 2. File log (xem bằng Filza / chép về máy tính)
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
// DUMP HELPER FOR NCNotificationRequest
// ==========================================
static NSString *ZKDumpRequest(id req) {
    if (!req) return @"(nil request)";
    NSMutableString *outStr = [NSMutableString string];

    @try {
        NSString *secId = [req valueForKey:@"sectionIdentifier"];
        NSString *notifId = [req valueForKey:@"notificationIdentifier"];
        NSString *threadId = [req valueForKey:@"threadIdentifier"];
        NSString *catId = [req valueForKey:@"categoryIdentifier"];
        NSDate *timestamp = [req valueForKey:@"timestamp"];

        [outStr appendFormat:@"secId=%@ | notifId=%@ | threadId=%@ | catId=%@ | time=%@",
         secId, notifId, threadId, catId, timestamp];

        id content = [req valueForKey:@"content"];
        if (content) {
            NSString *title = [content valueForKey:@"title"];
            NSString *subtitle = [content valueForKey:@"subtitle"];
            NSString *message = [content valueForKey:@"message"] ?: [content valueForKey:@"body"];
            NSString *header = [content valueForKey:@"header"];
            [outStr appendFormat:@"\n    [Content] header='%@' | title='%@' | sub='%@' | msg='%@'",
             header ?: @"", title ?: @"", subtitle ?: @"", message ?: @""];
        }

        id userNotif = [req valueForKey:@"userNotification"];
        if (userNotif) {
            id reqInner = [userNotif valueForKey:@"request"];
            id contentInner = [reqInner valueForKey:@"content"];
            NSDictionary *userInfo = [contentInner valueForKey:@"userInfo"];
            if (userInfo) {
                [outStr appendFormat:@"\n    [UserInfo Keys] %@", [userInfo allKeys]];
                [outStr appendFormat:@"\n    [UserInfo Dump] %@", userInfo];
            }
        }

        id context = [req valueForKey:@"context"];
        if (context) {
            [outStr appendFormat:@"\n    [Context] %@", context];
        }
    } @catch (NSException *e) {
        [outStr appendFormat:@"\n    [Exception dumping request: %@]", e];
    }

    return outStr;
}

// Lấy 6 khung stack trace đầu tiên (bỏ qua frame nội bộ) để xác định thủ phạm gọi
static NSString *ZKGetCallerTrace(void) {
    NSArray *symbols = [NSThread callStackSymbols];
    NSUInteger count = MIN((NSUInteger)8, symbols.count);
    NSArray *sub = [symbols subarrayWithRange:NSMakeRange(1, count - 1)];
    return [sub componentsJoinedByString:@"\n      "];
}

// ==========================================
// 1. HOOK NCNotificationDispatcher
// (Trung tâm điều phối thông báo trong UserNotificationsKit)
// ==========================================
@interface ZKHook_NCNotificationDispatcher : NSObject
@end

@implementation ZKHook_NCNotificationDispatcher

// A. Thông báo mới tới
- (void)zk_postNotificationWithRequest:(id)request {
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        ZKLog(@"POST_NEW", @"Incoming Zalo Notification:\n  %@\n  [Caller]\n      %@",
              ZKDumpRequest(request), ZKGetCallerTrace());
    }

    // Gọi hàm gốc (không can thiệp)
    [self zk_postNotificationWithRequest:request];
}

// B. Thông báo được sửa đổi/thay thế (gộp tin, cập nhật, thu hồi...)
- (void)zk_modifyNotificationWithRequest:(id)request {
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        ZKLog(@"MODIFY", @"Modified/Updated Zalo Notification:\n  %@\n  [Caller]\n      %@",
              ZKDumpRequest(request), ZKGetCallerTrace());
    }

    [self zk_modifyNotificationWithRequest:request];
}

// C. Lệnh rút/xóa thông báo
- (void)zk_withdrawNotificationWithRequest:(id)request {
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        ZKLog(@"WITHDRAW", @"Withdraw Zalo Notification:\n  %@\n  [Caller]\n      %@",
              ZKDumpRequest(request), ZKGetCallerTrace());
    }

    [self zk_withdrawNotificationWithRequest:request];
}

// D. Thực thi Action (Bấm vào thông báo, bấm nút trả lời nhanh, dismiss...)
- (void)zk_destination:(id)destination executeAction:(id)action forNotificationRequest:(id)request requestAuthentication:(BOOL)auth withParameters:(id)params completion:(id)completion {
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        NSString *actionId = nil;
        NSString *actionTitle = nil;
        @try {
            actionId = [action valueForKey:@"identifier"];
            actionTitle = [action valueForKey:@"title"];
        } @catch (NSException *e) {}

        ZKLog(@"EXEC_ACTION", @"Action on Zalo Notification:\n  actionId='%@' title='%@' dest='%@' auth=%d\n  %@\n  [Caller]\n      %@",
              actionId, actionTitle, [destination description], auth,
              ZKDumpRequest(request), ZKGetCallerTrace());
    }

    [self zk_destination:destination executeAction:action forNotificationRequest:request requestAuthentication:auth withParameters:params completion:completion];
}

// E. Người dùng vuốt xóa một thông báo
- (void)zk_destination:(id)destination didDismissNotificationRequest:(id)request {
    NSString *secId = nil;
    @try { secId = [request valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        ZKLog(@"USER_DISMISS", @"User dismissed Zalo notification:\n  dest='%@'\n  %@\n  [Caller]\n      %@",
              [destination description], ZKDumpRequest(request), ZKGetCallerTrace());
    }

    [self zk_destination:destination didDismissNotificationRequest:request];
}

// F. Xóa nhiều thông báo cùng lúc (ví dụ nút "Xóa" một nhóm hoặc "Xóa tất cả")
- (void)zk_destination:(id)destination requestsClearingNotificationRequests:(id)requests {
    BOOL hasZalo = NO;
    if ([requests isKindOfClass:[NSArray class]]) {
        for (id req in (NSArray *)requests) {
            NSString *sec = nil;
            @try { sec = [req valueForKey:@"sectionIdentifier"]; } @catch (NSException *e) {}
            if ([sec isEqualToString:kZaloSectionID]) {
                hasZalo = YES;
                break;
            }
        }
    }

    if (hasZalo) {
        ZKLog(@"CLEAR_GROUP", @"Clearing notification requests batch (has Zalo, count=%lu):\n  dest='%@'\n  [Caller]\n      %@",
              (unsigned long)[(NSArray *)requests count], [destination description], ZKGetCallerTrace());
    }

    [self zk_destination:destination requestsClearingNotificationRequests:requests];
}

@end

// ==========================================
// 2. HOOK BBServer (BulletinBoard)
// (Tầng kết nối giữa usernoted và SpringBoard)
// ==========================================
@interface ZKHook_BBServer : NSObject
@end

@implementation ZKHook_BBServer

- (void)zk_publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    NSString *secId = nil;
    @try { secId = [bulletin valueForKey:@"sectionID"]; } @catch (NSException *e) {}

    if ([secId isEqualToString:kZaloSectionID]) {
        NSString *bId = nil;
        NSString *recId = nil;
        NSDate *date = nil;
        @try {
            bId = [bulletin valueForKey:@"bulletinID"];
            recId = [bulletin valueForKey:@"recordID"];
            date = [bulletin valueForKey:@"date"];
        } @catch (NSException *e) {}

        ZKLog(@"BB_PUBLISH", @"BBServer publishBulletin for Zalo: bId=%@ recId=%@ date=%@ dest=%llu",
              bId, recId, date, destinations);
    }

    [self zk_publishBulletin:bulletin destinations:destinations];
}

- (void)zk_withdrawBulletinRequestsWithBulletinID:(NSString *)bulletinID {
    ZKLog(@"BB_WITHDRAW_ID", @"BBServer withdrawBulletinRequestsWithBulletinID: %@\n  [Caller]\n      %@",
          bulletinID, ZKGetCallerTrace());
    [self zk_withdrawBulletinRequestsWithBulletinID:bulletinID];
}

- (void)zk_withdrawBulletinsWithRecordID:(NSString *)recordID forSectionID:(NSString *)sectionID {
    if ([sectionID isEqualToString:kZaloSectionID]) {
        ZKLog(@"BB_WITHDRAW_RECORD", @"BBServer withdrawBulletinsWithRecordID: %@ for section: %@\n  [Caller]\n      %@",
              recordID, sectionID, ZKGetCallerTrace());
    }
    [self zk_withdrawBulletinsWithRecordID:recordID forSectionID:sectionID];
}

@end

// ==========================================
// 3. HOOK SBApplication / SBLeafIcon (BADGE)
// ==========================================
@interface ZKHook_SBApplication : NSObject
@end

@implementation ZKHook_SBApplication

- (void)zk_setBadgeValue:(id)badgeValue {
    NSString *bundleId = nil;
    @try { bundleId = [self valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) {}

    if ([bundleId isEqualToString:kZaloSectionID]) {
        ZKLog(@"BADGE_SET", @"SBApplication setBadgeValue for Zalo: value=%@\n  [Caller]\n      %@",
              badgeValue, ZKGetCallerTrace());
    }

    [self zk_setBadgeValue:badgeValue];
}

@end

// ==========================================
// 4. CONSTRUCTOR (KHỞI ĐỘNG TRONG SPRINGBOARD)
// ==========================================
__attribute__((constructor)) static void initZaloKeepNotifProbe() {
    @autoreleasepool {
        ZKLog(@"INIT", @"=======================================================");
        ZKLog(@"INIT", @"ZaloKeepNotif (Phase 0: Probe) successfully loaded into SpringBoard!");
        ZKLog(@"INIT", @"Target: iOS 16.5 Dopamine roothide (iphoneos-arm64e)");
        ZKLog(@"INIT", @"Log file destination: %@", ZKGetLogPath());
        ZKLog(@"INIT", @"=======================================================");

        // 1. Hook NCNotificationDispatcher
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
            ZKLog(@"INIT", @"Hooked NCNotificationDispatcher successfully.");
        } else {
            ZKLog(@"INIT", @"WARNING: NCNotificationDispatcher not found!");
        }

        // 2. Hook BBServer
        Class bbServerClass = objc_getClass("BBServer");
        if (bbServerClass) {
            SwizzleInstanceMethod(bbServerClass,
                                  @selector(publishBulletin:destinations:),
                                  @selector(zk_publishBulletin:destinations:));
            SwizzleInstanceMethod(bbServerClass,
                                  @selector(withdrawBulletinRequestsWithBulletinID:),
                                  @selector(zk_withdrawBulletinRequestsWithBulletinID:));
            SwizzleInstanceMethod(bbServerClass,
                                  @selector(withdrawBulletinsWithRecordID:forSectionID:),
                                  @selector(zk_withdrawBulletinsWithRecordID:forSectionID:));
            ZKLog(@"INIT", @"Hooked BBServer successfully.");
        } else {
            ZKLog(@"INIT", @"Note: BBServer not present in this process context.");
        }

        // 3. Hook SBApplication
        Class appClass = objc_getClass("SBApplication");
        if (appClass) {
            SwizzleInstanceMethod(appClass,
                                  @selector(setBadgeValue:),
                                  @selector(zk_setBadgeValue:));
            ZKLog(@"INIT", @"Hooked SBApplication setBadgeValue successfully.");
        }
    }
}
