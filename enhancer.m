// libipaenhancer v15.1 — lz4 解压 + 启动崩溃修复 + 魔数嗅探 + RAR5 volume 标志修补
// v15.1 修正：fixRarVolumeFlag 边界检查（文件可短于 16 字节，读满 15 即够）

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#import "lz4frame.h"

#define BUF_SIZE (1 << 20)

typedef BOOL (*DecoderFn)(NSString *, NSString *, NSError **);

static BOOL decode_lz4(NSString *src, NSString *dst, NSError **errOut) {
    FILE *in = fopen(src.fileSystemRepresentation, "rb");
    if (!in) return NO;
    FILE *out = fopen(dst.fileSystemRepresentation, "wb");
    if (!out) { fclose(in); return NO; }
    LZ4F_errorCode_t r;
    LZ4F_dctx *dctx = NULL;
    r = LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION);
    if (LZ4F_isError(r) || !dctx) { fclose(in); fclose(out); return NO; }
    static uint8_t inbuf[BUF_SIZE], outbuf[BUF_SIZE];
    BOOL ok = YES;
    for (;;) {
        size_t got = fread(inbuf, 1, sizeof(inbuf), in);
        if (got == 0) break;
        size_t pos = 0;
        while (pos < got) {
            size_t consumed = got - pos;
            size_t produced = sizeof(outbuf);
            size_t ret = LZ4F_decompress(dctx, outbuf, &produced, inbuf + pos, &consumed, NULL);
            if (LZ4F_isError(ret)) {
                if (errOut) *errOut = [NSError errorWithDomain:@"ipaenhancer" code:-2
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"lz4: %s", LZ4F_getErrorName(ret)]}];
                ok = NO; goto out;
            }
            if (produced && fwrite(outbuf, 1, produced, out) != produced) { ok = NO; goto out; }
            pos += consumed;
        }
    }
out:
    LZ4F_freeDecompressionContext(dctx);
    fclose(in);
    if (fclose(out) != 0) ok = NO;
    if (!ok) remove(dst.fileSystemRepresentation);
    return ok;
}

static NSString *innerName(NSString *path) {
    NSString *name = path.lastPathComponent;
    NSString *low = name.lowercaseString;
    NSDictionary<NSString *, NSString *> *two = @{
        @".7z.lz4": @".7z", @".zip.lz4": @".zip", @".tar.lz4": @".tar",
    };
    for (NSString *suf in two) {
        if ([low hasSuffix:suf]) {
            NSString *stem = [name substringToIndex:name.length - suf.length];
            return [stem stringByAppendingString:two[suf]];
        }
    }
    if ([low hasSuffix:@".lz4"]) return [name substringToIndex:name.length - 4];
    return nil;
}

// lz4 魔数嗅探：文件后缀被用户改名（去掉 .lz4）但内容仍是 lz4 流
static BOOL hasLz4Magic(NSString *path) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return NO;
    uint8_t m[4];
    size_t n = fread(m, 1, 4, f);
    fclose(f);
    if (n < 4) return NO;
    uint32_t v = (uint32_t)m[0] | ((uint32_t)m[1] << 8) | ((uint32_t)m[2] << 16) | ((uint32_t)m[3] << 24);
    if (v == 0x184D2204) return YES;                 // lz4 frame magic
    if ((v & 0xFFFFFFF0u) == 0x184D2A50) return YES; // legacy/skippable frame
    return NO;
}

static DecoderFn decoderFor(NSString *path, NSString **innerOut) {
    NSString *inner = innerName(path);
    if (inner) { *innerOut = inner; return decode_lz4; }
    NSString *low = path.lastPathComponent.lowercaseString;
    if ([low hasSuffix:@".7z"] || [low hasSuffix:@".zip"] || [low hasSuffix:@".tar"]) {
        if (hasLz4Magic(path)) {
            *innerOut = path.lastPathComponent;
            return decode_lz4;
        }
    }
    *innerOut = nil;
    return NULL;
}

