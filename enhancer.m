// libipaenhancer — 解压专家 iOS 格式增强 dylib
// 思路与安卓增强版完全同构：swizzle 解压总入口 → 识别扩展后缀 →
// 先用内置解码器解开压缩层 → 解出的内层包回调原入口接力解压。
// 任何异常都回退原实现，保证不闪退。
//
// hook 点（静态侦察确认）：
//   ZMUnzipZipWrapper - unarchiveFile:desDir:progressBlock:compeleteBlock:  (总入口)
//   ZMFileMainViewController - handleUnzip:  (UI 层入口，兜底)
//
// 新增格式：
//   .lz4 (LZ4 frame, liblz4)     .br (brotli)          .7z.lz4 / .zip.lz4 等双层
//   .gz (zlib)  .tar.gz .tgz     .bz2 (libbz2) .tar.bz2 .tbz2
//   .xz / .tar.xz 放行 App 原逻辑（其 libarchive 内置 xz filter，实测后再定）

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#import "lz4frame.h"
#import "lz4.h"
#import "brotli/decode.h"
#import "zlib.h"
#import "bzlib.h"

#define BUF_SIZE (1 << 20) // 1MB，与安卓版缓冲一致

// ---------------- LZ4 frame ----------------

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
        const uint8_t *pin = inbuf;
        size_t left = got;
        for (;;) {
            uint8_t *pout = outbuf;
            size_t cap = sizeof(outbuf);
            size_t ret = LZ4F_decompress(dctx, pout, &cap, pin, &left, NULL);
            if (LZ4F_isError(ret)) {
                if (errOut) *errOut = [NSError errorWithDomain:@"ipaenhancer" code:-2
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"lz4: %s", LZ4F_getErrorName(ret)]}];
                ok = NO; break;
            }
            if (cap && fwrite(outbuf, 1, cap, out) != cap) { ok = NO; break; }
            if (left == 0) break;
            pin = inbuf + (got - left);
        }
        if (!ok) break;
        if (feof(in)) break;
    }
    LZ4F_freeDecompressionContext(dctx);
    fclose(in);
    if (fclose(out) != 0) ok = NO;
    if (!ok) remove(dst.fileSystemRepresentation);
    return ok;
}

// ---------------- brotli ----------------

static BOOL decode_brotli(NSString *src, NSString *dst, NSError **errOut) {
    FILE *in = fopen(src.fileSystemRepresentation, "rb");
    if (!in) return NO;
    FILE *out = fopen(dst.fileSystemRepresentation, "wb");
    if (!out) { fclose(in); return NO; }

    static uint8_t inbuf[BUF_SIZE], outbuf[BUF_SIZE];
    BrotliDecoderState *s = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    BOOL ok = YES, eof = NO;
    size_t avail_in = 0;
    const uint8_t *next_in = inbuf;
    for (;;) {
        if (avail_in == 0 && !eof) {
            avail_in = fread(inbuf, 1, sizeof(inbuf), in);
            if (avail_in == 0) eof = YES;
            next_in = inbuf;
        }
        uint8_t *pout = outbuf;
        size_t cap = sizeof(outbuf);
        BrotliDecoderResult r = BrotliDecoderDecompressStream(
            s, &avail_in, &next_in, &cap, &pout, NULL);
        if (cap && fwrite(outbuf, 1, cap, out) != cap) { ok = NO; break; }
        if (r == BROTLI_DECODER_RESULT_SUCCESS) break;
        if (r == BROTLI_DECODER_RESULT_ERROR) {
            if (errOut) *errOut = [NSError errorWithDomain:@"ipaenhancer" code:-3
                userInfo:@{NSLocalizedDescriptionKey:@"brotli: 解码错误"}];
            ok = NO; break;
        }
        if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT && eof) {
            if (errOut) *errOut = [NSError errorWithDomain:@"ipaenhancer" code:-4
                userInfo:@{NSLocalizedDescriptionKey:@"brotli: 输入不完整"}];
            ok = NO; break;
        }
    }
    BrotliDecoderDestroyInstance(s);
    fclose(in);
    if (fclose(out) != 0) ok = NO;
    if (!ok) remove(dst.fileSystemRepresentation);
    return ok;
}

// ---------------- gzip（系统 zlib） ----------------

