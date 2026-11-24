// DYColorComment —— 抖音评论「黄字」探针版（TrollFools 注入，不依赖 CydiaSubstrate）
// 目标：摸清 iOS 抖音评论提交时 (a) 走哪条网络路径 (b) text_extra 长什么样 (c) 输入框 @ 的富文本属性 key
// 用法：注入抖音后正常发一条含标记的评论，点屏幕上的小圆点 → 日志复制到剪贴板

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DYMAXLINES 900
#define DYMAXLEN 6000

static NSMutableArray<NSString *> *gLines = nil;
static NSMutableSet<NSString *> *gSeen = nil;
static NSLock *gLock = nil;
static NSString *gLogPath = nil;
static NSMutableString *gMethodMap = nil;

static void DYFlush(void) {
    if (!gLogPath || !gLines) return;
    NSMutableString *all = [NSMutableString stringWithCapacity:64 * 1024];
    [all appendString:@"=== DYColorComment probe log ===\n"];
    if (gMethodMap.length) { [all appendString:gMethodMap]; [all appendString:@"\n"]; }
    for (NSString *s in gLines) { [all appendString:s]; [all appendString:@"\n"]; }
    [all writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
}

static void DYLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!s) return;
    [gLock lock];
    if (gLines.count < DYMAXLINES) {
        [gLines addObject:s];
        DYFlush();
    }
    [gLock unlock];
}

// 同类 payload 只记一次，避免刷爆
static BOOL DYWorthLogging(NSString *key) {
    if (!key) return YES;
    NSString *h = [NSString stringWithFormat:@"%lu", (unsigned long)[key hash]];
    [gLock lock];
    BOOL seen = [gSeen containsObject:h];
    if (!seen && gSeen.count < 400) [gSeen addObject:h];
    [gLock unlock];
    return !seen;
}

static NSString *DYTrunc(NSString *s, NSUInteger n) {
    if (!s) return @"(nil)";
    if (s.length <= n) return s;
    return [[s substringToIndex:n] stringByAppendingString:@"…(截断)"];
}

static NSString *DYHexDump(NSData *d, NSUInteger max) {
    if (!d) return @"(nil)";
    NSUInteger n = MIN(d.length, max);
    const uint8_t *b = d.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:n * 4];
    for (NSUInteger i = 0; i < n; i++) {
        [out appendFormat:@"%02x", b[i]];
        if ((i & 15) == 15) [out appendString:@"\n"];
        else [out appendString:@" "];
    }
    if (d.length > max) [out appendFormat:@"\n…共 %lu 字节", (unsigned long)d.length];
    return out;
}

static BOOL DYLooksInteresting(NSString *s) {
    if (s.length < 4) return NO;
    if ([s containsString:@"text_extra"]) return YES;
    if ([s containsString:@"comment"] && ([s containsString:@"aweme_id"] || [s containsString:@"reply_id"])) return YES;
    if ([s containsString:@"comment/publish"] || [s containsString:@"/comment/"]) return YES;
    return NO;
}

static void DYCheckString(NSString *s, NSString *src, id ctx) {
    if (![s isKindOfClass:[NSString class]] || s.length < 4) return;
    if (!DYLooksInteresting(s)) return;
    if (!DYWorthLogging(s)) return;
    DYLog(@"[%@] ctx=%@\n---\n%@\n---", src, DYTrunc([ctx description], 200), DYTrunc(s, DYMAXLEN));
}

static void DYCheckData(NSData *d, NSString *src, id ctx) {
    if (![d isKindOfClass:[NSData class]] || d.length < 8) return;
    NSString *asString = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (asString && DYLooksInteresting(asString)) {
        if (DYWorthLogging(asString)) {
            DYLog(@"[%@] ctx=%@ len=%lu\n--- utf8 ---\n%@\n--- hex(256) ---\n%@",
                  src, DYTrunc([ctx description], 200), (unsigned long)d.length,
                  DYTrunc(asString, DYMAXLEN), DYHexDump(d, 256));
        }
    }
}

// ---------------------------------------------------------------- hooks

// 1) JSON 序列化边界（params 走 JSON 时必经）
static id (*dy_orig_json)(id, SEL, id, NSJSONWritingOptions, NSError **);
static id dy_json(id self, SEL _cmd, id obj, NSJSONWritingOptions opt, NSError **err) {
    @try {
        NSString *s = nil;
        if ([NSJSONSerialization isValidJSONObject:obj]) {
            s = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL]
                                       encoding:NSUTF8StringEncoding];
        }
        if (s) DYCheckString(s, @"NSJSONSerialization", obj);
    } @catch (NSException *e) {}
    return dy_orig_json(self, _cmd, obj, opt, err);
}

