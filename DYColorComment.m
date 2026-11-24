// DYColorComment 0.1.1~safe2 —— 抖音评论黄字探针（TrollFools 注入，无 substrate）
//
// 0.1.1 相对 probe5 的改动（都是崩因）：
//   1. 删除 +[NSJSONSerialization dataWithJSONObject:options:error:] hook
//      旧版在 hook 里再次调用被 hook 的方法 → 无限递归 → 栈溢出闪退。
//   2. 删除 setHTTPBodyStream: hook；setHTTPBody: 只处理 <=64KB 的 body，
//      避免对超大二进制 body 做 UTF8 解码（内存/CPU 暴涨被 jetsam 杀）。
//   3. 类扫描不再在 constructor 里跑，改为启动 4 秒后在后台队列执行。
//   4. 悬浮窗改为 60x60 的小窗口（原来全屏透明窗口会吃掉全部触摸），
//      并让 hitTest 只命中按钮。
//   5. 每个 hook 全部 @try 包裹 + 计数，任何一步失败只记日志不抛。
//   6. 阶段标记实时追加落盘，闪退后重开抖音点球仍能看到上次卡在哪一步。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DY_MAX_LINES 800
#define DY_MAX_PAYLOAD 65536

static NSMutableArray<NSString *> *gLines = nil;
static NSMutableSet<NSString *> *gSeen = nil;
static NSLock *gLock = nil;
static NSString *gLogPath = nil;
static NSString *gMethodMap = nil;

static int gCountAttr = 0;
static int gCountBody = 0;
static int gCountMatch = 0;

// 阶段标记：立即追加落盘，用来定位闪退位置
static void DYStage(const char *tag, NSString *detail) {
    @try {
        if (!gLogPath) return;
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"[stage] %s", tag];
        if (detail.length) [s appendFormat:@" %@", detail];
        [s appendString:@"\n"];
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:gLogPath]) {
            [d writeToFile:gLogPath atomically:NO];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

static void DYLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!s || !gLock) return;
    [gLock lock];
    if (gLines.count < DY_MAX_LINES) [gLines addObject:s];
    [gLock unlock];
}

static BOOL DYWorthLogging(NSString *key) {
    if (!key) return YES;
    NSString *h = [NSString stringWithFormat:@"%lu", (unsigned long)key.hash];
    BOOL seen = YES;
    [gLock lock];
    if (gSeen.count < 300) {
        seen = [gSeen containsObject:h];
        if (!seen) [gSeen addObject:h];
    }
    [gLock unlock];
    return !seen;
}

static NSString *DYTrunc(NSString *s, NSUInteger n) {
    if (!s) return @"(nil)";
    if (s.length <= n) return s;
    return [[s substringToIndex:n] stringByAppendingString:@"…"];
}

static BOOL DYLooksInteresting(NSString *s) {
    if (s.length < 6) return NO;
    if ([s containsString:@"text_extra"]) return YES;
    if ([s containsString:@"comment"] && ([s containsString:@"aweme_id"] || [s containsString:@"reply_id"])) return YES;
    return NO;
}

// ---------------------------------------------------------------- hooks

// 输入框富文本：@ 的 mention attribute 就在这里
// UITextView 与 UITextField 必须各存一份 orig，共用会互相覆盖成死循环
static void (*dy_origTVAttr)(id, SEL, NSAttributedString *);
static void (*dy_origTfAttr)(id, SEL, NSAttributedString *);

static void DYRecordAttrs(id self, NSAttributedString *s, const char *which) {
    if (![s isKindOfClass:[NSAttributedString class]] || s.length < 3 || s.length > 4000) return;
    gCountAttr++;
    NSMutableString *buf = [NSMutableString string];
    __block NSUInteger dumped = 0;
    [s enumerateAttributesInRange:NSMakeRange(0, s.length) options:0
                       usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange r, BOOL *stop) {
        if (dumped++ >= 5) { *stop = YES; return; }
        NSString *txt = (r.location + r.length <= s.string.length)
                          ? [s.string substringWithRange:r] : @"?";
        [buf appendFormat:@"  range=%lu,%lu text=%@\n  attrs=%@\n",
                          (unsigned long)r.location, (unsigned long)r.length,
                          DYTrunc(txt, 40), attrs];
    }];
    if (!buf.length) return;
    if (!DYWorthLogging(buf)) return;
    DYLog(@"[attr %s] cls=%@ len=%lu\n%@", which, [self class], (unsigned long)s.length, buf);
}

static void dy_tvAttr(id self, SEL _cmd, NSAttributedString *s) {
    @try { @autoreleasepool { DYRecordAttrs(self, s, "UITextView"); } } @catch (__unused NSException *e) {}
    dy_origTVAttr(self, _cmd, s);
}