static BOOL decode_gzip(NSString *src, NSString *dst, NSError **errOut) {
    gzFile g = gzopen(src.fileSystemRepresentation, "rb");
    if (!g) return NO;
    FILE *out = fopen(dst.fileSystemRepresentation, "wb");
    if (!out) { gzclose(g); return NO; }
    static uint8_t buf[BUF_SIZE];
    BOOL ok = YES;
    for (;;) {
        int n = gzread(g, buf, BUF_SIZE);
        if (n < 0) {
            if (errOut) *errOut = [NSError errorWithDomain:@"ipaenhancer" code:-5
                userInfo:@{NSLocalizedDescriptionKey:@"gzip: 解码错误"}];
            ok = NO; break;
        }
        if (n == 0) break;
        if (fwrite(buf, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
    }
    gzclose(g);
    if (fclose(out) != 0) ok = NO;
    if (!ok) remove(dst.fileSystemRepresentation);
    return ok;
}

// ---------------- bzip2（系统 libbz2） ----------------

static BOOL decode_bzip2(NSString *src, NSString *dst, NSError **errOut) {
    FILE *in = fopen(src.fileSystemRepresentation, "rb");
    if (!in) return NO;
    int bzErr = BZ_OK;
    BZFILE *b = BZ2_bzReadOpen(&bzErr, in, 0, 0, NULL, 0);
    if (!b || bzErr != BZ_OK) { fclose(in); return NO; }
    FILE *out = fopen(dst.fileSystemRepresentation, "wb");
    if (!out) { BZ2_bzReadClose(&bzErr, b); fclose(in); return NO; }

    static uint8_t buf[BUF_SIZE];
    BOOL ok = YES;
    for (;;) {
        int n = 0;
        bzErr = BZ_OK;
        n = BZ2_bzRead(&bzErr, b, buf, BUF_SIZE);
        if (bzErr == BZ_STREAM_END) {
            if (n > 0 && fwrite(buf, 1, (size_t)n, out) != (size_t)n) ok = NO;
            break;
        }
        if (bzErr != BZ_OK || n < 0) {
            if (errOut) *errOut = [NSError errorWithDomain:@"ipaenhancer" code:-6
                userInfo:@{NSLocalizedDescriptionKey:@"bzip2: 解码错误"}];
            ok = NO; break;
        }
        if (n > 0 && fwrite(buf, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
    }
    BZ2_bzReadClose(&bzErr, b);
    fclose(in);
    if (fclose(out) != 0) ok = NO;
    if (!ok) remove(dst.fileSystemRepresentation);
    return ok;
}

// ---------------- 后缀路由 ----------------

typedef BOOL (*DecoderFn)(NSString *, NSString *, NSError **);

static NSString *innerName(NSString *path) {
    NSString *name = path.lastPathComponent;
    NSString *low = name.lowercaseString;
    // 双层优先：.7z.lz4 / .zip.lz4 / .tar.gz ...
    NSDictionary<NSString *, NSString *> *two = @{
        @".7z.lz4": @"7z", @".zip.lz4": @"zip", @".tar.lz4": @"tar",
        @".tar.gz": @"tar", @".tar.bz2": @"tar", @".tar.xz": @"tar", @".tar.br": @"tar",
    };
    for (NSString *suf in two) {
        if ([low hasSuffix:suf]) {
            return [name substringToIndex:name.length - suf.length];
        }
    }
    NSDictionary<NSString *, NSString *> *one = @{
        @".lz4": @"", @".br": @"", @".gz": @"", @".bz2": @"",
        @".xz": @"", @".tgz": @".tar", @".tbz2": @".tar", @".txz": @".tar",
    };
    for (NSString *suf in one) {
        if ([low hasSuffix:suf]) {
            NSString *stem = [name substringToIndex:name.length - suf.length];
            return [stem stringByAppendingString:one[suf]];
        }
    }
    return nil;
}

static DecoderFn decoderFor(NSString *path, NSString **innerOut) {
    NSString *name = path.lastPathComponent;
    NSString *low = name.lowercaseString;
    // 返回同时负责给内层命名
    *innerOut = innerName(path);
    if (!*innerOut) return NULL;
    if ([low hasSuffix:@".lz4"] || [low hasSuffix:@".tar.lz4"]) return decode_lz4;
    if ([low hasSuffix:@".br"] || [low hasSuffix:@".tar.br"])  return decode_brotli;
    if ([low hasSuffix:@".gz"] || [low hasSuffix:@".tar.gz"] ||
        [low hasSuffix:@".tgz"])                               return decode_gzip;
    if ([low hasSuffix:@".bz2"] || [low hasSuffix:@".tar.bz2"] ||
        [low hasSuffix:@".tbz2"])                              return decode_bzip2;
    return NULL; // .xz/.txz 放行原逻辑
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

// ---------------- swizzle 实现 ----------------

// 原 unarchiveFile:desDir:progressBlock:compeleteBlock: 实现
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
            if (ok) {
                // 接力：内层包再走一遍本入口（若内层仍是扩展格式会再次命中，天然支持多层）
                new_unarchiveFile(self, _cmd, dst, desDir, progressBlock, completeBlock);
                return;
            }
            // 解码失败 → 落回原实现（App 自行报错，不会闪退）
            new_unarchiveFile(self, _cmd, src, desDir, progressBlock, completeBlock);
            return;
        }
    } @catch (NSException *e) {
        // 吞掉并回退
    }
    orig_unarchiveFile(self, _cmd, src, desDir, progressBlock, completeBlock);
}

// 原 handleUnzip:（UI 层，兜底 hook）
static void (*orig_handleUnzip)(id self, SEL _cmd, NSString *path);
static void new_handleUnzip(id self, SEL _cmd, NSString *path) {
    @try {
        NSString *inner = nil;
        DecoderFn fn = decoderFor(path, &inner);
        if (fn) {
            // 在文件同目录解出内层，再走原 UI 流程（后台解码防止卡 UI）
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
        // constructor 时 dyld 已完成主二进制 ObjC 类注册
        Class wrapper = NSClassFromString(@"ZMUnzipZipWrapper");
        Class vc = NSClassFromString(@"ZMFileMainViewController");
        swizzle(wrapper, @selector(unarchiveFile:desDir:progressBlock:compeleteBlock:),
                (IMP)new_unarchiveFile, (IMP *)&orig_unarchiveFile);
        swizzle(vc, @selector(handleUnzip:),
                (IMP)new_handleUnzip, (IMP *)&orig_handleUnzip);
    }
}
