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
#import <objc/message.h>
#import <dlfcn.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#import "lz4frame.h"
#import "lz4.h"
#import "brotli/decode.h"
#import "zlib.h"
#import "bzlib.h"

// ---------------- 通用流式解码骨架 ----------------

#define BUF_SIZE (1 << 20) // 1MB，与安卓版缓冲一致

static BOOL copy_stream(FILE *in, FILE *out, NSError **errOut, NSString *label) {
    static uint8_t buf[BUF_SIZE];
    size_t n;
    while ((n = fread(buf, 1, BUF_SIZE, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            if (errOut) *errOut = [NSError errorWithDomain:@"ipaenhancer" code:-1
                userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@: 写出失败", label]}];
            return NO;
        }
    }
    return YES;
}

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
        // 注意：cap 返回的是"剩余可用容量"，实际写入 = 容量 - 剩余
        size_t produced = sizeof(outbuf) - cap;
#ifdef ENH_DEBUG
        fprintf(stderr, "BR: r=%d produced=%zu avail_in=%zu eof=%d\n", (int)r, produced, avail_in, (int)eof);
#endif
        if (produced && fwrite(outbuf, 1, produced, out) != produced) { ok = NO; break; }
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
    // 双层优先：.7z.lz4 / .zip.lz4 / .tar.gz ...（value 带点，与 stem 直接拼接）
    NSDictionary<NSString *, NSString *> *two = @{
        @".7z.lz4": @".7z", @".zip.lz4": @".zip", @".tar.lz4": @".tar",
        @".tar.gz": @".tar", @".tar.bz2": @".tar", @".tar.xz": @".tar", @".tar.br": @".tar",
    };
    for (NSString *suf in two) {
        if ([low hasSuffix:suf]) {
            NSString *stem = [name substringToIndex:name.length - suf.length];
            return [stem stringByAppendingString:two[suf]];
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

// 原 unarchiveFile:desDir:progressBlock:compeleteBlock: 实现（交换后名叫 new_unarchiveFile:）
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

// ---------------- iOS 26 兼容性防护：NSFileManager.copyItemAtPath ----------------
// 实测（原版对照同现）：App 6.3.7 在 iOS 26.5 上启动资源拷贝抛异常致闪退、导入文件静默失败。
// 对策：①目标已存在 → 幂等返回 YES（App 语义是"确保文件就位"）
//      ②源文件自动取得安全作用域权限（iOS 文件选择器选中的文件需 startAccessing 才可读）
//      ③异常一律捕获转普通失败返回，绝不让异常逃逸
//      ④关键调用写诊断日志到 Documents/ipaenhancer.log（可通过文件共享导出）
static BOOL (*orig_copyItemAtPath)(id self, SEL _cmd, NSString *src, NSString *dst, NSUInteger options, NSError **error);

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
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } else {
        [d writeToFile:logPath atomically:YES];
    }
}

static BOOL new_copyItemAtPath(id self, SEL _cmd, NSString *src, NSString *dst, NSUInteger options, NSError **error) {
    BOOL startedScope = NO;
    NSURL *srcURL = nil;
    @try {
        if (src) {
            srcURL = [NSURL fileURLWithPath:src];
            if ([srcURL respondsToSelector:@selector(startAccessingSecurityScopedResource)]) {
                startedScope = [srcURL startAccessingSecurityScopedResource];
            }
        }
    } @catch (NSException *e) { startedScope = NO; }

    BOOL result = NO;
    NSError *localErr = nil;
    NSString *failMsg = nil;
    @try {
        if (src && dst) {
            if ([(NSFileManager *)self fileExistsAtPath:dst]) {
                if (error) *error = nil;
                enh_log(@"copy: dst exists, idempotent YES  src=%@ dst=%@", src.lastPathComponent, dst.lastPathComponent);
                result = YES;
                goto done;
            }
        }
        result = orig_copyItemAtPath(self, _cmd, src, dst, options, &localErr);
        enh_log(@"copy: orig=%@ err=%@ src=%@ dst=%@ scope=%d",
                result ? @"YES" : @"NO",
                localErr.localizedDescription ?: @"-", src, dst, startedScope);
        if (!result && error && localErr) *error = localErr;
        if (!result) failMsg = localErr.localizedDescription ?: @"系统拷贝返回失败";
    } @catch (NSException *e) {
        enh_log(@"copy: EXCEPTION %@ (%@) src=%@ dst=%@ scope=%d", e.name, e.reason ?: @"-", src, dst, startedScope);
        if ([e.name isEqualToString:@"NSFileAlreadyExistsException"]) {
            if (error) *error = nil;
            result = YES;
            goto done;
        }
        failMsg = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"-"];
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:-1
            userInfo:@{NSLocalizedDescriptionKey: failMsg}];
        result = NO;
    }

    // ---- 备用写入：绕过系统拷贝限制（NSData 读源 → 直接写目标，仅普通文件）----
    if (!result) {
        @try {
            NSFileManager *fm = (NSFileManager *)self;
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:src isDirectory:&isDir] && !isDir) {
                NSData *bytes = [NSData dataWithContentsOfFile:src];
                if (bytes) {
                    // 确保父目录存在
                    NSString *parent = [dst stringByDeletingLastPathComponent];
                    if (parent.length) [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
                    if ([bytes writeToFile:dst atomically:YES]) {
                        enh_log(@"copy: FALLBACK NSData 写入成功 src=%@ dst=%@", src.lastPathComponent, dst.lastPathComponent);
                        if (error) *error = nil;
                        result = YES;
                        goto done;
                    } else {
                        enh_log(@"copy: FALLBACK 写入失败 dst=%@", dst);
                        failMsg = @"备用写入也失败（目标目录不可写？）";
                    }
                } else {
                    enh_log(@"copy: FALLBACK 读源失败 src=%@", src);
                    failMsg = @"备用方式读取源文件失败";
                }
            }
        } @catch (NSException *e) {
            enh_log(@"copy: FALLBACK EXCEPTION %@", e.reason ?: e.name);
        }
    }