static NSString *uniqueDst(NSString *dir, NSString *name) {
    NSString *dst = [dir stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:dst]) return dst;
    NSString *ext = name.pathExtension;
    NSString *stem = ext.length ? [name stringByDeletingPathExtension] : name;
    for (int i = 2; i < 1000; i++) {
        NSString *cand = [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@(%d).%@", stem, i, ext]];
        if (![NSFileManager.defaultManager fileExistsAtPath:cand]) return cand;
    }
    return nil;
}

static void enh_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void enh_alert(NSString *title, NSString *msg);
static void enh_log(NSString *fmt, ...) {
    static NSString *logPath = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (docs) logPath = [docs stringByAppendingPathComponent:@"ipaenhancer.log"];
    });
    if (!logPath) return;
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *out = [NSString stringWithFormat:@"[%lld] %@\n",
                     (long long)[[NSDate date] timeIntervalSince1970], line];
    NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
    else [d writeToFile:logPath atomically:YES];
}

static void enh_alert(NSString *title, NSString *msg) {
#if TARGET_OS_IPHONE
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            Class alertCls = NSClassFromString(@"UIAlertController");
            Class sceneCls = NSClassFromString(@"UIWindowScene");
            if (!alertCls || !sceneCls) return;
            id alert = [alertCls alertControllerWithTitle:title message:msg
                preferredStyle:UIAlertControllerStyleAlert];
            id app = [[UIApplication class] performSelector:@selector(sharedApplication)];
            id scenes = [app performSelector:@selector(connectedScenes)];
            id active = nil;
            for (id scene in scenes) {
                if ([[scene valueForKey:@"activationState"] intValue] == 2) { active = scene; break; }
            }
            if (!active) return;
            id win = [active valueForKey:@"keyWindow"];
            id vc = [win valueForKey:@"rootViewController"];
            if (!vc) return;
            while ([vc respondsToSelector:@selector(presentedViewController)] &&
                   [vc performSelector:@selector(presentedViewController)]) {
                vc = [vc performSelector:@selector(presentedViewController)];
            }
            void (*presentVC)(id, SEL, id, BOOL, void (^)(void)) =
                (void (*)(id, SEL, id, BOOL, void (^)(void)))objc_msgSend;
            presentVC(vc, @selector(presentViewController:animated:completion:), alert, YES, NULL);
        } @catch (NSException *e) {}
    });
#endif
}

// ---------------- copyItemAtPath 防护（类簇真实类 hook，修 iOS 26/27 启动崩溃） ----------------

static BOOL (*orig_copy4_concrete)(id, SEL, NSString *, NSString *, NSUInteger, NSError **);
static BOOL (*orig_copy3_concrete)(id, SEL, NSString *, NSString *, NSError **);
static BOOL (*orig_copy4_base)(id, SEL, NSString *, NSString *, NSUInteger, NSError **);
static BOOL (*orig_copy3_base)(id, SEL, NSString *, NSString *, NSError **);

static BOOL enh_fallback_copy(NSString *src, NSString *dst) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir] || isDir) return NO;
        NSData *bytes = [NSData dataWithContentsOfFile:src];
        if (!bytes) return NO;
        NSString *parent = [dst stringByDeletingLastPathComponent];
        if (parent.length) [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        return [bytes writeToFile:dst atomically:YES];
    } @catch (NSException *e) { return NO; }
}

