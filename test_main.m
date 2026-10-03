// test_main.m — enhancer 逻辑的 macOS 宿主测试
// #include "enhancer.m" 合并编译：可访问 static 函数，constructor 自动执行（swizzle 生效）
// 在 macOS Foundation（与 iOS 同源实现）上验证：路由表 / 五格式解码 / 接力 / copyItemAtPath 防护
#import <Foundation/Foundation.h>
#import "enhancer.m"
#import "brotli/encode.h"

static int g_pass = 0, g_fail = 0;

static void T(NSString *name, BOOL ok, NSString *detail) {
    printf("  [%s] %s%s\n", ok ? "PASS" : "FAIL", name.UTF8String ?: "",
           ok ? "" : [[NSString stringWithFormat:@" | %@", detail ?: @"-"] UTF8String]);
    if (ok) g_pass++; else g_fail++;
}

static NSData *readFile(NSString *p) { return [NSData dataWithContentsOfFile:p]; }
static BOOL writeFile(NSString *p, NSData *d) { return [d writeToFile:p atomically:YES]; }
static BOOL eqDataOk(NSData *a, NSData *b) { return a && b && [a isEqualToData:b]; }
static NSString *fnNameOf(DecoderFn fn) {
    if (fn == decode_lz4) return @"lz4";
    if (fn == decode_brotli) return @"brotli";
    if (fn == decode_gzip) return @"gzip";
    if (fn == decode_bzip2) return @"bzip2";
    return nil;
}

// ---------- 1. 路由表 ----------
static void test_routing(void) {
    printf("== 路由表 ==\n");
    struct { const char *in; const char *inner; const char *dec; } cases[] = {
        {"data.7z.lz4",    "data.7z",    "lz4"},
        {"BACKUP.ZIP.LZ4", "BACKUP.zip", "lz4"},
        {"x.tar.lz4",      "x.tar",      "lz4"},
        {"doc.tar.gz",     "doc.tar",    "gzip"},
        {"img.TGZ",        "img.tar",    "gzip"},
        {"f.tbz2",         "f.tar",      "bzip2"},
        {"f.tar.bz2",      "f.tar",      "bzip2"},
        {"plain.lz4",      "plain",      "lz4"},
        {"a.gz",           "a",          "gzip"},
        {"a.br",           "a",          "brotli"},
        {"a.xz",           "a",          NULL},
        {"noext",          NULL,         NULL},
        {"a.7z",           NULL,         NULL},
    };
    int n = (int)(sizeof(cases) / sizeof(cases[0]));
    for (int i = 0; i < n; i++) {
        NSString *in = @(cases[i].in);
        NSString *inner = nil;
        DecoderFn fn = decoderFor(in, &inner);
        NSString *fnName = fnNameOf(fn);
        BOOL ok = (cases[i].inner ? [inner isEqualToString:@(cases[i].inner)] : inner == nil)
               && (cases[i].dec ? [fnName isEqualToString:@(cases[i].dec)] : fnName == nil);
        T([NSString stringWithFormat:@"route %s", cases[i].in], ok,
          [NSString stringWithFormat:@"got inner=%@ dec=%@ want inner=%@ dec=%@",
           inner ?: @"nil", fnName ?: @"放行",
           cases[i].inner ? @(cases[i].inner) : @"nil",
           cases[i].dec ? @(cases[i].dec) : @"放行"]);
    }
}