done:
    if (startedScope) {
        @try { [srcURL stopAccessingSecurityScopedResource]; } @catch (NSException *e) {}
    }
    if (!result && failMsg) {
        enh_alert(@"解压专家·导入诊断", [NSString stringWithFormat:@"文件拷贝失败\n\n来源: %@\n目标: %@\n原因: %@",
                  src.lastPathComponent ?: @"-", dst.lastPathComponent ?: @"-", failMsg]);
    }
    return result;
}

// 诊断弹窗：拷贝失败时在 App 内直接显示原因（无需数据线即可反馈）
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
                if ([[scene valueForKey:@"activationState"] intValue] == 0) continue; // unattached
                if ([[scene valueForKey:@"activationState"] intValue] == 2) { active = scene; break; } // foregroundActive
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

// ---------------- 导入链路诊断：hook 更多文件操作 + document picker 回调 ----------------

static BOOL (*orig_moveItemAtPath)(id self, SEL _cmd, NSString *src, NSString *dst, NSError **error);
static BOOL new_moveItemAtPath(id self, SEL _cmd, NSString *src, NSString *dst, NSError **error) {
    BOOL r = orig_moveItemAtPath(self, _cmd, src, dst, error);
    enh_log(@"move: %@ src=%@ dst=%@", r ? @"YES" : @"NO", src, dst);
    return r;
}

static BOOL (*orig_createFileAtPath)(id self, SEL _cmd, NSString *path, NSData *data, NSDictionary *attr);
static BOOL new_createFileAtPath(id self, SEL _cmd, NSString *path, NSData *data, NSDictionary *attr) {
    BOOL r = orig_createFileAtPath(self, _cmd, path, data, attr);
    enh_log(@"createFile: %@ path=%@ size=%lu", r ? @"YES" : @"NO", path, (unsigned long)(data ? data.length : 0));
    return r;
}

static NSArray *(*orig_contentsOfDirectory)(id self, SEL _cmd, NSString *path, NSError **error);
static NSArray *new_contentsOfDirectory(id self, SEL _cmd, NSString *path, NSError **error) {
    NSArray *r = orig_contentsOfDirectory(self, _cmd, path, error);
    static int logged = 0;
    if (logged < 5) {
        logged++;
        enh_log(@"listDir(%@): %lu 项", path, (unsigned long)(r ? r.count : -1));
    }
    return r;
}

// document picker 回调 hook（运行时扫描宿主类）
static void (*orig_didPick)(id self, SEL _cmd, id picker, id urls);
static void new_didPick(id self, SEL _cmd, id picker, id urls) {
    enh_log(@"didPick 触发: %@", urls);
    enh_alert(@"导入回调已触发", [NSString stringWithFormat:@"收到 %@ 个文件，开始导入流程…\n\n若之后无文件出现，此弹窗后的日志即为断点。",
              @(urls ? [urls count] : 0)]);
    orig_didPick(self, _cmd, picker, urls);
}

static void hook_document_picker(void) {
    SEL sel = NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:");
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    int hooked = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class c = list[i];
        if (!class_getInstanceMethod(c, sel)) continue;
        // 跳过系统类（UIDocumentPickerViewController 自身等）
        const char *nm = class_getName(c);
        if (strncmp(nm, "UI", 2) == 0 || strncmp(nm, "PK", 2) == 0 || strncmp(nm, "_", 1) == 0) continue;
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        orig_didPick = (void (*)(id, SEL, id, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)new_didPick);
        enh_log(@"hook documentPicker delegate: %s", nm);
        hooked++;
        break;
    }
    free(list);
    if (!hooked) enh_log(@"未找到 documentPicker delegate 实现类");
}

__attribute__((constructor))
static void enhancer_init(void) {
    @autoreleasepool {
        // 等主二进制 ObjC 类已注册（constructor 时 dyld 已完成类注册）
        Class wrapper = NSClassFromString(@"ZMUnzipZipWrapper");
        Class vc = NSClassFromString(@"ZMFileMainViewController");
        swizzle(wrapper, @selector(unarchiveFile:desDir:progressBlock:compeleteBlock:),
                (IMP)new_unarchiveFile, (IMP *)&orig_unarchiveFile);
        swizzle(vc, @selector(handleUnzip:),
                (IMP)new_handleUnzip, (IMP *)&orig_handleUnzip);
        // iOS 26 兼容防护：App 启动/导入的文件拷贝抛异常 → 闪退/导入失败
        swizzle([NSFileManager class], @selector(copyItemAtPath:toPath:options:error:),
                (IMP)new_copyItemAtPath, (IMP *)&orig_copyItemAtPath);
        // 导入链路诊断：move/createFile/列目录 + document picker 回调
        swizzle([NSFileManager class], @selector(moveItemAtPath:toPath:error:),
                (IMP)new_moveItemAtPath, (IMP *)&orig_moveItemAtPath);
        swizzle([NSFileManager class], @selector(createFileAtPath:contents:attributes:),
                (IMP)new_createFileAtPath, (IMP *)&orig_createFileAtPath);
        swizzle([NSFileManager class], @selector(contentsOfDirectoryAtPath:error:),
                (IMP)new_contentsOfDirectory, (IMP *)&orig_contentsOfDirectory);
        hook_document_picker();
        enh_log(@"enhancer v8 loaded (unarchive/handleUnzip/copy/move/createFile/listDir/documentPicker)");
    }
}