static void dy_tfAttr(id self, SEL _cmd, NSAttributedString *s) {
    @try { @autoreleasepool { DYRecordAttrs(self, s, "UITextField"); } } @catch (__unused NSException *e) {}
    dy_origTfAttr(self, _cmd, s);
}

// 网络 body：只碰 <=64KB 且能按 UTF8 解出关键词的
static void (*dy_origBody)(id, SEL, NSData *);
static void dy_setBody(id self, SEL _cmd, NSData *body) {
    dy_origBody(self, _cmd, body);
    @try {
        @autoreleasepool {
            if ([body isKindOfClass:[NSData class]] && body.length > 8 && body.length <= DY_MAX_PAYLOAD) {
                gCountBody++;
                NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
                if (s && DYLooksInteresting(s) && DYWorthLogging(s)) {
                    gCountMatch++;
                    NSString *url = @"?";
                    @try { url = DYTrunc([[self valueForKey:@"URL"] description], 200); } @catch (__unused NSException *e) {}
                    DYLog(@"[body] len=%lu url=%@\n---\n%@\n---", (unsigned long)body.length, url, DYTrunc(s, 6000));
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

static void DYSwizzleInstance(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls || !sel || !newImp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (old == newImp) return;
    if (outOrig) *outOrig = old;
    method_setImplementation(m, newImp);
}

// ---------------------------------------------------------------- 类扫描（后台）

static BOOL DYNameInteresting(NSString *n) {
    NSString *lower = n.lowercaseString;
    if ([lower containsString:@"comment"]) return YES;
    if ([lower containsString:@"textinput"] || [lower containsString:@"textedit"]) return YES;
    if ([lower containsString:@"mention"]) return YES;
    if ([lower containsString:@"imedit"] || [lower containsString:@"richedit"]) return YES;
    return NO;
}

static void DYScanRuntime(void) {
    @autoreleasepool {
        DYStage("scan-begin", nil);
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) { DYStage("scan-empty", nil); return; }
        Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
        if (!classes) { DYStage("scan-nomem", nil); return; }
        count = objc_getClassList(classes, count);

        NSMutableString *out = [NSMutableString stringWithCapacity:64 * 1024];
        NSInteger hits = 0;
        for (int i = 0; i < count && hits < 90; i++) {
            @autoreleasepool {
                Class c = classes[i];
                const char *nm = class_getName(c);
                if (!nm) continue;
                NSString *name = [NSString stringWithUTF8String:nm];
                if (!name || !DYNameInteresting(name)) continue;
                hits++;
                Class sc = class_getSuperclass(c);
                [out appendFormat:@"CLASS %@ : %@\n", name,
                                   sc ? [NSString stringWithUTF8String:class_getName(sc)] : @"-"];
                unsigned int mc = 0;
                Method *ms = class_copyMethodList(c, &mc);
                if (ms) {
                    NSInteger shown = 0;
                    for (unsigned int j = 0; j < mc && shown < 25; j++) {
                        NSString *sel = NSStringFromSelector(method_getName(ms[j]));
                        NSString *ls = sel.lowercaseString;
                        if ([ls containsString:@"send"] || [ls containsString:@"publish"] ||
                            [ls containsString:@"post"] || [ls containsString:@"reply"] ||
                            [ls containsString:@"submit"] || [ls containsString:@"mention"] ||
                            [ls containsString:@"insert"] || [ls containsString:@"text"]) {
                            [out appendFormat:@"   -%@  %s\n", sel, method_getTypeEncoding(ms[j])];
                            shown++;
                        }
                    }
                    if (shown == 0) {
                        [out appendString:@"   (无关键词) 前5:"];
                        for (unsigned int j = 0; j < mc && j < 5; j++) {
                            [out appendFormat:@" %@", NSStringFromSelector(method_getName(ms[j]))];
                        }
                        [out appendString:@"\n"];
                    }
                    free(ms);
                }
                if (out.length > 90 * 1024) break;
            }
        }
        free(classes);
        gMethodMap = [out copy];
        DYLog(@"[scan] 命中相关类 %ld 个", (long)hits);
        DYStage("scan-done", [NSString stringWithFormat:@"hits=%ld", (long)hits]);
    }
}

// ---------------------------------------------------------------- 悬浮球

@interface DYWindow : UIWindow
@end
@interface DYBall : NSObject
+ (void)pan:(UIPanGestureRecognizer *)g;
+ (void)doCopy;
@end

static DYWindow *gWin = nil;

@implementation DYWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFocused { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (!v || v == self.rootViewController.view) return nil;
    return v;
}
@end

static void DYCopyLog(void);

@implementation DYBall
+ (void)doCopy { DYCopyLog(); }
+ (void)pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateEnded) {
        CGPoint t = [g translationInView:nil];
        UIWindow *w = g.view.window;
        if (w) {
            w.center = CGPointMake(w.center.x + t.x, w.center.y + t.y);
            [g setTranslation:CGPointZero inView:nil];
        }
    }
}
@end

static NSString *DYCurrentLog(void) {
    NSMutableString *all = [NSMutableString string];
    if (gMethodMap.length) { [all appendString:gMethodMap]; [all appendString:@"\n\n"]; }
    [gLock lock];
    for (NSString *s in gLines) { [all appendString:s]; [all appendString:@"\n"]; }
    [gLock unlock];
    return all;
}

static void DYCopyLog(void) {
    @try {
        NSMutableString *all = [NSMutableString string];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (gLogPath && [fm fileExistsAtPath:gLogPath]) {
            NSString *hist = [NSString stringWithContentsOfFile:gLogPath encoding:NSUTF8StringEncoding error:NULL];
            if (hist.length) { [all appendString:@"### 磁盘阶段记录 ###\n"]; [all appendString:hist]; [all appendString:@"\n\n"]; }
        }
        [all appendString:@"### 本次运行内存日志 ###\n"];
        [all appendString:DYCurrentLog()];
        [all appendFormat:@"\n[hooks] attr=%d body=%d match=%d\n", gCountAttr, gCountBody, gCountMatch];

        [UIPasteboard generalPasteboard].string = all;

        UIViewController *root = gWin.rootViewController;
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"已复制 %lu 字符", (unsigned long)all.length]
                             message:@"粘贴发出去即可"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [root presentViewController:ac animated:YES completion:nil];
    } @catch (__unused NSException *e) {}
}

static void DYBuildUI(void) {
    @try {
        if (gWin) return;
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            DYStage("ui-skip", @"not active");
            return;
        }
        // 只有 60x60 的小窗口，物理上不会盖住视频区域
        DYWindow *w = [[DYWindow alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        w.windowLevel = UIWindowLevelAlert + 1;
        w.backgroundColor = [UIColor clearColor];

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.frame = w.bounds;
        w.rootViewController = vc;

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(9, 9, 46, 46);
        b.layer.cornerRadius = 23;
        b.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.15 alpha:0.9];
        b.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.25].CGColor;
        b.layer.borderWidth = 1;
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        [b setTitle:@"黄" forState:UIControlStateNormal];
        [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        b.accessibilityLabel = @"复制黄字探针日志";
        [b addTarget:[DYBall class] action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:b];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:[DYBall class] action:@selector(pan:)];
        [b addGestureRecognizer:pan];

        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
        if (scene) w.windowScene = scene;

        CGSize sc = [UIScreen mainScreen].bounds.size;
        w.center = CGPointMake(sc.width - 46, 170);
        w.hidden = NO;

        gWin = w;
        DYLog(@"[ui] 小球已创建");
        DYStage("ui-ok", nil);
    } @catch (NSException *e) {
        DYStage("ui-fail", e.reason);
    }
}



