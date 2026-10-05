// test_main.m v15 — lz4 round-trip + 路由 + RAR5 volume 标志修补测试
// #include "enhancer.m" 合并编译：可访问 static 函数，constructor 自动执行（swizzle 生效）
#import <Foundation/Foundation.h>
#import <zlib.h>
#import "enhancer.m"

static int pass = 0, fails = 0;
static void ck(BOOL ok, const char *label) {
    printf("%s %s\n", ok ? "PASS" : "FAIL", label);
    if (ok) pass++; else fails++;
}

int main(void) {
    @autoreleasepool {
        printf("=== libipaenhancer v15 测试 ===\n");
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [[NSProcessInfo processInfo] globallyUniqueString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
            withIntermediateDirectories:YES attributes:nil error:nil];

        // ---- 1) lz4 round-trip（LZ4F_compressFrame → decode_lz4）----
        NSMutableString *big = [NSMutableString string];
        for (int i = 0; i < 20000; i++)
            [big appendString:@"预置中文测试 anohana LZ4 0123456789 abcdefgh\n"];
        NSData *plain = [big dataUsingEncoding:NSUTF8StringEncoding];

        size_t cap = LZ4F_compressFrameBound(plain.length, NULL);
        uint8_t *buf = (uint8_t *)malloc(cap);
        size_t clen = LZ4F_compressFrame(buf, cap, plain.bytes, plain.length, NULL);
        ck(!LZ4F_isError(clen), "LZ4F_compressFrame");

        NSString *lz4f = [dir stringByAppendingPathComponent:@"big.bin.lz4"];
        NSString *out = [dir stringByAppendingPathComponent:@"big.out"];
        [(NSData *)[NSData dataWithBytes:buf length:clen] writeToFile:lz4f atomically:YES];

        NSError *err = nil;
        BOOL ok = decode_lz4(lz4f, out, &err);
        ck(ok, "decode_lz4 执行");
        NSData *rt = [NSData dataWithContentsOfFile:out];
        ck(rt && rt.length == plain.length && memcmp(rt.bytes, plain.bytes, plain.length) == 0,
           "lz4 round-trip 逐字节一致");

        // ---- 2) 损坏输入 → 不会产生正确的完整输出 ----
        NSString *bad = [dir stringByAppendingPathComponent:@"bad.lz4"];
        [(NSData *)[NSData dataWithBytes:buf length:clen / 4] writeToFile:bad atomically:YES];
        NSString *badOut = [dir stringByAppendingPathComponent:@"bad.out"];
        BOOL badOk = decode_lz4(bad, badOut, &err);
        NSData *badRt = [NSData dataWithContentsOfFile:badOut];
        BOOL badCorrect = badRt && badRt.length == plain.length &&
                          memcmp(badRt.bytes, plain.bytes, plain.length) == 0;
        ck(!(badOk && badCorrect), "损坏 lz4 流不会误判为成功解出完整数据");

        // ---- 3) 路由（仅 lz4 家族命中，其余放行）----
        NSString *inner = nil;
        ck(decoderFor(@"/x/data.7z.lz4", &inner) != NULL && [inner isEqualToString:@"data.7z"],
           "路由 .7z.lz4 → data.7z");
        ck(decoderFor(@"/x/data.zip.lz4", &inner) != NULL && [inner isEqualToString:@"data.zip"],
           "路由 .zip.lz4 → data.zip");
        ck(decoderFor(@"/x/data.tar.lz4", &inner) != NULL && [inner isEqualToString:@"data.tar"],
           "路由 .tar.lz4 → data.tar");
        ck(decoderFor(@"/x/a.lz4", &inner) != NULL && [inner isEqualToString:@"a"],
           "路由 .lz4 → a");
        ck(decoderFor(@"/x/a.zip", &inner) == NULL, "放行 .zip（原逻辑）");
        ck(decoderFor(@"/x/a.gz", &inner) == NULL, "放行 .gz（原逻辑）");
        ck(decoderFor(@"/x/a.br", &inner) == NULL, "放行 .br（原逻辑）");
        ck(decoderFor(@"/x/a.bz2", &inner) == NULL, "放行 .bz2（原逻辑）");
        ck(decoderFor(@"/x/a.7z", &inner) == NULL, "放行 .7z（原逻辑）");

        // ---- 4) RAR5 volume 标志修补 ----
        {
            NSMutableData *rar = [NSMutableData dataWithBytes:"Rar!\x1a\x07\x01\x00" length:8];
            uint8_t hdr[] = {0, 0, 0, 0, 0x03, 0x01, 0x05}; // CRC占位 + hsz=3 + type=1 + flags=volume|solid
            [rar appendBytes:hdr length:7];
            NSString *rf = [dir stringByAppendingPathComponent:@"v.rar"];
            [rar writeToFile:rf atomically:YES];
            fixRarVolumeFlag(rf);
            NSData *fixed = [NSData dataWithContentsOfFile:rf];
            const uint8_t *b = (const uint8_t *)fixed.bytes;
            ck(fixed.length == rar.length, "RAR5 修补不改变文件长度");
            ck(b[14] == 0x04, "RAR5 volume 标志已清除");
            // 用 zlib 独立验证重算的 CRC32（header 区 = offset 12 起 hsz=3 字节 {0x03,0x01,0x04}）
            uint32_t expect = (uint32_t)crc32(0, b + 12, 3);
            uint32_t got = b[8] | (b[9] << 8) | (b[10] << 16) | ((uint32_t)b[11] << 24);
            ck(got == expect, "RAR5 header CRC32 重算正确");
        }

        printf("汇总: PASS %d FAIL %d\n", pass, fails);
        return fails ? 1 : 0;
    }
}