// 2) HTTP body 设置（form-urlencoded / pb 都会经过这里）
static void (*dy_orig_setBody)(id, SEL, NSData *);
static void dy_setBody(id self, SEL _cmd, NSData *body) {
    @try {
        DYCheckData(body, @"setHTTPBody", [self valueForKey:@"URL"]);
    } @catch (NSException *e) {}
    dy_orig_setBody(self, _cmd, body);
}

static void (*dy_orig_setBodyStream)(id, SEL, id);
static void dy_setBodyStream(id self, SEL _cmd, id stream) {
    @try { DYLog(@"[setHTTPBodyStream] %@ -> %@", [self class], [stream class]); } @catch (NSException *e) {}
    dy_orig_setBodyStream(self, _cmd, stream);
}

// 3) 输入框富文本（看 @ 的 mention 属性 key）
static void (*dy_orig_setAttr)(id, SEL, NSAttributedString *);
static void dy_setAttr(id self, SEL _cmd, NSAttributedString *s) {
    @try {
        if (s.length && s.length < 6000) {
            __block NSUInteger dumped = 0;
            NSMutableString *buf = [NSMutableString string];
            [s enumerateAttributesInRange:NSMakeRange(0, s.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey,id> *attrs, NSRange r, BOOL *stop) {
                if (dumped++ > 6) { *stop = YES; return; }
                [buf appendFormat:@"range=%lu,%lu text=%@\n  attrs=%@\n",
                                  (unsigned long)r.location, (unsigned long)r.length,
                                  DYTrunc([s.string substringWithRange:r], 40), attrs];
            }];
            if (buf.length && DYWorthLogging(buf)) {
                DYLog(@"[TextView setAttributedText] cls=%@ len=%lu\n%@", [self class], (unsigned long)s.length, buf);
            }
        }
    } @catch (NSException *e) {}
    dy_orig_setAttr(self, _cmd, s);
}

static void (*dy_orig_setAttrTF)(id, SEL, NSAttributedString *);
static void dy_setAttrTF(id self, SEL _cmd, NSAttributedString *s) {
    @try {
        NSMutableString *buf = [NSMutableString string];
        [s enumerateAttributesInRange:NSMakeRange(0, s.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey,id> *attrs, NSRange r, BOOL *stop) {
            [buf appendFormat:@"range=%lu,%lu text=%@ attrs=%@\n",
                              (unsigned long)r.location, (unsigned long)r.length,
                              DYTrunc([s.string substringWithRange:r], 40), attrs];
            if (r.location > 200) *stop = YES;
        }];
        if (buf.length && DYWorthLogging(buf)) {
            DYLog(@"[TextField setAttributedText] cls=%@ len=%lu\n%@", [self class], (unsigned long)s.length, buf);
        }
    } @catch (NSException *e) {}
    dy_orig_setAttrTF(self, _cmd, s);
}

static void DYSwizzleInstance(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

static void DYSwizzleClass(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls || !sel) return;
    Class meta = object_getClass(cls);
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    (void)meta;
}

// ---------------------------------------------------------------- 类名/方法名扫描

static BOOL DYNameInteresting(NSString *n) {
    NSString *lower = [n lowercaseString];
    if ([lower containsString:@"comment"]) return YES;
    if ([lower containsString:@"textinput"] || [lower containsString:@"textedit"]) return YES;
    if ([lower containsString:@"mention"]) return YES;
    return NO;
}

static NSMutableSet<NSString *> *gScannedClasses = nil;

static void DYScanRuntime(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    NSInteger hits = 0;
    for (int i = 0; i < count; i++) {
        @autoreleasepool {
            Class c = classes[i];
            const char *nm = class_getName(c);
            if (!nm) continue;
            NSString *name = [NSString stringWithUTF8String:nm];
            if (!DYNameInteresting(name)) continue;
            if ([gScannedClasses containsObject:name]) continue;
            if (hits++ > 80) { continue; }
            [gScannedClasses addObject:name];
            NSMutableString *line = [NSMutableString stringWithFormat:@"CLASS %@ : %@\n", name, class_getSuperclass(c) ? [NSString stringWithUTF8String:class_getName(class_getSuperclass(c))] : @"-"];
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            NSInteger shown = 0;
            for (unsigned int j = 0; j < mc && shown < 40; j++) {
                NSString *s = NSStringFromSelector(method_getName(ms[j]));
                NSString *ls = [s lowercaseString];
                if ([ls containsString:@"send"] || [ls containsString:@"publish"] || [ls containsString:@"post"] ||
                    [ls containsString:@"reply"] || [ls containsString:@"submit"] || [ls containsString:@"input"] ||
                    [ls containsString:@"insert"] || [ls containsString:@"mention"]) {
                    [line appendFormat:@"   -%@  %s\n", s, method_getTypeEncoding(ms[j])];
                    shown++;
                }
            }
            if (shown == 0 && mc > 0) {
                // 没命中关键词就只记类名和前 6 个方法名，避免日志过大
                [line appendString:@"   (方法名无关键词) 前6个:"];
                for (unsigned int j = 0; j < mc && j < 6; j++) {
                    [line appendFormat:@" %@", NSStringFromSelector(method_getName(ms[j]))];
                }
                [line appendString:@"\n"];
            }
            if (ms) free(ms);
            if (gMethodMap.length < 120 * 1024) [gMethodMap appendString:line];
        }
    }
    free(classes);
    DYLog(@"[scan] 命中相关类 %ld 个", (long)hits);
}