// ---------- 2. lz4 round-trip + 双层 ----------
static void test_lz4(void) {
    printf("== lz4 round-trip ==\n");
    NSMutableData *src = [NSMutableData dataWithCapacity:5 << 20];
    srand(42);
    for (int i = 0; i < (5 << 20) / 4; i++) {
        uint32_t v = (i % 100 < 80) ? (uint32_t)(i % 7) : (uint32_t)rand();
        [src appendBytes:&v length:4];
    }
    NSData *srcData = [src copy];
    size_t cap = LZ4F_compressFrameBound(srcData.length, NULL);
    NSMutableData *comp = [NSMutableData dataWithLength:cap];
    size_t clen = LZ4F_compressFrame(comp.mutableBytes, cap, srcData.bytes, srcData.length, NULL);
    if (LZ4F_isError(clen)) { T(@"lz4 compress", NO, @"frame error"); return; }
    comp.length = clen;

    NSString *srcP = [NSTemporaryDirectory() stringByAppendingPathComponent:@"t.lz4"];
    NSString *dstP = [NSTemporaryDirectory() stringByAppendingPathComponent:@"t.out"];
    writeFile(srcP, comp);
    NSError *err = nil;
    BOOL ok = decode_lz4(srcP, dstP, &err);
    T(@"lz4 decode", ok, err.localizedDescription ?: @"-");
    T(@"lz4 round-trip 内容一致", ok && eqDataOk(readFile(dstP), srcData), ok ? @"-" : @"内容不一致");

    // 双层语义：payload.7z.lz4 → innerName=payload.7z → decode → 内容应为 7z 原始字节
    NSString *fake = [NSTemporaryDirectory() stringByAppendingPathComponent:@"payload.7z.lz4"];
    writeFile(fake, comp);
    NSString *inner = nil;
    DecoderFn fn = decoderFor(fake, &inner);
    NSString *innerDst = [NSTemporaryDirectory() stringByAppendingPathComponent:(inner ?: @"x")];
    ok = (fn != NULL) && [inner isEqualToString:@"payload.7z"] && decode_lz4(fake, innerDst, &err);
    T(@".7z.lz4 双层接力命名+解码", ok,
      [NSString stringWithFormat:@"inner=%@ err=%@", inner ?: @"nil", err.localizedDescription ?: @"-"]);
}

// ---------- 3. gz / bz2 / brotli round-trip ----------
static void test_gz_bz2_br(void) {
    printf("== gz / bz2 / brotli round-trip ==\n");
    NSMutableData *src = [NSMutableData data];
    for (int i = 0; i < 100000; i++) {
        uint8_t b = (uint8_t)"hello world compress test 123 "[i % 29];
        [src appendBytes:&b length:1];
    }
    NSData *srcData = [src copy];
    NSString *dstP = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rt.out"];
    NSError *err = nil;

    // gzip（zlib windowBits 31）
    z_stream zs = {};
    deflateInit2(&zs, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY);
    NSMutableData *gz = [NSMutableData dataWithLength:(NSUInteger)deflateBound(&zs, (uLong)srcData.length)];
    zs.next_out = (Bytef *)gz.mutableBytes; zs.avail_out = (uInt)gz.length;
    zs.next_in = (Bytef *)srcData.bytes; zs.avail_in = (uInt)srcData.length;
    deflate(&zs, Z_FINISH); gz.length = (NSUInteger)zs.total_out; deflateEnd(&zs);
    NSString *gp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rt.gz"];
    writeFile(gp, gz);
    BOOL ok = decode_gzip(gp, dstP, &err);
    T(@"gz decode+round-trip", ok && eqDataOk(readFile(dstP), srcData), err.localizedDescription ?: @"-");

    // bz2
    unsigned int cb = (unsigned int)(srcData.length + srcData.length / 100 + 600);
    NSMutableData *bz = [NSMutableData dataWithLength:cb];
    unsigned int blen = cb;
    BZ2_bzBuffToBuffCompress((char *)bz.mutableBytes, &blen,
                             (char *)srcData.bytes, (unsigned int)srcData.length, 5, 0, 0);
    bz.length = blen;
    NSString *bp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rt.bz2"];
    writeFile(bp, bz);
    ok = decode_bzip2(bp, dstP, &err);
    T(@"bz2 decode+round-trip", ok && eqDataOk(readFile(dstP), srcData), err.localizedDescription ?: @"-");

    // brotli（编码器来自 brotli/c/enc）
    size_t eb = BrotliEncoderMaxCompressedSize(srcData.length);
    NSMutableData *br = [NSMutableData dataWithLength:eb ?: 1024];
    size_t brLen = br.length;
    BrotliEncoderCompress(BROTLI_DEFAULT_QUALITY, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_GENERIC,
                          srcData.length, (const uint8_t *)srcData.bytes, &brLen,
                          (uint8_t *)br.mutableBytes);
    br.length = brLen;
    NSString *brp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rt.br"];
    writeFile(brp, br);
    ok = decode_brotli(brp, dstP, &err);
    T(@"brotli decode+round-trip", ok && eqDataOk(readFile(dstP), srcData), err.localizedDescription ?: @"-");
}