static BOOL enh_protected_copy(id self, NSString *src, NSString *dst, NSUInteger options,
                               NSError **error, BOOL hasOptions, const char *kind) {
    static _Thread_local int in_prot = 0;
    if (in_prot) {
        @try {
            if (hasOptions) return orig_copy4_concrete(self, @selector(copyItemAtPath:toPath:options:error:),
                                                       src, dst, options, error);
            return orig_copy3_concrete(self, @selector(copyItemAtPath:toPath:error:), src, dst, error);
        } @catch (NSException *e) { return NO; }
    }
    in_prot = 1;
    BOOL r = NO;
    NSError *le = nil;
    @try {
        if (src && dst && [(NSFileManager *)self fileExistsAtPath:dst]) {
            if (error) *error = nil;
            enh_log(@"copy[%s]: dst exists → YES %@", kind, dst.lastPathComponent);
            in_prot = 0;
            return YES;
        }
    } @catch (NSException *e) {}
    @try {
        if (hasOptions)
            r = orig_copy4_concrete(self, @selector(copyItemAtPath:toPath:options:error:),
                                    src, dst, options, &le);
        else
            r = orig_copy3_concrete(self, @selector(copyItemAtPath:toPath:error:), src, dst, &le);
        enh_log(@"copy[%s]: %@ err=%@ src=%@ dst=%@", kind, r ? @"YES" : @"NO",
                le.localizedDescription ?: @"-", src.lastPathComponent ?: @"-", dst.lastPathComponent ?: @"-");
        if (error && le) *error = le;
    } @catch (NSException *e) {
        enh_log(@"copy[%s]: EXCEPTION %@ (%@)", kind, e.name, e.reason ?: @"-");
        if ([e.name isEqualToString:@"NSFileAlreadyExistsException"]) {
            if (error) *error = nil;
            in_prot = 0;
            return YES;
        }
        le = [NSError errorWithDomain:NSCocoaErrorDomain code:-1
            userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"copy exception"}];
        if (error) *error = le;
        r = NO;
    }
    if (!r) {
        if (enh_fallback_copy(src, dst)) {
            enh_log(@"copy[%s]: FALLBACK 成功 %@", kind, dst.lastPathComponent);
            if (error) *error = nil;
            in_prot = 0;
            return YES;
        }
        enh_log(@"copy[%s]: FALLBACK 也失败", kind);
        enh_alert(@"解压专家·兼容修复",
                  [NSString stringWithFormat:@"文件拷贝失败\n\n来源: %@\n目标: %@\n原因: %@",
                   src.lastPathComponent ?: @"-", dst.lastPathComponent ?: @"-",
                   le.localizedDescription ?: @"-"]);
    }
    in_prot = 0;
    return r;
}

static BOOL new_copy4(id self, SEL _cmd, NSString *src, NSString *dst, NSUInteger options, NSError **error) {
    return enh_protected_copy(self, src, dst, options, error, YES, "4");
}
static BOOL new_copy3(id self, SEL _cmd, NSString *src, NSString *dst, NSError **error) {
    return enh_protected_copy(self, src, dst, 0, error, NO, "3");
}

// ---------------- RAR5 volume 标志修补 ----------------
// 实测：部分发布包把单卷 RAR5 误设 volume 标志（main flags=0x05），
// unrar 找不到下一卷 → 解出文件缺失。解压喵等工具不校验该标志。
// 对策：解出内层 .rar 后，main flags=0x05 → 清 volume 位 + 重算 header CRC32。