// ---------------------------------------------------------------- 悬浮按钮

static UIWindow *gWin = nil;
static UIButton *gBtn = nil;

static void DYCopyLog(void) {
    NSMutableString *all = [NSMutableString string];
    if (gMethodMap.length) [all appendString:gMethodMap];
    for (NSString *s in gLines) { [all appendString:s]; [all appendString:@"\n"]; }
    if (!all.length) all = [NSMutableString stringWithString:@"(日志为空)"];
    [UIPasteboard generalPasteboard].string = all;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已复制日志"
                                                               message:[NSString stringWithFormat:@"%lu 字符，粘贴发出去即可", (unsigned long)all.length]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = gWin.rootViewController;
    [root presentViewController:ac animated:YES completion:nil];
    DYLog(@"[ui] 日志已复制 %lu 字符, 文件 %@", (unsigned long)all.length, gLogPath);
}

// 用 target-action 自管手势，避免 block 循环引用问题
@interface DYBall : NSObject
+ (instancetype)shared;
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)tap:(UIButton *)b;
@end

@implementation DYBall
+ (instancetype)shared {
    static DYBall *o; static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [DYBall new]; }); return o;
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; if (!v) return;
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateEnded) {
        CGPoint t = [g translationInView:v.superview];
        v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
        [g setTranslation:CGPointZero inView:v.superview];
    }
}
- (void)tap:(UIButton *)b { (void)b; DYCopyLog(); }
@end

static void DYBuildUI(void) {
    if (gWin) return;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = vc;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 46, 46);
    b.layer.cornerRadius = 23;
    b.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.15 alpha:0.88];
    [b setTitle:@"黄" forState:UIControlStateNormal];
    [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [b addTarget:[DYBall shared] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[DYBall shared] action:@selector(pan:)];
    [b addGestureRecognizer:pan];

    [vc.view addSubview:b];
    b.center = CGPointMake(UIScreen.mainScreen.bounds.size.width - 40, 160);

    gWin = w; gBtn = b;
    w.hidden = NO;
    DYLog(@"[ui] 悬浮球已创建");
}

// ---------------------------------------------------------------- 入口

__attribute__((constructor)) static void DYInit(void) {
    @autoreleasepool {
        gLines = [NSMutableArray array];
        gSeen = [NSMutableSet set];
        gLock = [NSLock new];
        gMethodMap = [NSMutableString string];
        gScannedClasses = [NSMutableSet set];

        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!dir) dir = NSTemporaryDirectory();
        gLogPath = [dir stringByAppendingPathComponent:@"dycolor.log"];
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSBundle *b = [NSBundle mainBundle];
        DYLog(@"[env] %@ v%@ (%@) iOS %@", b.bundleIdentifier, [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [b objectForInfoDictionaryKey:@"CFBundleVersion"], [[UIDevice currentDevice] systemVersion]);

        DYScanRuntime();

        Class nsjs = NSClassFromString(@"NSJSONSerialization");
        if (nsjs) {
            DYSwizzleClass(nsjs, @selector(dataWithJSONObject:options:error:), (IMP)dy_json, (IMP *)&dy_orig_json);
        }
        DYSwizzleInstance(NSClassFromString(@"NSMutableURLRequest"), @selector(setHTTPBody:), (IMP)dy_setBody, (IMP *)&dy_orig_setBody);
        DYSwizzleInstance(NSClassFromString(@"NSMutableURLRequest"), @selector(setHTTPBodyStream:), (IMP)dy_setBodyStream, (IMP *)&dy_orig_setBodyStream);
        Class tv = NSClassFromString(@"UITextView");
        if (tv) DYSwizzleInstance(tv, @selector(setAttributedText:), (IMP)dy_setAttr, (IMP *)&dy_orig_setAttr);
        Class tf = NSClassFromString(@"UITextField");
        if (tf) DYSwizzleInstance(tf, @selector(setAttributedText:), (IMP)dy_setAttrTF, (IMP *)&dy_orig_setAttrTF);

        DYLog(@"[init] hooks 安装完成");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DYBuildUI();
            DYScanRuntime();
        });
    }
}