// ---------- 4. copyItemAtPath 防护（constructor 已 swizzle） ----------
static void test_copy_protection(void) {
    printf("== copyItemAtPath 防护 ==\n");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"enhtest"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *src = [dir stringByAppendingPathComponent:@"src.bin"];
    NSString *dst = [dir stringByAppendingPathComponent:@"dst.bin"];
    writeFile(src, [@"payload-bytes" dataUsingEncoding:NSUTF8StringEncoding]);
    [fm removeItemAtPath:dst error:nil];

    NSError *err = nil;
    BOOL ok = [fm copyItemAtPath:src toPath:dst error:&err];
    T(@"copy 正常路径", ok, err.localizedDescription ?: @"-");

    err = nil;
    ok = [fm copyItemAtPath:src toPath:dst error:&err];
    T(@"copy 目标已存在 → 幂等 YES", ok, err.localizedDescription ?: @"-");

    err = nil;
    ok = [fm copyItemAtPath:[dir stringByAppendingPathComponent:@"no-such-file.bin"]
                     toPath:dst error:&err];
    T(@"copy 源不存在 → NO 不崩", ok == NO, @"-");
}

// ---------- 5. 双层接力端到端（tar.gz → tar） ----------
static BOOL mkd(NSString *d) { return [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil]; }

static void test_relay_targz(void) {
    printf("== tar.gz 接力 ==\n");
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"relay"];
    mkd(dir);
    writeFile([dir stringByAppendingPathComponent:@"a.txt"],
              [@"tar content for relay test" dataUsingEncoding:NSUTF8StringEncoding]);
    NSTask *tar = [[NSTask alloc] init];
    tar.launchPath = @"/usr/bin/tar";
    tar.arguments = @[@"-cf", @"arch.tar", @"a.txt"];
    tar.currentDirectoryPath = dir;
    [tar launch]; [tar waitUntilExit];

    NSData *tarData = readFile([dir stringByAppendingPathComponent:@"arch.tar"]);
    z_stream zs = {};
    deflateInit2(&zs, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY);
    NSMutableData *gz = [NSMutableData dataWithLength:(NSUInteger)deflateBound(&zs, (uLong)tarData.length)];
    zs.next_out = (Bytef *)gz.mutableBytes; zs.avail_out = (uInt)gz.length;
    zs.next_in = (Bytef *)tarData.bytes; zs.avail_in = (uInt)tarData.length;
    deflate(&zs, Z_FINISH); gz.length = (NSUInteger)zs.total_out; deflateEnd(&zs);
    NSString *tgzP = [dir stringByAppendingPathComponent:@"arch.tar.gz"];
    writeFile(tgzP, gz);

    NSString *inner = nil;
    DecoderFn fn = decoderFor(tgzP, &inner);
    NSString *innerDst = [dir stringByAppendingPathComponent:(inner ?: @"x.tar")];
    NSError *err = nil;
    BOOL ok = (fn != NULL) && [inner isEqualToString:@"arch.tar"] && decode_gzip(tgzP, innerDst, &err);
    T(@"tar.gz innerName+解码+内容一致", ok && eqDataOk(readFile(innerDst), tarData),
      [NSString stringWithFormat:@"inner=%@ err=%@", inner ?: @"nil", err.localizedDescription ?: @"-"]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("=== libipaenhancer macOS 宿主测试 ===\n");
        test_routing();
        test_lz4();
        test_gz_bz2_br();
        test_copy_protection();
        test_relay_targz();
        printf("\n=== 汇总: PASS %d / FAIL %d ===\n", g_pass, g_fail);
        return g_fail ? 1 : 0;
    }
}