static uint32_t enh_crc32(const uint8_t *d, size_t n) {
    static uint32_t table[256];
    static int init = 0;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
        init = 1;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = table[(c ^ d[i]) & 0xff] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void fixRarVolumeFlag(NSString *path) {
    if (![path.lowercaseString hasSuffix:@".rar"]) return;
    FILE *f = fopen(path.fileSystemRepresentation, "rb+");
    if (!f) return;
    uint8_t h[16];
    size_t rn = fread(h, 1, 16, f);
    if (rn < 15) { fclose(f); return; }         // 最短有效结构 15 字节
    if (memcmp(h, "Rar!\x1a\x07\x01\x00", 8) != 0) { fclose(f); return; } // 仅 RAR5
    if (h[13] != 0x01) { fclose(f); return; }   // main archive header
    if (h[14] != 0x05) { fclose(f); return; }   // flags = volume|solid 才修
    uint8_t hsz = h[12];                        // HeaderSize vint（main header 极小，恒 1 字节）
    if (hsz < 2 || hsz > 127) { fclose(f); return; }
    uint8_t *buf = (uint8_t *)malloc(hsz);
    fseek(f, 12, SEEK_SET);
    if (fread(buf, 1, hsz, f) != hsz) { free(buf); fclose(f); return; }
    buf[2] = 0x04;                              // flags: 清 volume 位（保留 solid）
    uint32_t crc = enh_crc32(buf, hsz);
    free(buf);
    fseek(f, 14, SEEK_SET);
    uint8_t nb = 0x04;
    fwrite(&nb, 1, 1, f);
    fseek(f, 8, SEEK_SET);
    fwrite(&crc, 4, 1, f);                      // little-endian
    fflush(f);
    fclose(f);
    enh_log(@"rar: volume 标志误设已清除 %@", path.lastPathComponent);
}

// ---------------- 解压入口 hook（lz4 双层接力） ----------------

static void (*orig_unarchiveFile)(id self, SEL _cmd, NSString *src, NSString *desDir,
                                  id progressBlock, id completeBlock);
static void new_unarchiveFile(id self, SEL _cmd, NSString *src, NSString *desDir,
                              id progressBlock, id completeBlock) {
    @try {
        NSString *inner = nil;
        DecoderFn fn = decoderFor(src, &inner);
        if (fn) {
            NSString *dst = uniqueDst(desDir, inner);
            NSError *err = nil;
            BOOL ok = dst && fn(src, dst, &err);
            enh_log(@"lz4: %@ src=%@", ok ? @"OK" : @"FAIL", src.lastPathComponent);
            if (ok) {
                if ([dst.lowercaseString hasSuffix:@".rar"]) fixRarVolumeFlag(dst);
                new_unarchiveFile(self, _cmd, dst, desDir, progressBlock, completeBlock);
                return;
            }
            new_unarchiveFile(self, _cmd, src, desDir, progressBlock, completeBlock);
            return;
        }
    } @catch (NSException *e) {}
    orig_unarchiveFile(self, _cmd, src, desDir, progressBlock, completeBlock);
}

static void (*orig_handleUnzip)(id self, SEL _cmd, NSString *path);
static void new_handleUnzip(id self, SEL _cmd, NSString *path) {
    @try {
        NSString *inner = nil;
        DecoderFn fn = decoderFor(path, &inner);
        if (fn) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *dir = [path stringByDeletingLastPathComponent];
                NSString *dst = uniqueDst(dir, inner);
                NSError *err = nil;
                if (dst && fn(path, dst, &err)) {
                    if ([dst.lowercaseString hasSuffix:@".rar"]) fixRarVolumeFlag(dst);
                    dispatch_async(dispatch_get_main_queue(), ^{ orig_handleUnzip(self, _cmd, dst); });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{ orig_handleUnzip(self, _cmd, path); });
                }
            });
            return;
        }
    } @catch (NSException *e) {}
    orig_handleUnzip(self, _cmd, path);
}

static void swizzle(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
    enh_log(@"swizzle %s +%s OK", class_getName(cls), sel_getName(sel));
}

__attribute__((constructor))
static void enhancer_init(void) {
    @autoreleasepool {
        Class wrapper = NSClassFromString(@"ZMUnzipZipWrapper");
        Class vc = NSClassFromString(@"ZMFileMainViewController");
        swizzle(wrapper, @selector(unarchiveFile:desDir:progressBlock:compeleteBlock:),
                (IMP)new_unarchiveFile, (IMP *)&orig_unarchiveFile);
        swizzle(vc, @selector(handleUnzip:),
                (IMP)new_handleUnzip, (IMP *)&orig_handleUnzip);
        Class concrete = object_getClass([NSFileManager defaultManager]);
        swizzle(concrete, @selector(copyItemAtPath:toPath:options:error:),
                (IMP)new_copy4, (IMP *)&orig_copy4_concrete);
        swizzle(concrete, @selector(copyItemAtPath:toPath:error:),
                (IMP)new_copy3, (IMP *)&orig_copy3_concrete);
        swizzle([NSFileManager class], @selector(copyItemAtPath:toPath:options:error:),
                (IMP)new_copy4, (IMP *)&orig_copy4_base);
        swizzle([NSFileManager class], @selector(copyItemAtPath:toPath:error:),
                (IMP)new_copy3, (IMP *)&orig_copy3_base);
        enh_log(@"enhancer v15.1 loaded (lz4 + magic sniff + copy protection + rar5 volume fix)");
    }
}