// ---------------------------------------------------------------- 入口

__attribute__((constructor)) static void DYInit(void) {
    gLock = [NSLock new];
    gLines = [NSMutableArray array];
    gSeen = [NSMutableSet set];

    @try {
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!dir) dir = NSTemporaryDirectory();
        gLogPath = [dir stringByAppendingPathComponent:@"dycolor.log"];
        DYStage("ctor-enter", [NSBundle mainBundle].bundleIdentifier);
    } @catch (__unused NSException *e) {}

    @try {
        NSBundle *b = [NSBundle mainBundle];
        DYLog(@"[env] %@ v%@ (%@) iOS %@", b.bundleIdentifier,
              [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [b objectForInfoDictionaryKey:@"CFBundleVersion"],
              [[UIDevice currentDevice] systemVersion]);
    } @catch (__unused NSException *e) {}

    DYStage("hook-tv", nil);
    DYSwizzleInstance(NSClassFromString(@"UITextView"), @selector(setAttributedText:),
                      (IMP)dy_tvAttr, (IMP *)&dy_origTVAttr);

    DYStage("hook-tf", nil);
    DYSwizzleInstance(NSClassFromString(@"UITextField"), @selector(setAttributedText:),
                      (IMP)dy_tfAttr, (IMP *)&dy_origTfAttr);

    DYStage("hook-body", nil);
    DYSwizzleInstance(NSClassFromString(@"NSMutableURLRequest"), @selector(setHTTPBody:),
                      (IMP)dy_setBody, (IMP *)&dy_origBody);

    DYStage("hooks-done", [NSString stringWithFormat:@"tv=%d tf=%d body=%d",
                           dy_origTVAttr != NULL, dy_origTfAttr != NULL, dy_origBody != NULL]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ DYBuildUI(); });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{ DYScanRuntime(); });
}