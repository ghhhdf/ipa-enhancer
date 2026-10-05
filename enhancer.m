// libipaenhancer v11 — 极简版：只加 lz4 解压（应要求移除 gz/bz2/br/弹窗/额外 hook）
// 功能：解压入口识别 .lz4 / .7z.lz4 / .zip.lz4 / .tar.lz4 → liblz4 解码 → 内层包自动接力
// 其余格式全部放行 App 原逻辑；任何异常回退原实现，不闪退

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "lz4frame.h"

#define BUF_SIZE (1 << 20) // 1MB

// ---------------- lz4 frame 解码 ----------------

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

// ---------------- 后缀路由（仅 lz4 家族） ----------------

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
    if ([low hasSuffix:@".lz4"]) {
        return [name substringToIndex:name.length - 4];
    }
    return nil; // 非 lz4 → 放行
}

static DecoderFn decoderFor(NSString *path, NSString **innerOut) {
    *innerOut = innerName(path);
    return *innerOut ? decode_lz4 : NULL;
}

// 生成不冲突的输出路径
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

// ---------------- 日志（写入 Documents/ipaenhancer.log） ----------------

static void enh_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
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
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } else {
        [d writeToFile:logPath atomically:YES];
    }
}

// ---------------- 解压入口 hook（与安卓版同构的双层接力） ----------------

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
                // 接力：内层包再走一遍本入口（.7z.lz4 → .7z 由 App 原生引擎接手）
                new_unarchiveFile(self, _cmd, dst, desDir, progressBlock, completeBlock);
                return;
            }
            new_unarchiveFile(self, _cmd, src, desDir, progressBlock, completeBlock);
            return;
        }
    } @catch (NSException *e) {
        // 吞掉并回退
    }
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
                    dispatch_async(dispatch_get_main_queue(), ^{
                        orig_handleUnzip(self, _cmd, dst);
                    });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        orig_handleUnzip(self, _cmd, path);
                    });
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
}

__attribute__((constructor))
static void enhancer_init(void) {
    @autoreleasepool {
        // 只做 2 个 swizzle，其他什么都不碰
        Class wrapper = NSClassFromString(@"ZMUnzipZipWrapper");
        Class vc = NSClassFromString(@"ZMFileMainViewController");
        swizzle(wrapper, @selector(unarchiveFile:desDir:progressBlock:compeleteBlock:),
                (IMP)new_unarchiveFile, (IMP *)&orig_unarchiveFile);
        swizzle(vc, @selector(handleUnzip:),
                (IMP)new_handleUnzip, (IMP *)&orig_handleUnzip);
        enh_log(@"enhancer v11 loaded (lz4 only, 2 swizzles)");
    }
}
