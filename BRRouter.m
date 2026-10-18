#import "BRZlib.h"
#import "BRRouter.h"
#import "BRStore.h"
#import "BRSession.h"
#import "BRURLProtocol.h"   // [BRPREFETCH] kBRInternalKey（内部请求标记）
#import "BRLog.h"

@implementation BRRoute
- (NSString *)description {
    return [NSString stringWithFormat:@"<BRRoute %@ %@>", self.kind, self.url];
}
@end

#pragma mark - 小工具

static NSString *BRUrlDecode(NSString *s) {
    return [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: s;
}

// 解析 query（值做一次 decode）
static NSMutableDictionary *BRParseQuery(NSString *query) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (![query length]) return d;
    for (NSString *kv in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [kv rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [kv substringToIndex:eq.location];
        NSString *v = BRUrlDecode([kv substringFromIndex:eq.location + 1]);
        if ([k length]) [d setObject:v forKey:k];
    }
    return d;
}

static NSNumber *BRNumValue(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSString class]]) return @([v longLongValue]);
    return @0;
}

static NSString *BRNum(id v) {
    if (v == nil || v == [NSNull null]) return @"0";
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    if ([v isKindOfClass:[NSString class]]) return v;
    return [v description];
}


// ==== 照搬 5.9 参考实现的辅助函数 ====
static NSString *BRPicFix(NSString *p) {
    if (![p length]) return p ?: @"";
    if ([p hasPrefix:@"//"])      return [@"https:" stringByAppendingString:p];
    if ([p hasPrefix:@"http://"]) return [@"https://" stringByAppendingString:[p substringFromIndex:7]];
    return p;
}

static NSString *BRFmtDuration(id d) {
    long long v = 0;
    if ([d respondsToSelector:@selector(longLongValue)]) v = [d longLongValue];
    if (v <= 0) return @"0:00";
    long long h = v / 3600, mm = (v % 3600) / 60, ss = v % 60;
    if (h > 0) return [NSString stringWithFormat:@"%lld:%02lld:%02lld", h, mm, ss];
    return [NSString stringWithFormat:@"%lld:%02lld", mm, ss];
}


// 判断某类转换器是否被开关禁用（全局 /tmp/br-noconv 或 per-kind /tmp/br-noconv-<kind>）
static BOOL BRConvOff(NSString *kind) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/tmp/br-noconv"]) return YES;
    if ([kind length]) {
        NSString *p = [NSString stringWithFormat:@"/tmp/br-noconv-%@", kind];
        if ([fm fileExistsAtPath:p]) return YES;
    }
    return NO;
}

// [BRFILL_V2] gzip 旗标：集中在这一处定义。
//   ★ 必须真正有定义：只声明不定义 → 未定义符号 → dyld 解析失败 → dylib 加载后被卸载
//     （本项目历史上反复踩的坑，见 Makefile 顶部注释）。
//   之前是 extern 全局量，只有同步路径会写它，别处会残留上一次请求的值。
static BOOL s_BRRespWasGzip = NO;
void BRSetRespWasGzip(BOOL v) { s_BRRespWasGzip = v; }
BOOL BRRespWasGzip(void) { return s_BRRespWasGzip; }




// 分区名映射 —— 取自 App 自带的 tidMetaV2.json（含常见一级分区）
static NSString *BRRegionNameForRid(NSString *rid) {
    static NSDictionary *m = nil;
    if (m == nil) {
        m = @{
            @"1":@"动画", @"13":@"番剧", @"167":@"国创", @"3":@"音乐", @"129":@"舞蹈",
            @"4":@"游戏", @"36":@"科技", @"188":@"数码", @"5":@"娱乐", @"119":@"鬼畜",
            @"155":@"时尚", @"160":@"生活", @"168":@"影视", @"181":@"影视",
            @"211":@"美食", @"217":@"动物圈", @"223":@"汽车", @"234":@"运动",
            @"249":@"生活兴趣", @"25":@"MAD·AMV", @"26":@"MMD·3D", @"27":@"综合",
            @"17":@"单机联机", @"65":@"网络游戏", @"60":@"电子竞技", @"136":@"音游",
            @"19":@"Mugen", @"121":@"GMV", @"31":@"翻唱", @"30":@"VOCALOID·UTAU",
            @"59":@"演奏", @"130":@"音乐选集", @"153":@"国产动画",
            @"124":@"趣味科普人文", @"122":@"野生技术协会", @"96":@"军事",
            @"95":@"数码", @"98":@"机械",
            @"171":@"电子竞技", @"172":@"手机游戏", @"173":@"桌游棋牌",
            @"174":@"GMV", @"175":@"音游", @"71":@"综艺", @"137":@"明星综合"
        };
    }
    NSString *n = [m objectForKey:(rid ?: @"")];
    return n ?: [NSString stringWithFormat:@"分区%@", rid ?: @"?"];
}



@implementation BRRouter

// ---------------------------------------------------------------------------
// GZIP 工具
//   实测：/x/v2/show 返回的是 gzip 压缩体（日志里 head 为空就是这个原因）。
//   App 自己会解压，所以「原样透传」时正常；一旦我们要改 JSON，就必须
//   自己先解压、改完再决定是否压缩，并且同步修正 Content-Encoding。
// ---------------------------------------------------------------------------
+ (NSData *)gunzip:(NSData *)src {
    if (src == nil || [src length] < 2) return src;
    // 不是 gzip → 原样返回（保持老语义：不要 NULL 化调用方数据）
    if (!BRIsGzipHeader(src)) return src;
    // ★ 交给 BRZlib：zlib 是运行时 dlopen 的，拿不到就用原始数据，
    //   绝不因为解压不可用而让调用方拿到 nil。
    NSData *plain = BRGunzipData(src);
    if (plain == nil) {
        BRERR(@"[改写] gunzip 失败（zlib 不可用？），返回原始数据 %lu 字节",
              (unsigned long)[src length]);
        return src;
    }
    return plain;
}

// 从响应头里判断 Content-Encoding
static BOOL BRIsGzipResponse(NSURLResponse *r) {
    @try {
        if (![r isKindOfClass:[NSHTTPURLResponse class]]) return NO;
        NSDictionary *h = [(NSHTTPURLResponse *)r allHeaderFields];
        NSString *e = nil;
        for (NSString *k in h) {
            if ([k caseInsensitiveCompare:@"Content-Encoding"] == NSOrderedSame) {
                e = [h objectForKey:k]; break;
            }
        }
        return (e != nil && [e rangeOfString:@"gzip" options:NSCaseInsensitiveSearch].location != NSNotFound);
    } @catch (NSException *e) { return NO; }
}


// ---------------------------------------------------------------------------
// 首页分区卡片：插件自己取数据
//   App 期望首页一次返回所有卡片（推荐 + 各分区），而现代接口只给视频列表，
//   所以由插件补齐。数据源用 UWP 的 dynamic/child（实测 code=0、有数据）。
// ---------------------------------------------------------------------------

// 直连 GET（同步；调用方在后台线程 —— 同步路径本来就是后台）
// [BRPREFETCH] 分區結果快取 —— 提升到檔案級，讓並行預取能先灌進來。
//   key = rid（字串），value = @{@"t": 時間, @"v": 已轉換的陣列}
//   TTL 120 秒（原本 fetchRegionVideos 內就有這個快取，這裡只是搬上來共用）。
static NSMutableDictionary *gBRRegionCache = nil;

// =====================================================================
// [BRPREFETCH] 並行預取分區榜單
//   原本 15 個分區**循序**抓 ranking/region，實測要 52 秒 → 首頁卡住近一分鐘。
//   這裡改成併發（同時最多 5 條），先收進臨時字典，全部結束後
//   **在當前執行緒**一次性併入 gBRRegionCache；
//   後面既有的循序迴圈就全部命中快取 → 總時間從 ~52 秒降到約 10 秒。
//
//   為什麼現在才能並行：BRRegionHttpGet 原本只靠執行緒閘門（BRFetchDepth），
//   只能在「已在抓取的同一條執行緒」上發出；本補丁為它補上了
//   request 標記 kBRInternalKey（執行緒無關）→ 跨執行緒才安全。
//
//   安全性：
//     ① 併發限 5，避免一次 15 條觸發 B 站風控
//     ② 併入快取只在本執行緒做 → gBRRegionCache 不會被多執行緒同時寫
//     ③ 任何失敗都不影響原流程（沒灌進快取，迴圈照舊自己抓）
//     ④ /tmp/br-noprefetch 可完全關閉
// =====================================================================
// [BRPREFETCH] 前置宣告 —— BRRegionHttpGet 的定義在下面，
//   不先宣告會在 C99 下變成隱式宣告 → 編譯錯誤。
static NSData *BRRegionHttpGet(NSString *url);

static void BRPrefetchRegionRank(NSArray *rids) {
    if (![rids isKindOfClass:[NSArray class]] || [rids count] == 0) return;
    @try {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-noprefetch"]) {
            BRDBG(@"[改写] 并行预取已被 /tmp/br-noprefetch 关闭");
            return;
        }
        NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];
        NSMutableDictionary *pre = [[NSMutableDictionary alloc] init];
        dispatch_semaphore_t sem = dispatch_semaphore_create(5);
        dispatch_group_t grp = dispatch_group_create();
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

        for (NSString *rid in rids) {
            dispatch_group_async(grp, q, ^{
                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                @try {
                    NSString *u = [NSString stringWithFormat:
                        @"https://api.bilibili.com/x/web-interface/ranking/region"
                        @"?rid=%@&day=3", rid];
                    NSData *d = BRRegionHttpGet(u);
                    if (d != nil) {
                        NSDictionary *j = [BRRouter jsonFromData:d];
                        id lst = [j objectForKey:@"data"];
                        if ([lst isKindOfClass:[NSArray class]] &&
                            [(NSArray *)lst count] > 0) {
                            // [BRPREFETCH_CAP] 上限必須與 fetchRegionVideos 的
                            //   `if ([out count] >= want) break;` 一致（want=4）。
                            //   否則：① 快取內容不一致（卡片會拿到 11 筆而非 4 筆）
                            //         ② brRegionElement 會呼叫 BRStore
                            //            fakeAidForReal:，而它在鎖內每次分配都
                            //            BRSaveMap() 寫檔 → 165 次磁碟寫入（原本 60 次）
                            const NSUInteger BRP_WANT = 4;
                            NSMutableArray *out = [NSMutableArray array];
                            NSMutableSet *seen = [NSMutableSet set];
                            for (id one in (NSArray *)lst) {
                                if ([out count] >= BRP_WANT) break;
                                if (![one isKindOfClass:[NSDictionary class]]) continue;
                                NSDictionary *e =
                                    [BRRouter brRegionElement:one
                                                    playValue:[one objectForKey:@"play"]
                                                 danmakuValue:[one objectForKey:@"video_review"]
                                                         seen:seen];
                                if (e != nil) [out addObject:e];
                            }
                            if ([out count] > 0) {
                                @synchronized (pre) {
                                    [pre setObject:@{
                                        @"t": @([[NSDate date] timeIntervalSince1970]),
                                        @"v": out
                                    } forKey:rid];
                                }
                            }
                        }
                    }
                } @catch (NSException *e) { }
                dispatch_semaphore_signal(sem);
            });
        }

        // 最多等 25 秒（首頁總預算 55 秒的一部分）
        long w = dispatch_group_wait(grp,
                                     dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)(25 * NSEC_PER_SEC)));

        // ★ 只在本執行緒併入 → 不會有多執行緒競爭
        @synchronized (gBRRegionCache) {
            if (gBRRegionCache == nil) {
                gBRRegionCache = [[NSMutableDictionary alloc] init];
            }
            [gBRRegionCache addEntriesFromDictionary:pre];
        }
        BRINFO(@"[改写] oldhome 并行预取：%lu 个分区，命中 %lu 个，耗时 %.1f 秒%@",
               (unsigned long)[rids count], (unsigned long)[pre count],
               [[NSDate date] timeIntervalSince1970] - t0,
               (w != 0) ? @"（等待超时，未全部完成，其余回圈自己抓）" : @"");
    } @catch (NSException *e) {
        BRERR(@"[改写] 并行预取异常（不影响原流程）: %@", [e description]);
    }
}

static NSData *BRRegionHttpGet(NSString *url) {
    @try {
        Class reqCls = NSClassFromString(@"NSMutableURLRequest");
        Class connCls = NSClassFromString(@"NSURLConnection");
        if (reqCls == Nil || connCls == Nil) return nil;
        NSURL *u = [NSURL URLWithString:url];
        if (u == nil) return nil;
        id rq = [reqCls requestWithURL:u];
        [rq setTimeoutInterval:3];   // ★ 8s 太久，会把首页请求卡死
        [rq setValue:@"Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android"
   forHTTPHeaderField:@"User-Agent"];
        // [BRPREFETCH] 打上「內部請求」標記 —— 這是**執行緒無關**的遞迴保護。
        //   BRURLProtocol 的 canInitWithRequest: 看到這個標記就直接放行。
        //   原本只靠執行緒閘門 BRFetchDepth，所以我們的請求只能在
        //   「已經在抓取的同一條執行緒」上發出 → 無法並行。補上標記後才安全。
        @try {
            [NSClassFromString(@"NSURLProtocol") setProperty:@YES
                                                       forKey:kBRInternalKey
                                                    inRequest:rq];
        } @catch (NSException *e) { }
        return [connCls sendSynchronousRequest:rq returningResponse:NULL error:NULL];
    } @catch (NSException *e) { return nil; }
}

// 取某分区的若干条视频，并转成老客户端能吃的条目
// =====================================================================
// [BRLIVEX] 直播 / 番劇 回應轉換   [BRLIVEX_FIX2]
//   來源是 2026-10-16 從 App 二進位抽出的 ObjC ivar 名稱：
//     BiliLiveList { count, hasNext, livelist[], page, status, totalCount, totalPage }
//     BiliLiveItem { attention, cover, face, mid, online, room_id, status,
//                    title, uname, vip, svip, ... }
//     BBPhoneBangumiHomeModel { banners, categories, finishedBangumis,
//                               latestUpdate, recommendCategory }
//     BBPhoneBangumiTimelineModel { ep_id, ep_index, ep_index_ui, dayIndex,
//                                   follow, is_published, ontime, season_id, ... }
//   欄位同時輸出 snake_case 與 camelCase 兩種寫法，最大化命中率
//   （模型 ivar 有 room_id 也有 hasNext 這種駝峰）。
// =====================================================================

+ (NSDictionary *)brLiveRoomFromDict:(NSDictionary *)it {
    @try {
        if (![it isKindOfClass:[NSDictionary class]]) return nil;
        // [BRLIVECOVER] 截圖顯示直播列表的標題與人數都出來了，但封面是灰的。
        //   先記錄上游到底給了哪些欄位（不同 xlive 介面用不同名字），再決定對映。
        {
            static NSMutableSet *gSeen = nil;
            if (gSeen == nil) gSeen = [[NSMutableSet alloc] init];
            NSString *sig = [[[it allKeys] sortedArrayUsingSelector:@selector(compare:)]
                             componentsJoinedByString:@","];
            if (![gSeen containsObject:sig]) {
                [gSeen addObject:sig];
                BRINFO(@"[改写] 直播房间字段样本: %@", sig);
            }
        }
        id ridRaw = [it objectForKey:@"roomid"];
        if (ridRaw == nil) ridRaw = [it objectForKey:@"room_id"];
        long long room = 0;
        if ([ridRaw respondsToSelector:@selector(longLongValue)]) room = [ridRaw longLongValue];
        else if ([ridRaw isKindOfClass:[NSString class]]) room = [(NSString *)ridRaw longLongValue];
        if (room <= 0) return nil;

        id midRaw = [it objectForKey:@"uid"];
        if (midRaw == nil) midRaw = [it objectForKey:@"mid"];
        if (midRaw == nil) midRaw = [it objectForKey:@"up_id"];

        // status 在 recommend_room_list 裡沒有，在 room_list[].list 裡是 bool
        NSNumber *st = @1;
        id stRaw = [it objectForKey:@"status"];
        if (stRaw != nil && [stRaw respondsToSelector:@selector(boolValue)])
            st = [stRaw boolValue] ? @1 : @0;
        // 直播中才有 online；online<=0 視為未開播
        id onlineRaw = [it objectForKey:@"online"];
        long long online = 0;
        if ([onlineRaw respondsToSelector:@selector(longLongValue)])
            online = [onlineRaw longLongValue];
        if (online <= 0) st = @0;

        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        [o setObject:@(room) forKey:@"room_id"];
        [o setObject:@(room) forKey:@"roomid"];
        [o setObject:([it objectForKey:@"title"] ?: @"") forKey:@"title"];
        [o setObject:([it objectForKey:@"uname"] ?: @"") forKey:@"uname"];
        // [BRLIVECARD] 首頁「正在直播」卡（config 樣本）的元素欄位是
        //   { title, cover, param, name, face, online, area, area_id, finish }
        //   其中 param 是 **room_id 的字串**（樣本 '37034'）、name 是主播名。
        //   這裡補上這兩個別名 —— 純新增，不會影響直播 tab（它讀 room_id/uname）。
        [o setObject:([it objectForKey:@"uname"] ?: @"") forKey:@"name"];
        [o setObject:[NSString stringWithFormat:@"%lld", room] forKey:@"param"];
        [o setObject:@(online) forKey:@"online"];
        // [BRLIVECOVER_FB] ★ 直播封面是灰的：真機診斷顯示上游同時有
        //   cover / cover_source / keyframe 三個候選欄位。
        //   cover 為空時依序退回，避免整個列表都是灰框。
        {
            id cv = [it objectForKey:@"cover"];
            if (![cv isKindOfClass:[NSString class]] || ![cv length])
                cv = [it objectForKey:@"cover_source"];
            if (![cv isKindOfClass:[NSString class]] || ![cv length])
                cv = [it objectForKey:@"keyframe"];
            if (![cv isKindOfClass:[NSString class]]) cv = @"";
            [o setObject:BRPicFix(cv) forKey:@"cover"];
        }
        [o setObject:BRPicFix([it objectForKey:@"face"] ?: @"") forKey:@"face"];
        // [BRMODELFILL] ★ 對照模型 BiliLiveItem（18 個 ivar），
        //   我們原本只給了 9 個；缺的這些 App 會取到 nil。
        //   全部純新增，成本極低。
        {
            id v1 = [it objectForKey:@"vip"];
            id v2 = [it objectForKey:@"svip"];
            [o setObject:(v1 ?: @0) forKey:@"vip"];
            [o setObject:(v2 ?: @0) forKey:@"svip"];
            id cm = [it objectForKey:@"cmt"];
            [o setObject:(cm ?: @0) forKey:@"cmt"];
            [o setObject:(cm ?: @0) forKey:@"comment"];
            id ct = [it objectForKey:@"create"];
            id ca = [it objectForKey:@"create_at"];
            [o setObject:(ct ?: @0) forKey:@"create"];
            [o setObject:(ca ?: @0) forKey:@"create_at"];
            id st = [it objectForKey:@"start"];
            id sa = [it objectForKey:@"start_at"];
            [o setObject:(st ?: @0) forKey:@"start"];
            [o setObject:(sa ?: @0) forKey:@"start_at"];
            id sc = [it objectForKey:@"sch_id"];
            [o setObject:(sc ?: @0) forKey:@"sch_id"];
        }
        if (midRaw != nil) {
            [o setObject:midRaw forKey:@"mid"];
            [o setObject:midRaw forKey:@"uid"];
        }
        [o setObject:st forKey:@"status"];
        // 關注狀態（老模型叫 attention，新介面叫 follow_status）
        id fp = [it objectForKey:@"follow_status"];
        [o setObject:(fp ?: @0) forKey:@"attention"];
        [o setObject:(fp ?: @0) forKey:@"follow"];
        [o setObject:([it objectForKey:@"followers"] ?: @0) forKey:@"fans"];
        // 分區
        [o setObject:([it objectForKey:@"area_v2_name"] ?: @"") forKey:@"area"];
        [o setObject:([it objectForKey:@"area_v2_name"] ?: @"") forKey:@"area_v2_name"];
        [o setObject:([it objectForKey:@"area_v2_id"] ?: @0) forKey:@"area_id"];
        [o setObject:([it objectForKey:@"area_v2_id"] ?: @0) forKey:@"area_v2_id"];
        [o setObject:([it objectForKey:@"area_v2_parent_name"] ?: @"") forKey:@"area_v2_parent_name"];
        [o setObject:([it objectForKey:@"area_v2_parent_id"] ?: @0) forKey:@"area_v2_parent_id"];
        [o setObject:BRPicFix([it objectForKey:@"keyframe"] ?: @"") forKey:@"keyframe"];
        // 老模型有但新介面不提供的，給 0 避免 nil
        for (NSString *k in @[@"cmt", @"comment", @"create", @"create_at",
                              @"start", @"start_at", @"sch_id", @"vip", @"svip",
                              @"watched_show_num"]) {
            [o setObject:@0 forKey:k];
        }
        return o;
    } @catch (NSException *e) {
        return nil;
    }
}

+ (NSDictionary *)brTimelineToOld:(NSDictionary *)j {
    @try {
        id res = [j objectForKey:@"result"];
        if (res == nil) res = [j objectForKey:@"data"];
        if (![res isKindOfClass:[NSArray class]]) return nil;
        NSMutableArray *days = [NSMutableArray array];
        for (id day in res) {
            if (![day isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            id date = [day objectForKey:@"date"];
            id dow  = [day objectForKey:@"day_of_week"];
            [d setObject:(date ?: @"") forKey:@"date"];
            [d setObject:(dow ?: @0) forKey:@"day_of_week"];
            [d setObject:(dow ?: @0) forKey:@"dayIndex"];
            [d setObject:([day objectForKey:@"is_today"] ?: @0) forKey:@"is_today"];
            // [BRMODELFILL_TL] 對照 BBPhoneBangumiTimelineModel（16 個 ivar），
            //   補上缺少的 badge 與 season_status（純新增）。
            {
                id bd = [day objectForKey:@"badge"];
                [d setObject:(bd ?: @"") forKey:@"badge"];
                id ss = [day objectForKey:@"season_status"];
                [d setObject:(ss ?: @0) forKey:@"season_status"];
            }
            NSMutableArray *eps = [NSMutableArray array];
            id rawEps = [day objectForKey:@"episodes"];
            if ([rawEps isKindOfClass:[NSArray class]]) {
                for (id e in rawEps) {
                    if (![e isKindOfClass:[NSDictionary class]]) continue;
                    id epId = [e objectForKey:@"episode_id"];
                    if (epId == nil) epId = [e objectForKey:@"ep_id"];
                    // [BRLIVEX_FIX2] 沒有 ep_id 的集數直接跳過 —— 輸出殘缺項會讓
                    //   App 拿到無法開啟的卡片（實測 50 集裡有 1 集如此）。
                    long long epLL = 0;
                    if ([epId respondsToSelector:@selector(longLongValue)])
                        epLL = [epId longLongValue];
                    if (epLL <= 0) continue;
                    id pubIdx = [e objectForKey:@"pub_index"];
                    id follows = [e objectForKey:@"follows"];
                    id plays = [e objectForKey:@"plays"];
                    NSMutableDictionary *x = [NSMutableDictionary dictionary];
                    [x setObject:(epId ?: @0) forKey:@"ep_id"];
                    [x setObject:(epId ?: @0) forKey:@"episode_id"];
                    [x setObject:([e objectForKey:@"season_id"] ?: @0) forKey:@"season_id"];
                    [x setObject:([e objectForKey:@"title"] ?: @"") forKey:@"title"];
                    [x setObject:BRPicFix([e objectForKey:@"cover"] ?: @"") forKey:@"cover"];
                    [x setObject:BRPicFix([e objectForKey:@"square_cover"] ?: @"") forKey:@"square_cover"];
                    [x setObject:BRPicFix([e objectForKey:@"ep_cover"] ?: @"") forKey:@"ep_cover"];
                    [x setObject:(pubIdx ?: @"") forKey:@"pub_index"];
                    [x setObject:(pubIdx ?: @"") forKey:@"ep_index"];
                    [x setObject:(pubIdx ?: @"") forKey:@"ep_index_ui"];
                    [x setObject:([e objectForKey:@"pub_time"] ?: @"") forKey:@"pub_time"];
                    [x setObject:([e objectForKey:@"pub_ts"] ?: @0) forKey:@"pub_ts"];
                    [x setObject:([e objectForKey:@"published"] ?: @0) forKey:@"published"];
                    [x setObject:([e objectForKey:@"published"] ?: @0) forKey:@"is_published"];
                    [x setObject:([e objectForKey:@"delay"] ?: @0) forKey:@"delay"];
                    [x setObject:([e objectForKey:@"delay_reason"] ?: @"") forKey:@"delay_reason"];
                    [x setObject:(follows ?: @"-") forKey:@"follow"];
                    [x setObject:(follows ?: @"-") forKey:@"follows"];
                    [x setObject:(plays ?: @"-") forKey:@"plays"];
                    // 只有在「已播」且沒有 delay 時才算準時
                    id delay = [e objectForKey:@"delay"];
                    BOOL late = ([delay respondsToSelector:@selector(boolValue)] && [delay boolValue]);
                    [x setObject:(late ? @0 : @1) forKey:@"ontime"];
                    [x setObject:(date ?: @"") forKey:@"date"];
                    // [BRLIVEX_FIX2] dayIndex 也要放在每一集 ——
                    //   BBPhoneBangumiTimelineModel 是「一集一個 model」，
                    //   dayIndex 掛在「天」層級的話它拿不到（sim_live.py 抓到）。
                    [x setObject:(dow ?: @0) forKey:@"dayIndex"];
                    [x setObject:@"" forKey:@"badge"];
                    [x setObject:@0 forKey:@"season_status"];
                    [eps addObject:x];
                }
            }
            [d setObject:eps forKey:@"episodes"];
            [d setObject:eps forKey:@"listOfDay"];
            [days addObject:d];
        }
        if ([days count] == 0) return nil;
        return @{ @"code": @0, @"message": @"success",
                  @"result": days, @"data": days, @"latestUpdate": days };
    } @catch (NSException *e) {
        return nil;
    }
}

+ (NSDictionary *)brBangumiHomeFromTimeline:(NSDictionary *)j
                                      index:(NSDictionary *)idx {
    @try {
        NSDictionary *tl = [BRRouter brTimelineToOld:j];
        NSArray *days = nil;
        if (tl != nil) {
            days = [tl objectForKey:@"result"];
        }
        if (![days isKindOfClass:[NSArray class]]) days = @[];

        // finishedBangumis：從 pgc 索引取（帶 is_finish/cover/title/season_id）
        NSMutableArray *finished = [NSMutableArray array];
        @try {
            id dd = [idx objectForKey:@"data"];
            NSArray *list = nil;
            if ([dd isKindOfClass:[NSDictionary class]]) {
                id l = [dd objectForKey:@"list"];
                if ([l isKindOfClass:[NSArray class]]) list = l;
            }
            for (id one in list) {
                if (![one isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *x = [NSMutableDictionary dictionary];
                [x setObject:([one objectForKey:@"title"] ?: @"") forKey:@"title"];
                [x setObject:([one objectForKey:@"season_id"] ?: @0) forKey:@"season_id"];
                [x setObject:([one objectForKey:@"media_id"] ?: @0) forKey:@"media_id"];
                [x setObject:BRPicFix([one objectForKey:@"cover"] ?: @"") forKey:@"cover"];
                [x setObject:([one objectForKey:@"index_show"] ?: @"") forKey:@"index_show"];
                [x setObject:([one objectForKey:@"is_finish"] ?: @0) forKey:@"is_finish"];
                [x setObject:([one objectForKey:@"badge"] ?: @"") forKey:@"badge"];
                [x setObject:([one objectForKey:@"score"] ?: @"") forKey:@"score"];
                [x setObject:([one objectForKey:@"subTitle"] ?: @"") forKey:@"subTitle"];
                [x setObject:([one objectForKey:@"order"] ?: @"") forKey:@"order"];
                id fe = [one objectForKey:@"first_ep"];
                if ([fe isKindOfClass:[NSDictionary class]]) {
                    [x setObject:([fe objectForKey:@"ep_id"] ?: @0) forKey:@"ep_id"];
                    [x setObject:BRPicFix([fe objectForKey:@"cover"] ?: @"") forKey:@"ep_cover"];
                }
                [finished addObject:x];
            }
        } @catch (NSException *e) { }

        NSDictionary *inner = @{
            @"banners": @[],
            @"categories": @[],
            @"finishedBangumis": finished,
            @"finished_bangumis": finished,
            @"latestUpdate": days,
            @"latest_update": days,
            @"recommendCategory": @[],
            @"recommend_category": @[],
        };
        BRINFO(@"[改写] 番剧首页拼装：latestUpdate %lu 天 / finishedBangumis %lu 部",
               (unsigned long)[days count], (unsigned long)[finished count]);
        return @{ @"code": @0, @"message": @"ok",
                  @"data": inner, @"result": inner };
    } @catch (NSException *e) {
        BRERR(@"[改写] 番剧首页拼装失败: %@", [e description]);
        return nil;
    }
}

// [BRSTAT3_IMPL] 统一映射：一条视频 → App 分区卡片期望的 6 字段。
//   型别必须与 App 自带 home_init/config 完全一致
//   （play/danmaku/finish 是数字，其余是字符串），否则老客户端渲染会崩。
+ (NSDictionary *)brRegionElement:(NSDictionary *)it
                        playValue:(id)play
                     danmakuValue:(id)dm
                             seen:(NSMutableSet *)seen {
    @try {
        id aidRaw = [it objectForKey:@"aid"];
        if (aidRaw == nil) aidRaw = [it objectForKey:@"id"];
        long long aidLL = 0;
        if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
        else if ([aidRaw isKindOfClass:[NSString class]]) aidLL = [(NSString *)aidRaw longLongValue];
        if (aidLL <= 0) return nil;
        long long fake = [BRStore fakeAidForReal:aidLL];
        if (fake <= 0) return nil;
        NSString *key = [NSString stringWithFormat:@"%lld", fake];
        if (seen != nil) {
            if ([seen containsObject:key]) return nil;   // 跨数据源去重
            [seen addObject:key];
        }
        NSString *pic = BRPicFix([it objectForKey:@"pic"] ?: [it objectForKey:@"cover"] ?: @"");
        if ([pic length] > 0
            && [pic rangeOfString:@"_320x200"].location == NSNotFound
            && [pic rangeOfString:@"hdslb.com"].location != NSNotFound) {
            pic = [pic stringByAppendingString:@"_320x200.jpg"];
        }
        NSDictionary *st = [it objectForKey:@"stat"];
        if (![st isKindOfClass:[NSDictionary class]]) st = @{};
        id playV = play;
        if (playV == nil || ![playV respondsToSelector:@selector(integerValue)]) {
            playV = [st objectForKey:@"view"] ?: @0;
        }
        id dmV = dm;
        if (dmV == nil || ![dmV respondsToSelector:@selector(integerValue)]) {
            dmV = [st objectForKey:@"danmaku"] ?: @0;
        }
        // [BRFIXALL] ★ 分區卡片「點不進去」：
        //   真機日誌顯示 App 送出的 aid 是 2147483647（它自己的佔位符），
        //   表示它**沒有採用我們填的 param** → 很可能它讀的是 item 的 `aid`。
        //   所以 param / aid / avid 三個鍵都給（純新增，不影響既有行為）。
        // [BRGOTOACTION] ★ App 解析得出封面與播放量（所以模型有拿到 param），
        //   但點擊時送的卻是 aid=2147483647（它自己的佔位符）——
        //   證明它**不是**用 param/aid/avid 當點擊目標。
        //   BiliHomeBodyItem 裡唯一的動作欄位是 _gotoaction，
        //   所以補上 gotoaction（與 goto 一併給，純新增）。
        // [BROLDKEYS] ★★ 照舊版（實測推薦卡可進入詳情）補齊三個關鍵差異：
        //   ① aid / id / avid 用 **NSNumber**（不是字串）——
        //      老客戶端的 JSON→模型映射對這些欄位期待數字，字串可能因型別不符被忽略。
        //   ② 多給 **id** 這個鍵（舊版有給）。
        //   ③ **保留 bvid**（使用者提供的檔名就寫著「清空 bvid 後分區卡片失效」）。
        //   另外 cid 也一併帶上（舊版有）。
        NSNumber *fakeNum = @(fake);
        NSString *bv = [it objectForKey:@"bvid"];
        if (![bv isKindOfClass:[NSString class]]) bv = @"";
        NSNumber *cidNum = @0;
        id cidRaw = [it objectForKey:@"cid"];
        if (cidRaw && [cidRaw respondsToSelector:@selector(longLongValue)])
            cidNum = @([cidRaw longLongValue]);
        return @{
            @"title":      [it objectForKey:@"title"] ?: @"",
            @"cover":      pic,
            @"param":      key,          // 字串（config 樣本如此）
            @"aid":        fakeNum,      // ★ 數字
            @"id":         fakeNum,      // ★ 數字（舊版也有）
            @"avid":       fakeNum,      // ★ 數字
            @"bvid":       bv,           // ★ 保留
            @"cid":        cidNum,
            @"play":       playV,
            @"danmaku":    dmV,
            @"finish":     @0,
            @"goto":       @"av",
            @"gotoaction": @"av",
        };
    } @catch (NSException *e) {
        return nil;
    }
}


// =====================================================================
// [BRBANGUMICARD] 「番劇推薦」卡片的元素
//   形狀取自 App 自帶 home_init/config 的該卡（type=bangumi, param=13）：
//     { title, cover, param(season_id), finish, index, mtime, status }
//   注意：這裡的 param 是 **season_id**（config 樣本 '5538'），不是 aid。
//   上游 pgc/season/index/result 直接提供 6 個裡的 5 個；
//   mtime 介面沒有 → 留空字串。
//   /tmp/br-nobangumicard 可關閉（回到原本的 region 形狀）。
// =====================================================================

// =====================================================================
// [BRLIVECARD] 首頁「正在直播」卡的元素
//   config 的該卡：type=live, param=''（所以「param 是正整數」的判斷會跳過它）
//   → 它從來沒被填過，一直吃已死的老 feed 內容。
//   形狀（config 樣本）：
//     { title, cover, param(room_id 字串), name, face, online, area, area_id, finish }
//   上游 xlive getList 實測可用；轉換沿用 brLiveRoomFromDict:（已補上 param/name）。
//   /tmp/br-nolivecard 可關閉。
// =====================================================================

// =====================================================================
// [BRRECCARD] 首頁「热门焦点」卡的元素（type=recommend, param=''）
//   形狀取自 App 自帶 config 的該卡樣本：
//     { title, cover, param(影片 id 字串), goto, play, danmaku, finish }
//   上游沿用 feed 轉換器用的那條（需要 wbi 簽名），廣告過濾規則也一致。
//   ★ 只新增，不動 feed 路由本身。
//   /tmp/br-norecommendcard 可關閉。
// =====================================================================
static NSArray *BRRecommendCardItems(NSUInteger want) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-norecommendcard"]) {
            BRDBG(@"[改写] 热门焦点卡已被 /tmp/br-norecommendcard 关闭");
            return out;
        }
        // ★ ps 給多一點：廣告/非影片條目會被過濾掉，要留餘裕才湊得到 want 條
        NSString *base = [NSString stringWithFormat:
            @"https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd"
            @"?ps=%lu&fresh_type=3&platform=web&version=1",
            (unsigned long)(want + 6)];
        NSData *dt = BRRegionHttpGet([BRSession wbiSignURL:base]);
        if (dt == nil) return out;
        NSDictionary *j = [BRRouter jsonFromData:dt];
        NSDictionary *dd = [j objectForKey:@"data"];
        NSArray *src = nil;
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id it = [dd objectForKey:@"item"];
            if ([it isKindOfClass:[NSArray class]]) src = it;
        } else if ([dd isKindOfClass:[NSArray class]]) {
            src = dd;
        }
        if (![src isKindOfClass:[NSArray class]]) return out;

        for (id raw in (NSArray *)src) {
            if ([out count] >= want) break;
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *it = raw;
            // 與 feed 轉換器同一套廣告/非影片過濾
            NSString *g = [it objectForKey:@"goto"];
            if ([g isKindOfClass:[NSString class]] && [g length] > 0 &&
                ![g isEqualToString:@"av"] && ![g isEqualToString:@"video"]) continue;
            if ([it objectForKey:@"ad_info"] != nil) continue;
            id isAd = [it objectForKey:@"is_ad"];
            if (isAd != nil && [isAd respondsToSelector:@selector(boolValue)] &&
                [isAd boolValue]) continue;

            id aidRaw = [it objectForKey:@"id"];
            if (aidRaw == nil) aidRaw = [it objectForKey:@"aid"];
            long long aidLL = 0;
            if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
            else if ([aidRaw isKindOfClass:[NSString class]]) aidLL = [(NSString *)aidRaw longLongValue];
            long long fake = [BRStore fakeAidForReal:aidLL];
            if (fake <= 0) continue;

            NSDictionary *stat = [it objectForKey:@"stat"];
            if (![stat isKindOfClass:[NSDictionary class]]) stat = @{};
            NSString *pic = BRPicFix([it objectForKey:@"pic"] ?: [it objectForKey:@"cover"] ?: @"");
            [out addObject:@{
                @"title":   [it objectForKey:@"title"] ?: @"",
                @"cover":   pic,
                // [BRGOTOACTION] 同上：補 gotoaction，讓點擊有目標型別可判。
            @"gotoaction": @"av",
            @"param":   [NSString stringWithFormat:@"%lld", fake],
                @"goto":    ([g length] ? g : @"av"),
                @"play":    ([stat objectForKey:@"view"] ?: @0),
                @"danmaku": ([stat objectForKey:@"danmaku"] ?: @0),
                @"finish":  @0,
            }];
        }
        BRINFO(@"[改写] 热门焦点卡：组出 %lu 条", (unsigned long)[out count]);
    } @catch (NSException *e) {
        BRERR(@"[改写] 热门焦点卡异常: %@", [e description]);
    }
    return out;
}

static NSArray *BRLiveCardItems(NSUInteger want) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-nolivecard"]) {
            BRDBG(@"[改写] 直播推荐卡已被 /tmp/br-nolivecard 关闭");
            return out;
        }
        NSData *dt = BRRegionHttpGet(
            @"https://api.live.bilibili.com/xlive/web-interface/v1/index/getList?platform=web");
        if (dt == nil) return out;
        NSDictionary *j = [BRRouter jsonFromData:dt];
        NSDictionary *dd = [j objectForKey:@"data"];
        if (![dd isKindOfClass:[NSDictionary class]]) return out;

        NSMutableArray *raw = [NSMutableArray array];
        id rec = [dd objectForKey:@"recommend_room_list"];
        if ([rec isKindOfClass:[NSArray class]]) [raw addObjectsFromArray:rec];
        id rl = [dd objectForKey:@"room_list"];
        if ([rl isKindOfClass:[NSArray class]]) {
            for (id g in (NSArray *)rl) {
                if (![g isKindOfClass:[NSDictionary class]]) continue;
                id sub2 = [g objectForKey:@"list"];
                if ([sub2 isKindOfClass:[NSArray class]]) [raw addObjectsFromArray:sub2];
            }
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (id one in raw) {
            if ([out count] >= want) break;
            if (![one isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *room = [BRRouter brLiveRoomFromDict:one];
            if (room == nil) continue;
            NSString *k = [[room objectForKey:@"room_id"] description];
            if (k == nil || [seen containsObject:k]) continue;
            [seen addObject:k];
            // 只保留該卡需要的欄位（外加 finish）
            [out addObject:@{
                @"title":   [room objectForKey:@"title"] ?: @"",
                @"cover":   [room objectForKey:@"cover"] ?: @"",
                @"param":   [room objectForKey:@"param"] ?: @"",
                @"name":    [room objectForKey:@"name"] ?: @"",
                @"face":    [room objectForKey:@"face"] ?: @"",
                @"online":  [room objectForKey:@"online"] ?: @0,
                @"area":    [room objectForKey:@"area"] ?: @"",
                @"area_id": [room objectForKey:@"area_id"] ?: @0,
                @"finish":  @0,
            }];
        }
        BRINFO(@"[改写] 直播推荐卡：组出 %lu 间", (unsigned long)[out count]);
    } @catch (NSException *e) {
        BRERR(@"[改写] 直播推荐卡异常: %@", [e description]);
    }
    return out;
}

static NSArray *BRBangumiCardItems(NSUInteger want) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-nobangumicard"]) {
            BRDBG(@"[改写] 番剧推荐卡已被 /tmp/br-nobangumicard 关闭");
            return out;
        }
        NSString *u = [NSString stringWithFormat:
            @"https://api.bilibili.com/pgc/season/index/result"
            @"?st=1&order=3&season_type=1&page=1&pagesize=%lu&type=1",
            (unsigned long)want];
        NSData *dt = BRRegionHttpGet(u);
        if (dt == nil) return out;
        NSDictionary *j = [BRRouter jsonFromData:dt];
        id dd = [j objectForKey:@"data"];
        id list = [dd isKindOfClass:[NSDictionary class]] ? [dd objectForKey:@"list"] : nil;
        if (![list isKindOfClass:[NSArray class]]) return out;
        for (id one in (NSArray *)list) {
            if ([out count] >= want) break;
            if (![one isKindOfClass:[NSDictionary class]]) continue;
            id sid = [one objectForKey:@"season_id"];
            if (sid == nil || [sid longLongValue] <= 0) continue;
            NSString *cover = [one objectForKey:@"cover"] ?: @"";
            if ([cover hasPrefix:@"//"]) cover = [@"http:" stringByAppendingString:cover];
            [out addObject:@{
                @"title":  [one objectForKey:@"title"] ?: @"",
                @"cover":  cover,
                // ★ param = season_id（字串）—— config 樣本 '5538' 就是這個
                @"param":  [NSString stringWithFormat:@"%@", sid],
                @"finish": ([one objectForKey:@"is_finish"] ?: @0),
                @"index":  ([one objectForKey:@"index_show"] ?: @""),
                @"mtime":  @"",
                @"status": ([one objectForKey:@"season_status"] ?: @0),
            }];
        }
        BRINFO(@"[改写] 番剧推荐卡：组出 %lu 个番剧", (unsigned long)[out count]);
    } @catch (NSException *e) {
        BRERR(@"[改写] 番剧推荐卡异常: %@", [e description]);
    }
    return out;
}

+ (NSArray *)fetchRegionVideos:(NSString *)rid count:(NSUInteger)want {

// ★ 分区结果缓存：同一个分区 120 秒内不重复取数。
//   否则每次首页刷新都要重做几个同步请求，把首页卡死。
    // 注意：gBRRegionCache 已提升到檔案級（供並行預取共用），這裡不再宣告
    NSMutableArray *out = [NSMutableArray array];
    @try {
        // ★ 先查缓存
        @try {
            if (gBRRegionCache == nil) gBRRegionCache = [[NSMutableDictionary alloc] init];
            NSDictionary *c = [gBRRegionCache objectForKey:rid];
            if (c != nil) {
                NSTimeInterval age = [[NSDate date] timeIntervalSince1970] -
                                     [[c objectForKey:@"t"] doubleValue];
                // [BRTTL20] ★ 原本是 120 秒 —— 使用者按「刷新」時每個分區都命中快取，
                //   內容一模一樣 → 看起來就是「刷新鍵沒反應」。
                //   並行預取已把單次抓取降到約 6 秒，20 秒足夠避免重複抓取。
                if (age < 20.0) {
                    NSArray *v = [c objectForKey:@"v"];
                    if ([v isKindOfClass:[NSArray class]] && [v count] > 0) {
                        BRDBG(@"[改写] 分区 %@ 命中缓存 %lu 条", rid, (unsigned long)[v count]);
                        return v;
                    }
                }
            }
        } @catch (NSException *e) { }

        // ★★★ [BRSTAT3] 三级数据源 —— 目标：分区卡片显示真实播放量/弹幕。
        //   背景（2026-10-16 实测）：newlist 的 stat 现在**全是 0**，
        //     B 站已不再返回真实数字 —— 这正是卡片显示「播放量 -、弹幕 0」的原因。
        //   实测：ranking/region 在 16/16 个分区都成功且带真实 play/video_review；
        //         ranking/v2 有 11/16 回 -352 风控，**不能用**。
        //   ① ranking/region  主数据源
        //   ② newlist         条目不足时补齐（stat 会是 0）
        //   ③ popular         分区已废弃时兜底（如「广告区」rid=165 全接口 0 条）
        NSMutableSet *seen = [NSMutableSet set];
        BOOL rankOk = NO;      // [BRPERF] rank 源是否真的拿到資料

        // ---------- ① ranking/region ----------
        @try {
            NSString *u1 = [NSString stringWithFormat:
                @"https://api.bilibili.com/x/web-interface/ranking/region?rid=%@&day=3", rid];
            NSData *d1 = BRRegionHttpGet(u1);
            NSDictionary *j1 = d1 ? [BRRouter jsonFromData:d1] : nil;
            id l1 = [j1 objectForKey:@"data"];
            if ([l1 isKindOfClass:[NSArray class]] && [(NSArray *)l1 count] > 0) rankOk = YES;
            if ([l1 isKindOfClass:[NSArray class]]) {
                for (id one in l1) {
                    if ([out count] >= want) break;
                    if (![one isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *e = [BRRouter brRegionElement:one
                                                      playValue:[one objectForKey:@"play"]
                                                   danmakuValue:[one objectForKey:@"video_review"]
                                                           seen:seen];
                    if (e != nil) [out addObject:e];
                }
            }
            BRDBG(@"[改写] 分区 %@ ①rank 源得到 %lu 条", rid, (unsigned long)[out count]);
        } @catch (NSException *e) {
            BRERR(@"[改写] 分区 %@ rank 源异常: %@", rid, [e description]);
        }

        // ---------- ② newlist 补足 ----------
        //   [BRPERF] 只在 rank 源「成功但條數不足」時才補。
        //   若 rank 直接失敗（分區已廢棄，例如 rid=165 回 -400），
        //   newlist 幾乎必然也是空的 → 直接跳去 popular，省一次往返。
        if (rankOk && [out count] < want) {
            @try {
                NSString *u2 = [NSString stringWithFormat:
                    @"https://api.bilibili.com/x/web-interface/newlist"
                    @"?rid=%@&pn=1&ps=%lu&order=0&build=4070&mobi_app=iphone"
                    @"&platform=ios&device=phone&appkey=27eb53fc9058f8c3&ts=%lld",
                    rid, (unsigned long)want,
                    (long long)[[NSDate date] timeIntervalSince1970]];
                NSData *d2 = BRRegionHttpGet(u2);
                NSDictionary *j2 = d2 ? [BRRouter jsonFromData:d2] : nil;
                id dd = [j2 objectForKey:@"data"];
                NSArray *ar = nil;
                if ([dd isKindOfClass:[NSDictionary class]]) {
                    id a1 = [dd objectForKey:@"archives"];
                    if ([a1 isKindOfClass:[NSArray class]]) ar = a1;
                }
                for (id one in ar) {
                    if ([out count] >= want) break;
                    if (![one isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *e = [BRRouter brRegionElement:one
                                                      playValue:[one objectForKey:@"play"]
                                                   danmakuValue:[one objectForKey:@"video_review"]
                                                           seen:seen];
                    if (e != nil) [out addObject:e];
                }
                BRDBG(@"[改写] 分区 %@ ②补 newlist 后共 %lu 条", rid, (unsigned long)[out count]);
            } @catch (NSException *e) {
                BRERR(@"[改写] 分区 %@ newlist 异常: %@", rid, [e description]);
            }
        }

        // ---------- ③ popular 兜底 / 補足 ----------
        //   [BRPERF] 结果在分区之间共享缓存 120 秒：
        //   多个失效分区不会各发一次 popular。
        // [BRPOPULAR_TOPUP] ★ 原本是 `if ([out count] == 0)` —— 只有「完全 0 條」才兜底。
        //   但 PGC 類分區（紀錄片 177 / 電影 23 / 電視劇 11）的 ranking/region
        //   只回 1~2 條 → out.count = 1 或 2 → **兜底不執行** →
        //   卡片只有 1~2 個項目，而且 App 似乎會因此把「刷新鍵」藏起來
        //   （使用者回報：「内容不滿 4 個并且刷新鍵沒了」）。
        //   改成「不足 want 就補」，讓卡片一定填滿。
        if ([out count] < want) {
            @try {
                NSArray *pop = nil;
                @try {
                    NSDictionary *pc = [gBRRegionCache objectForKey:@"__popular__"];
                    if (pc != nil) {
                        NSTimeInterval page = [[NSDate date] timeIntervalSince1970] -
                                              [[pc objectForKey:@"t"] doubleValue];
                        if (page < 20.0) {   // [BRTTL20] 同上
                            id pv = [pc objectForKey:@"v"];
                            if ([pv isKindOfClass:[NSArray class]] && [pv count] > 0) {
                                pop = pv;
                                BRDBG(@"[改写] 分区 %@ popular 命中缓存 %lu 条",
                                      rid, (unsigned long)[pop count]);
                            }
                        }
                    }
                } @catch (NSException *e) { }

                if (pop == nil) {
                    NSString *u3 = @"https://api.bilibili.com/x/web-interface/popular?pn=1&ps=8";
                    NSData *d3 = BRRegionHttpGet(u3);
                    NSDictionary *j3 = d3 ? [BRRouter jsonFromData:d3] : nil;
                    id dd3 = [j3 objectForKey:@"data"];
                    NSArray *l3 = nil;
                    if ([dd3 isKindOfClass:[NSDictionary class]]) {
                        id a3 = [dd3 objectForKey:@"list"];
                        if ([a3 isKindOfClass:[NSArray class]]) l3 = a3;
                    }
                    NSMutableArray *mp = [NSMutableArray array];
                    for (id one in l3) {
                        if (![one isKindOfClass:[NSDictionary class]]) continue;
                        // 这里用一个临时 seen，避免把缓存内容提前消耗掉
                        NSDictionary *e = [BRRouter brRegionElement:one
                                                          playValue:nil
                                                       danmakuValue:nil
                                                               seen:nil];
                        if (e != nil) [mp addObject:e];
                    }
                    pop = mp;
                    if ([pop count] > 0) {
                        [gBRRegionCache setObject:@{@"t": @([[NSDate date] timeIntervalSince1970]),
                                                    @"v": pop} forKey:@"__popular__"];
                    }
                }

                for (NSDictionary *e in pop) {
                    if ([out count] >= want) break;
                    if (![e isKindOfClass:[NSDictionary class]]) continue;
                    id pk = [e objectForKey:@"param"];
                    if (pk != nil) {
                        if ([seen containsObject:pk]) continue;   // 跨源去重
                        [seen addObject:pk];
                    }
                    [out addObject:e];
                }
                BRINFO(@"[改写] 分区 %@ ③popular 兜底得到 %lu 条", rid,
                       (unsigned long)[out count]);
            } @catch (NSException *e) {
                BRERR(@"[改写] 分区 %@ popular 兜底异常: %@", rid, [e description]);
            }
        }
        BRINFO(@"[改写] 分区 %@ 最终 %lu 条（want=%lu）", rid,
               (unsigned long)[out count], (unsigned long)want);

        // ★ 写缓存
        @try {
            if ([out count] > 0) {
                if (gBRRegionCache == nil) gBRRegionCache = [[NSMutableDictionary alloc] init];
                [gBRRegionCache setObject:@{@"t": @([[NSDate date] timeIntervalSince1970]),
                                            @"v": out} forKey:rid];
            }
        } @catch (NSException *e) { }    } @catch (NSException *e) {
        BRERR(@"[改写] 取分区 %@ 失败: %@", rid, [e description]);
    }
    return out;
}

// 把真实 cid 换成假 cid（防 int32 溢出），并记住 cid->aid 反查
+ (NSNumber *)fakeCid:(id)cid forAid:(id)aid {
    long long c = 0, a = 0;
    if ([cid respondsToSelector:@selector(longLongValue)]) c = [cid longLongValue];
    if ([aid respondsToSelector:@selector(longLongValue)]) a = [aid longLongValue];
    if (c <= 0) return @0;
    long long fc = [BRStore fakeCidForReal:c];
    if (fc > 0 && a > 0) [BRStore rememberCid:fc forAid:[BRStore fakeAidForReal:a]];
    return @(fc > 0 ? fc : c);
}

#pragma mark - 路由表

+ (BRRoute *)routeForRequest:(NSURLRequest *)req {
    NSURL *u = [req URL];
    NSString *host = [[u host] lowercaseString];
    NSString *path = [u path] ?: @"";
    NSString *rawQuery = [u query] ?: @"";
    NSMutableDictionary *qs = BRParseQuery(rawQuery);

    BRRoute *r = [[BRRoute alloc] init];

    // ================= 弹幕 XML =================
    if ([host hasPrefix:@"comment.bilibili."] && [path hasSuffix:@".xml"]) {
        NSString *cid = [[path lastPathComponent] stringByDeletingPathExtension];
        long long real = [BRStore realCidForFake:[cid longLongValue]];
        if (real > 0 && real != [cid longLongValue]) {
            BRINFO(@"弹幕 cid 还原: %@ -> %lld", cid, real);
            cid = [NSString stringWithFormat:@"%lld", real];
        }
        r.url = [NSString stringWithFormat:
                 @"https://api.bilibili.com/x/v1/dm/list.so?oid=%@", cid];
        r.kind = @"danmaku";
        r.extra = @{@"cid": cid};
        r.note = @"弹幕";
        return r;
    }

    // ================= 一级 / 二级分区 =================
    if ([path hasPrefix:@"/x/v2/region"] || [path hasPrefix:@"/x/v2/partition"] ||
        [path hasPrefix:@"/x/v2/tag/archives"]) {
        return [self routeRegion:path qs:qs];
    }

    // ================= 首页 / 推荐流 =================
    // ★★★ 首页改为「走它自己的原接口」（用户建议：
    //   「套用原版的排版和框架，然後用新 API 加個 AV 和 BV 的轉換」）。
    //   原因：自己拼卡片（wbi feed 是视频列表，需重组成卡片数组）很难与
    //   App 的排版框架完全对齐，实测渲染那一步就崩。
    //   而 /x/v2/region 已实测「原样透传」能拿到正确的老格式，
    //   所以首页也先试原接口，让 App 用它自己的排版。
    //   想回到新 feed 对比时：touch /tmp/br-newhome
    // [BROLDHOME] 首页走原接口，但我们要把分区卡片的空 body 填上。
    if ([path isEqualToString:@"/x/v2/show"] &&
        ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-newhome"]) {
        BRRoute *oh = [[BRRoute alloc] init];
        oh.kind = @"oldhome";
        oh.note = @"首页(原接口+填充分区)";
        oh.url = nil;                 // 不改写上游
        BRINFO(@"[改写] /x/v2/show → oldhome（原版排版 + 填充分区卡片）");
        return oh;
    }
    if ([path isEqualToString:@"/x/v2/feed/index"] ||
        [path isEqualToString:@"/x/web-interface/index/top/rcmd"] ||
        [path isEqualToString:@"/x/v2/show"] ||
        [path isEqualToString:@"/x/v2/feed/index/upper"]) {
        NSString *ps = qs[@"ps"] ?: qs[@"pagesize"] ?: @"6";
        NSString *fresh = qs[@"fresh_type"] ?: @"3";
        // ★ 必须带 wbi 签名：未签名的 wbi 接口会被风控判 v_voucher（412）
        NSString *base = [NSString stringWithFormat:
            @"https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd"
            @"?ps=%@&fresh_type=%@&fresh_idx=1&feed_version=V8&homepage_ver=1"
            @"&brush=0&screen=1&platform=0", ps, fresh];
        r.url = [BRSession wbiSignURL:base];
        r.kind = @"feed";
        r.note = @"推荐流";
        return r;
    }

    // ================= 视频详情 =================
    if ([path isEqualToString:@"/x/web-interface/view"] ||
        [path isEqualToString:@"/x/web-interface/view/detail"] ||
        [path isEqualToString:@"/x/v2/view"] ||
        [path isEqualToString:@"/view"] ||
        [path isEqualToString:@"/x/web-interface/archive/stat"]) {
        NSString *aid = qs[@"aid"] ?: qs[@"avid"];
        NSString *bvid = qs[@"bvid"];
        // [BRVIEWDIAG] 診斷「分區卡片點不進去」。
        //   真機日誌顯示改寫後的 URL 是 aid=2147483647（= App 自己的佔位符），
        //   但我餵給卡片的 param 是約 10 億的假 aid，照理不該變成佔位符 ——
        //   所以要看清楚 App 究竟送了什麼進來。
        BRINFO(@"[改写] view 请求：进来 aid=%@ bvid=%@ 原始query=%@",
               aid ?: @"(nil)", bvid ?: @"(nil)", rawQuery ?: @"");
        // ★ 32 位溢出：客户端带来的是我们下发的假 aid，先还原
        if ([aid length]) {
            long long real = [BRStore realAidForFake:[aid longLongValue]];
            if (real == 0 && [BRStore looksLikeFakeAid:[aid longLongValue]]) {
                r.drop = YES;
                r.note = @"aid 映射丢失（不能当真 ID 去请求）";
                return r;
            }
            if (real > 0) {
                BRDBG(@"aid 还原: %@ -> %lld", aid, real);
                aid = [NSString stringWithFormat:@"%lld", real];
            }
        }
        if ([bvid length]) {
            r.url = [NSString stringWithFormat:
                     @"https://api.bilibili.com/x/web-interface/view?bvid=%@", bvid];
        } else if ([aid length]) {
            r.url = [NSString stringWithFormat:
                     @"https://api.bilibili.com/x/web-interface/view?aid=%@", aid];
        } else {
            r.url = [NSString stringWithFormat:
                     @"https://api.bilibili.com%@?%@", path, rawQuery];
        }
        r.kind = @"view";
        r.note = @"视频详情";
        return r;
    }

    // ================= 播放地址 =================
    if ([path hasSuffix:@"/playurl"] || [path isEqualToString:@"/playurl"]) {
        // 老客户端打的是 /x/player/playurl（无签名）→ 改用 wbi 版
        NSString *avid = qs[@"avid"] ?: qs[@"aid"];
        NSString *cid  = qs[@"cid"];
        NSString *qn   = qs[@"qn"] ?: @"16";
        if ([avid length]) {
            long long real = [BRStore realAidForFake:[avid longLongValue]];
            if (real > 0) avid = [NSString stringWithFormat:@"%lld", real];
        }
        if ([cid length]) {
            long long rc = [BRStore realCidForFake:[cid longLongValue]];
            if (rc > 0) cid = [NSString stringWithFormat:@"%lld", rc];
            // 只给了 cid 时，用 cid->aid 反查补上
            if (![avid length]) {
                long long a = [BRStore aidForCid:[cid longLongValue]];
                if (a > 0) avid = [NSString stringWithFormat:@"%lld", a];
            }
        }
        if (![avid length] || ![cid length]) {
            r.drop = YES; r.note = @"playurl 缺少 aid/cid";
            return r;
        }
        NSString *base = [NSString stringWithFormat:
            @"https://api.bilibili.com/x/player/wbi/playurl?avid=%@&cid=%@&qn=%@"
            @"&fnval=0&fourk=0&fnver=0&otype=json&platform=html5&high_quality=1",
            avid, cid, qn];
        r.url = [BRSession wbiSignURL:base];
        r.kind = @"playurl";
        r.extra = @{@"aid": avid, @"cid": cid};
        r.note = @"播放地址";
        return r;
    }

    // ================= 评论 =================
    if ([path hasPrefix:@"/x/v2/reply/main"] || [path hasPrefix:@"/x/v2/reply/wbi/main"] ||
        [path isEqualToString:@"/x/v2/reply"]) {
        NSString *oid = qs[@"oid"] ?: qs[@"aid"];
        if ([oid length]) {
            long long real = [BRStore realAidForFake:[oid longLongValue]];
            if (real > 0) oid = [NSString stringWithFormat:@"%lld", real];
        }
        NSString *type = qs[@"type"] ?: @"1";
        NSString *pn = qs[@"pn"] ?: @"1";
        NSString *ps = qs[@"ps"] ?: @"20";
        // ★ 用「经典」评论接口而不是 wbi/main：
        //   wbi/main 在匿名请求下返回 -403 访问权限不足，
        //   而经典版返回的正是老客户端期望的旧结构，连转换都可以省掉。
        NSString *base = [NSString stringWithFormat:
            @"https://api.bilibili.com/x/v2/reply?oid=%@&type=%@&pn=%@&ps=%@&sort=2&nohot=0",
            oid ?: @"", type, pn, ps];
        r.url = base;
        r.kind = @"reply";
        // ★ 必须完全匿名：带任何会话信息都只给 3 条评论
        //   （被判成「有会话的游客」；注意 buvid3 也算会话信息）
        r.anonymous = YES;
        r.note = @"评论（匿名）";
        return r;
    }

    // ================= 搜索 =================
    if ([path hasPrefix:@"/x/v2/search"] || [path hasPrefix:@"/x/web-interface/search"] ||
        [path isEqualToString:@"/search"] || [path hasPrefix:@"/x/v2/suggest"]) {
        NSString *kw = qs[@"keyword"] ?: qs[@"kw"] ?: qs[@"term"] ?: @"";
        NSString *page = qs[@"page"] ?: qs[@"pn"] ?: @"1";
        NSString *type = qs[@"search_type"] ?: qs[@"type"] ?: @"video";
        if ([type isEqualToString:@"all"]) type = @"video";
        if ([type isEqualToString:@"bangumi"]) type = @"media_bangumi";
        // ★ 用「非 wbi」的搜索接口：wbi 版在 iOS7 老客户端的 UA 下会被风控
        //   挑战（返回 v_voucher），而非 wbi 版策略宽松得多。
        NSMutableString *base = [NSMutableString stringWithFormat:
            @"https://api.bilibili.com/x/web-interface/search/type"
            @"?search_type=%@&page=%@&keyword=%@", type, page, kw];
        // 综合搜索要给不少额外参数，否则返回结构不完整
        if ([type isEqualToString:@"video"]) {
            [base appendString:@"&order=totalrank&duration=0&tids=0&highlight=1"];
        }
        // 补上风控指纹参数（缺这几个会拿到 v_voucher 而不是结果）
        [base appendString:@"&dm_img_list=%5B%5D"
                           @"&dm_img_str=V2ViR0wgMS4wIChPcGVuR0wgRVMgMi4wIENocm9taXVtKQ"
                           @"&dm_img_inter=%7B%22ds%22%3A%5B%5D%2C%22wh%22%3A%5B0%2C0%2C0%5D%2C%22of%22%3A%5B0%2C0%2C0%5D%7D"];
        r.url = base;
        // [BRSEARCH_RAW] ★★ 搜尋**不做轉換**，原樣透傳。
        //   使用者明確指出：「修之前這三個能搜到，你修了之後輸出和客戶端不兼容，
        //   導致什麼內容也沒。」
        //   真機診斷也證實：上游回應是 data.items（App API 原生格式），
        //   而我的轉換器只認 data.result，還把它重組成 {list, data:[]} →
        //   把 App 本來看得懂的資料改壞了。
        //   所以這裡改回 raw：請求照樣導到可用的新介面，但**回應不動**。
        r.kind = @"raw";
        // ★ 搜索接口必须用浏览器 UA（其它接口要用 App UA —— 要求正好相反）
        r.ua = [BRSession searchUA];
        r.note = @"搜索（原样透传）";
        return r;
    }

    // ================= 排行榜 =================
    if ([path hasPrefix:@"/index/rank/"] || [path isEqualToString:@"/x/v2/rank"] ||
        [path hasPrefix:@"/x/v2/rank"] || [path hasPrefix:@"/x/web-interface/ranking"]) {
        NSString *rid = qs[@"rid"] ?: @"0";
        if ([rid isEqualToString:@"all"]) rid = @"0";
        r.url = [NSString stringWithFormat:
                 // [BRRANKLEGACY] 2026-10-16 實測：ranking/v2 對老 UA（裝置用的）
                 //   回 -352 风控校验失败，只有現代 UA 才過；而老介面
                 //   x/web-interface/ranking?rid=&day=3 用老 UA 就能拿到 100 筆，
                 //   且元素是扁平經典欄位（play / video_review / author / mid），
                 //   正是這個 2014 年 App 期望的形狀。
                 @"https://api.bilibili.com/x/web-interface/ranking?rid=%@&day=3", rid];
        r.kind = @"list";
        r.extra = @{@"listKey": @"list"};
        r.note = @"排行榜";
        return r;
    }

    // ================= 直播 =================
    // [BRREACHABLE_LIVE] ★ 通用直播分支必須**排除「直播列表」那幾個路徑**，
    //   否則它會先把請求攔走（kind=raw），下面專門做 livelistx 轉換的分支
    //   就永遠到不了 —— 這正是「全部直播」顯示
    //   `[self.response arrayValue] return nil` 的原因（App 要陣列卻拿到未轉換的 dict）。
    //   這是本專案第三次遇到「到不了的分支」（前兩次：熱門焦點卡、正在直播卡）。
    {
        BOOL isLiveListPath =
            [path isEqualToString:@"/mobile/rooms"] ||
            [path isEqualToString:@"/room/v1/room/getList"] ||
            [path isEqualToString:@"/index/getRoomList"] ||
            [path isEqualToString:@"/index/getList"] ||
            [path isEqualToString:@"/x/v2/index/getList"] ||
            [path hasPrefix:@"/AppNewIndex"];
        if (!isLiveListPath &&
            ([host hasPrefix:@"api.live.bilibili."] || [path hasPrefix:@"/xlive"])) {
            // 直播是 APP 签名体系，不要套 wbi
            r.url = [NSString stringWithFormat:@"https://%@%@?%@", host, path, rawQuery];
            r.kind = @"raw";
            r.note = @"直播";
            return r;
        }
    }

    // ================= nav（登录态注入）=================
    if ([path isEqualToString:@"/x/web-interface/nav"] ||
        [path isEqualToString:@"/x/web-interface/nav/stat"]) {
        r.url = [NSString stringWithFormat:@"https://api.bilibili.com%@", path];
        r.kind = @"nav";
        r.note = @"nav";
        return r;
    }

    // ================= 番剧 =================
    if ([path hasPrefix:@"/pgc/"] || [path hasPrefix:@"/x/v2/bangumi"] ||
        [path isEqualToString:@"/bangumi"]) {
        r.url = [NSString stringWithFormat:@"https://api.bilibili.com%@?%@", path, rawQuery];
        r.kind = @"raw";
        r.note = @"番剧";
        return r;
    }

                // ================= [BR_UWP_REGION] 真二级分区（UWP 后门通道）=================
    // ★ 用户要求：不要再用「拿分区名去搜索」的伪装方案，改用 UWP 专用通道。
    //   实测 newlist 已泛化（rid=3 只返回无关推荐），而本接口返回的确实是该分区内容。
    if ([path hasPrefix:@"/x/v2/region"] || [path hasPrefix:@"/x/v2/partition"]) {
        NSString *rid = qs[@"rid"] ?: qs[@"tag_id"] ?: qs[@"tid"] ?: @"1";
        NSString *pn  = qs[@"pn"] ?: qs[@"page"] ?: @"1";
        BOOL isBangumiRid = ([rid isEqualToString:@"32"] || [rid isEqualToString:@"33"] ||
                             [rid isEqualToString:@"153"] || [rid isEqualToString:@"13"]);

        // 番剧/国创类分区内容在 PGC 系统里，newlist 恒返回 0 条
        if (isBangumiRid) {
            NSString *ps = qs[@"ps"] ?: qs[@"pagesize"] ?: @"20";
            r.url = [NSString stringWithFormat:
                     @"https://api.bilibili.com/pgc/season/index/result?st=1&order=3"
                     @"&season_type=1&page=%@&pagesize=%@&type=1", pn, ps];
            r.kind = @"region";
            r.note = @"番剧类分区（PGC 索引）";
            return r;
        }

        // ★ 开关回退：转换器被禁用时，UWP 通道的 data.new[] 没法转换，
        //   分区会彻底空白；改走 newlist（响应原生就是 archives[]）。
        if (BRConvOff(@"region")) {  // [BR_NOCONV_FALLBACK]
            NSString *ps = qs[@"ps"] ?: qs[@"pagesize"] ?: @"20";
            r.url = [NSString stringWithFormat:
                     @"https://api.bilibili.com/x/web-interface/newlist?rid=%@&pn=%@&ps=%@",
                     rid, pn, ps];
            r.kind = @"raw";
            r.note = @"分区（开关回退 newlist）";
            return r;
        }

        // ★ 真二级分区：UWP 通道
        long long ts = (long long)[[NSDate date] timeIntervalSince1970];
        r.url = [NSString stringWithFormat:
                 @"https://app.bilibili.com/x/v2/region/dynamic/child"
                 @"?build=3500&channel=bilih5&mobi_app=win&platform=2"
                 @"&rid=%@&tag_id=0&ts=%lld", rid, ts];
        r.kind = @"region";
        r.extra = @{@"uwp": @YES, @"pn": pn, @"rid": rid};
        r.note = @"二级分区（UWP 真通道）";
        return r;
    }

    // ================= [BR_ADDED_TAG_ROUTES] 标签 / 相关推荐 / 热搜 =================

    // ---- 视频相关推荐（★ 老 x/v2/related 已失效 → 「有的視頻不見了」）----
    if ([path isEqualToString:@"/x/v2/related"] ||
        [path isEqualToString:@"/x/v2/archive/related"] ||
        [path isEqualToString:@"/x/web-interface/archive/related"] ||
        [path isEqualToString:@"/x/v2/view/related"]) {
        NSString *aid = qs[@"aid"] ?: qs[@"avid"] ?: @"";
        long long real = [BRStore realAidForFake:[aid longLongValue]];
        if (real > 0) aid = [NSString stringWithFormat:@"%lld", real];
        r.url = [NSString stringWithFormat:
                 @"https://api.bilibili.com/x/web-interface/archive/related?aid=%@", aid];
        r.kind = @"raw";
        r.note = @"相关推荐";
        return r;
    }

    // ---- 热门标签 / 热搜（★ 参考实现实测：老 x/tag/hots 的 412 高达 60 次，
    //      是日志里失败最多的接口，必须改走热搜榜）----
    if ([path isEqualToString:@"/x/tag/hots"] ||
        [path isEqualToString:@"/x/v2/tag/hots"] ||
        [path isEqualToString:@"/x/tag/hot"] ||
        [path isEqualToString:@"/x/v2/search/hot"] ||
        [path isEqualToString:@"/x/web-interface/search/square"]) {
        r.url = [BRSession wbiSignURL:
                 @"https://api.bilibili.com/x/web-interface/search/square?limit=10"];
        r.kind = @"raw";
        r.note = @"热门标签/热搜";
        return r;
    }

    // ---- 视频标签（老 x/v2/tag 已失效）----
    if ([path isEqualToString:@"/x/v2/tag"] ||
        [path isEqualToString:@"/x/tag/archive/tags"]) {
        NSString *aid = qs[@"aid"] ?: qs[@"avid"] ?: @"";
        long long real = [BRStore realAidForFake:[aid longLongValue]];
        if (real > 0) aid = [NSString stringWithFormat:@"%lld", real];
        r.url = [NSString stringWithFormat:
                 @"https://api.bilibili.com/x/tag/archive/tags?aid=%@", aid];
        r.kind = @"raw";
        r.note = @"视频标签";
        return r;
    }

    // ---- 分出/专题：用标签名去搜索（伪二级分区）----
    // ★ 参考实现警告：wbiSignURL 内部会再编码一次，必须传原始关键词，
    //   否则 % 会被编成 %25（双重编码）→ 服务端收到乱码 → 返回无关结果
    if ([path isEqualToString:@"/x/v2/region/show"] ||
        [path isEqualToString:@"/x/v2/region/tag"] ||
        [path isEqualToString:@"/x/v2/region/show/tag"] ||
        [path isEqualToString:@"/x/v2/tag/archives"] ||
        [path isEqualToString:@"/x/tag/archives"]) {
        NSString *tag = qs[@"tag_name"] ?: qs[@"tag"] ?: qs[@"keyword"];
        if ([tag length]) {
            NSString *pn = qs[@"pn"] ?: @"1";
            NSString *b = [NSString stringWithFormat:
                           @"https://api.bilibili.com/x/web-interface/wbi/search/type"
                           @"?search_type=video&keyword=%@&page=%@", tag, pn];
            r.url = [BRSession wbiSignURL:b];
            r.kind = @"region";
            r.note = @"专题/标签（伪分区）";
            return r;
        }
    }

    // ================= [BR_ADDED_ROUTES] 按 5.9 参考实现补齐的路由 =================

    // ---- 直播：老接口已失效，统一映射到实测可用的新接口 ----
    // ★ live 域名是 APP 签名体系，不能套 wbi（会 412）
    if ([host hasPrefix:@"live."] || [host hasPrefix:@"api.live."]) {
        if ([path hasPrefix:@"/AppNewIndex"] || [path hasSuffix:@"/common"] ||
            [path isEqualToString:@"/"] ||
            [path isEqualToString:@"/index/getList"] ||
            [path isEqualToString:@"/x/v2/index/getList"] ||
            [path isEqualToString:@"/mobile/rooms"] ||
            [path isEqualToString:@"/room/v1/room/getList"] ||
            [path isEqualToString:@"/index/getRoomList"]) {
            NSMutableArray *keep = [NSMutableArray array];
            for (NSString *k in @[@"platform", @"mobi_app", @"device", @"build", @"scale",
                                  @"actionKey", @"appkey", @"ts", @"sign", @"type",
                                  @"parent_area_id", @"area_id"]) {
                NSString *v = qs[k];
                if ([v length]) [keep addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
            }
            if (![keep count])
                [keep addObjectsFromArray:@[@"platform=web", @"mobi_app=iphone", @"device=phone"]];
            r.url = [NSString stringWithFormat:
                     @"https://api.live.bilibili.com/xlive/web-interface/v1/index/getList?%@",
                     [keep componentsJoinedByString:@"&"]];
            r.kind = @"livelistx";   // [BRLIVEX] 需要重包成 BiliLiveList
            r.note = @"直播列表（新接口，已转换）";
            return r;
        }
        if ([path isEqualToString:@"/api/playurl"]) {
            NSString *room = qs[@"cid"] ?: qs[@"room_id"] ?: @"";
            r.url = [NSString stringWithFormat:
                     @"https://api.live.bilibili.com/room/v1/Room/playUrl?cid=%@&quality=4&platform=web",
                     room];
            r.kind = @"raw";
            r.note = @"直播播放地址";
            return r;
        }
    }

    // ---- [BRLIVEX] 番劇首頁：老介面已關閉（404）----
    //   App 二進位裡有 BBPhoneBangumiHomeModel { banners, categories,
    //   finishedBangumis, latestUpdate, recommendCategory }，
    //   用 timeline + pgc 索引拼出這個結構（不再讓它 404）。
    if ([path rangeOfString:@"app_index_page"].location != NSNotFound ||
        [path hasPrefix:@"/api/app_index_page"]) {
        r.url = @"https://api.bilibili.com/pgc/web/timeline?types=1&before=6&after=6";
        r.kind = @"bangumihome";
        r.note = @"番剧首页（拼装）";
        return r;
    }

    // ---- 番剧时间表 ----
    if ([path hasPrefix:@"/pgc/web/timeline"] || [path hasPrefix:@"/x/v2/bangumi/timeline"]) {
        r.url = @"https://api.bilibili.com/pgc/web/timeline?types=1&before=6&after=6";
        r.kind = @"bangumitlx";   // [BRLIVEX] 需要改成旧字段名
        r.note = @"番剧时间表（已转换）";
        return r;
    }

    // ---- 番剧详情 ----
    if ([path hasPrefix:@"/pgc/view/"] || [path hasPrefix:@"/pgc/season/"]) {
        NSString *sid = qs[@"season_id"], *ep = qs[@"ep_id"];
        if ([sid length])
            r.url = [NSString stringWithFormat:@"https://api.bilibili.com/pgc/view/web/season?season_id=%@", sid];
        else if ([ep length])
            r.url = [NSString stringWithFormat:@"https://api.bilibili.com/pgc/view/web/season?ep_id=%@", ep];
        else
            r.url = [NSString stringWithFormat:@"https://api.bilibili.com%@?%@", path, rawQuery];
        r.kind = @"raw";
        r.note = @"番剧详情";
        return r;
    }

    // ---- 番剧播放地址 ----
    if ([path isEqualToString:@"/pgc/player/api/playurl"] ||
        [path isEqualToString:@"/pgc/player/web/playurl"] ||
        [path isEqualToString:@"/player/playurl"]) {
        NSString *ep = qs[@"ep_id"], *cid = qs[@"cid"], *avid = qs[@"avid"] ?: qs[@"aid"];
        // [BRPGCWEB] 2026-10-16 審計實測：pgc/player/api/playurl 已回
        //   {"code":-400,"message":"请求错误"}，而 pgc/player/web/playurl
        //   回 {"code":0,"result":{...,"durl":[...]}} 正常。
        //   插件原本寫死 api 版 → 番劇完全播不出來。
        //   注意可用介面的載荷在 result（不是 data）；App 原本打的也是 pgc 系
        //   （result 風格），所以直接換上游、原樣透傳即可。
        NSMutableString *u = [NSMutableString stringWithString:
                              @"https://api.bilibili.com/pgc/player/web/playurl?"];
        if ([ep length])   [u appendFormat:@"ep_id=%@&", ep];
        if ([cid length])  [u appendFormat:@"cid=%@&", cid];
        if ([avid length]) [u appendFormat:@"avid=%@&", avid];
        [u appendString:@"fnval=0&fnver=0&fourk=0&platform=html5"];
        r.url = u;
        r.kind = @"playurl";
        r.note = @"番剧播放地址";
        return r;
    }

    // ---- 个人主页（★ 必须 wbi 签名，否则风控判 v_voucher）----
    if ([path hasPrefix:@"/x/v2/space"] || [path hasPrefix:@"/x/space"]) {
        NSString *mid = qs[@"mid"] ?: qs[@"vmid"] ?: @"";
        if ([path rangeOfString:@"arc"].location != NSNotFound ||
            [path rangeOfString:@"archive"].location != NSNotFound ||
            [path rangeOfString:@"video"].location != NSNotFound) {
            NSString *pn = qs[@"pn"] ?: qs[@"page"] ?: @"1";
            NSString *ps = qs[@"ps"] ?: qs[@"pagesize"] ?: @"20";
            NSString *b = [NSString stringWithFormat:
                           @"https://api.bilibili.com/x/space/wbi/arc/search?mid=%@&pn=%@&ps=%@&order=pubdate",
                           mid, pn, ps];
            r.url = [BRSession wbiSignURL:b];
            r.kind = @"raw";
            r.note = @"个人主页投稿";
            return r;
        }
        if ([mid length]) {
            // [BRSPACECARD] 原本用 space/wbi/acc/info，有兩個獨立問題：
            //   ①【形狀】App 的模型叫 BBPhoneUserSpaceCardModel，其 ivar 是
            //      _DisplayRank/_approve/_article/_attention/_attentions/_birthday/
            //      _face/_fans/_level_info/_mid/_name/_nameplate/_official_verify/
            //      _pendant/_rank/_sex/_sign/_spacesta/_vip …
            //      而 web-interface/card 的 data.card 欄位是
            //      DisplayRank/approve/article/attention/attentions/birthday/
            //      face/fans/level_info/mid/name/nameplate/official_verify/
            //      pendant/rank/sex/sign/spacesta/vip …
            //      → 連 "DisplayRank" 的大寫 D 都一樣，代表 App 解析的是
            //        **card 巢狀結構**；而 acc/info 回的是扁平物件 → 形狀不對。
            //   ②【端點】2026-10-16 實測：acc/info 對老/現代 UA 都回
            //      -352（风控 v_voucher）→ 個人主頁空白。
            //   改用 web-interface/card：形狀本來就對，原樣透傳即可。
            if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-nospacecard"]) {
                BRINFO(@"[改写] 个人主页信息已回退 acc/info（/tmp/br-nospacecard）");
                NSString *bb = [NSString stringWithFormat:
                                @"https://api.bilibili.com/x/space/wbi/acc/info?mid=%@", mid];
                r.url = [BRSession wbiSignURL:bb];
                r.kind = @"nav";
                r.note = @"个人主页信息（回退 acc/info）";
                return r;
            }
            r.url = [NSString stringWithFormat:
                     @"https://api.bilibili.com/x/web-interface/card?mid=%@&photo=false", mid];
            r.kind = @"raw";
            r.note = @"个人主页信息（web-interface/card）";
            return r;
        }
    }

    // ================= 默认：保持原 host，只补风控头 =================
    r.url = [NSString stringWithFormat:@"https://%@%@%@", host, path,
             [rawQuery length] ? [NSString stringWithFormat:@"?%@", rawQuery] : @""];
    r.kind = @"raw";
    r.note = @"默认";
    return r;
}

// ---------------------------------------------------------------- 分区

+ (BRRoute *)routeRegion:(NSString *)path qs:(NSDictionary *)qs {
    // ★★★ 关键修正：/x/v2/region（不带 /show）是「分区列表/菜单」请求，
    //   不是「某个分区里的视频」。之前把它改道到 UWP 的 dynamic/child?rid=1，
    //   等于把「视频列表」当成「分区列表」交给 App → 找不到字段 → self。
    //   所以这里不改写，让 App 用它的原始接口。
    if ([path isEqualToString:@"/x/v2/region"] ||
        [path isEqualToString:@"/x/v2/region/index"]) {
        // [BRREGIONHOME] 原本是「原樣透傳」，但 2026-10-16 實測伺服器已回
        //   code=-400 请求错误 → 分區選單拿不到東西。
        //   改用 App 自帶的 tidMetaNIirV2.json 組出回應（見 convertResponse）。
        BRRoute *rh = [[BRRoute alloc] init];
        rh.kind = @"regionhome";
        rh.url = nil;                      // 不改寫上游，只取代回應
        rh.note = @"分区菜单（用本机清单组）";
        BRINFO(@"[改写] /x/v2/region → regionhome（用本机分区清单组）");
        return rh;
    }

    // ★★★ /region/show/dynamic 是「二级/动态分区」，不是一级分区。
    //   实测日志：App 请求它，我却把它路由成「一级分区(newlist rid=4 pn=2)」
    //   → 拿到的是某个一级分区的内容 → 界面没内容/排版错。
    //   这里不改写，保持透传。
    if ([path rangeOfString:@"/region/show/dynamic"].location != NSNotFound) {
        // [BRREGIONDYN] 原本是「原樣透傳」，但 2026-10-16 實測伺服器回
        //   {"code":0,"data":[]}（空陣列）→ 二級分區內容全空。
        //   而 newlist 對二級 tid 也是 0 筆（二級分區服務已關停），
        //   只有 ranking/region 對二級 tid 4/4 有資料 → 改走它。
        NSString *tid = qs[@"tid"] ?: qs[@"rid"] ?: qs[@"tag_id"] ?: qs[@"area_id"];
        if ([tid length] &&
            ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-noregiondyn"]) {
            BRRoute *rd = [[BRRoute alloc] init];
            rd.url = [NSString stringWithFormat:
                      @"https://api.bilibili.com/x/web-interface/ranking/region?rid=%@&day=3",
                      tid];
            rd.kind = @"regiondynx";
            rd.note = @"二级分区内容（ranking/region）";
            BRINFO(@"[改写] /x/v2/region/show/dynamic → ranking/region rid=%@", tid);
            return rd;
        }
        BRINFO(@"[改写] /x/v2/region/show/dynamic 缺 tid → 维持原样透传");
        return nil;
    }

    BRRoute *r = [[BRRoute alloc] init];
    NSString *rid = qs[@"rid"] ?: qs[@"tag_id"] ?: qs[@"tid"] ?: @"1";
    NSString *pn  = qs[@"pn"] ?: qs[@"page"] ?: @"1";
    NSString *ps  = qs[@"ps"] ?: qs[@"pagesize"] ?: qs[@"page_size"] ?: @"20";
    NSString *tag = qs[@"tag_name"] ?: qs[@"tag"] ?: qs[@"keyword"];

    // 番剧/国创类分区的内容在 PGC 系统里，newlist 对它们恒返回 0 条
    if ([@[@"32", @"33", @"153", @"13"] containsObject:rid]) {
        r.url = [NSString stringWithFormat:
            @"https://api.bilibili.com/pgc/season/index/result?st=1&order=3"
            @"&season_type=1&page=%@&pagesize=%@&type=1", pn, ps];
        r.kind = @"region";
        r.extra = @{@"pgc": @YES};
        r.note = @"番剧类分区";
        return r;
    }

    if ([tag length]) {
        // ★ 开关回退：转换器禁用时，搜索结果转不成二级分区结构 → 空白。
        //   改走 newlist（响应原生就是 archives[]）。
        if (BRConvOff(@"region")) {
            r.url = [NSString stringWithFormat:
                @"https://api.bilibili.com/x/web-interface/newlist?rid=%@&pn=%@&ps=%@&tag_name=%@",
                rid, pn, ps, tag];
            r.kind = @"raw";
            r.note = @"分区(带tag，开关回退 newlist)";
            return r;
        }
        // ★★ 伪二级分区：B 站原二级分区服务已关停（带 tag 只是换了一页无关内容），
        //    所以改用「该分区名」做关键词去搜索，再把结果转成二级分区结构。
        //    ⚠️ 关键词必须传**原始值**：wbiSignURL 会对每个值再编码一次，
        //       预先编码会导致 % 变成 %25（双重编码）→ 服务端收到乱码 →
        //       返回一堆与关键词无关的泛化结果。
        NSString *base = [NSString stringWithFormat:
            @"https://api.bilibili.com/x/web-interface/wbi/search/type"
            @"?search_type=video&keyword=%@&page=%@", tag, pn];
        r.url = [BRSession wbiSignURL:base];
        r.kind = @"regiontag";
        r.ua = [BRSession searchUA];
        r.extra = @{@"tag": tag, @"pn": pn};
        r.note = [NSString stringWithFormat:@"伪二级分区「%@」", tag];
        return r;
    }

    // ★★ 开关回退：转换器被禁用（/tmp/br-noconv）时，UWP 通道的 data.new[]
    //    没有任何东西能把它转成老客户端认的结构 → 分区彻底空白。
    //    这时改走 newlist —— 它的响应原生就是 archives[]，不转换也能显示。
    if (BRConvOff(@"region")) {
        r.url = [NSString stringWithFormat:
            @"https://api.bilibili.com/x/web-interface/newlist?rid=%@&pn=%@&ps=%@",
            rid, pn, ps];
        r.kind = @"raw";
        r.note = @"分区（开关回退 newlist）";
        return r;
    }

    // ★ 一级分区：用经典 newlist，并且**必须带上 pn/ps**！
    //   之前转去 UWP 的 dynamic/child，那个接口不支持分页（永远返回第一页），
    //   于是分区卡片上的「换一换」刷新键点了没反应
    //   （用户反馈：「分區那裏的單獨刷新鍵點了不刷新」）。
    //   注意层级：UWP dynamic/child 是【二级】分区用的，一级分区用 newlist。
    r.url = [NSString stringWithFormat:
        @"https://api.bilibili.com/x/web-interface/newlist"
        @"?rid=%@&pn=%@&ps=%@&order=0&build=4070&mobi_app=iphone"
        @"&platform=ios&device=phone&appkey=27eb53fc9058f8c3",
        rid, pn, ps];
    r.kind = @"region";
    r.extra = @{@"pn": pn, @"ps": ps, @"rid": rid};
    r.note = [NSString stringWithFormat:@"一级分区(newlist rid=%@ pn=%@)", rid, pn];
    return r;
}

#pragma mark - 响应改写

+ (NSDictionary *)jsonFromData:(NSData *)d {
    if (![d length]) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}

+ (NSData *)dataFromJSON:(id)obj {
    if (obj == nil) return nil;
    if (![NSJSONSerialization isValidJSONObject:obj]) return nil;
    return [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
}

+ (id)fixImages:(id)obj {
    // 老客户端的图片加载器不认 protocol-relative（//i0.hdslb.com/...），
    // 必须补上 http:
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *o = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        for (NSString *k in obj) [o setObject:[self fixImages:[obj objectForKey:k]] forKey:k];
        return o;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id v in obj) [a addObject:[self fixImages:v]];
        return a;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        if ([obj hasPrefix:@"//"]) return [@"http:" stringByAppendingString:obj];
        return obj;
    }
    return obj;
}

static NSString *BRStripEm(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return s;
    // 搜索结果标题里带 <em class="keyword"> 高亮标签，老客户端会原样显示
    NSString *o = [s stringByReplacingOccurrencesOfString:@"<em class=\"keyword\">" withString:@""];
    o = [o stringByReplacingOccurrencesOfString:@"</em>" withString:@""];
    o = [o stringByReplacingOccurrencesOfString:@"<em>" withString:@""];
    return o;
}

// 统一的「老式视频对象」
+ (NSMutableDictionary *)legacyVideoFrom:(NSDictionary *)it {
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    long long realAid = [[it objectForKey:@"aid"] longLongValue];
    if (realAid == 0) realAid = [[it objectForKey:@"param"] longLongValue];
    if (realAid == 0) realAid = [[it objectForKey:@"id"] longLongValue];

    long long realCid = [[it objectForKey:@"cid"] longLongValue];
    if (realAid > 0 && realCid > 0) [BRStore rememberCid:realCid forAid:realAid];

    [o setObject:@([BRStore fakeAidForReal:realAid]) forKey:@"aid"];
    [o setObject:@([BRStore fakeAidForReal:realAid]) forKey:@"id"];
    [o setObject:(it[@"bvid"] ?: @"") forKey:@"bvid"];
    [o setObject:BRStripEm(it[@"title"] ?: @"") forKey:@"title"];
    NSString *pic = it[@"pic"] ?: it[@"cover"] ?: @"";
    if ([pic hasPrefix:@"//"]) pic = [@"http:" stringByAppendingString:pic];
    [o setObject:pic forKey:@"pic"];
    [o setObject:(it[@"description"] ?: it[@"desc"] ?: @"") forKey:@"description"];
    [o setObject:(it[@"author"] ?: it[@"name"] ?: @"") forKey:@"author"];
    NSString *face = it[@"face"] ?: @"";
    if ([face hasPrefix:@"//"]) face = [@"http:" stringByAppendingString:face];
    [o setObject:face forKey:@"face"];
    [o setObject:@([[it objectForKey:@"mid"] longLongValue]) forKey:@"mid"];
    [o setObject:@([[it objectForKey:@"play"] longLongValue]) forKey:@"play"];
    id dm = it[@"danmaku"] ?: it[@"video_review"] ?: @0;
    [o setObject:dm forKey:@"video_review"];
    [o setObject:dm forKey:@"danmaku"];
    [o setObject:@([[it objectForKey:@"reply"] longLongValue]) forKey:@"review"];
    [o setObject:@([[it objectForKey:@"favourite"] longLongValue]) forKey:@"favorites"];
    [o setObject:BRNum(it[@"duration"]) forKey:@"duration"];
    [o setObject:BRNum(it[@"pubdate"] ?: it[@"create"] ?: @"") forKey:@"create"];
    if (it[@"typename"] || it[@"rname"])
        [o setObject:(it[@"typename"] ?: it[@"rname"]) forKey:@"typename"];
    if (it[@"cid"]) [o setObject:@([BRStore fakeCidForReal:realCid]) forKey:@"cid"];
    return o;
}


// ★★★ ID 虚拟化：递归把 JSON 里的 aid/avid 换成 ≤int32 的假 ID。
//   与结构转换无关，必须永远生效 —— 否则老客户端 int32 溢出，
//   表现为「点进去串到别的视频」或「视频找不到了」。
//   只动 aid/avid；cid 交给各转换器处理（避免影响弹幕取用）。
+ (id)virtualizeAids:(id)obj {
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id v in (NSArray *)obj) {
            id nv = [self virtualizeAids:v];
            [a addObject:(nv ?: [NSNull null])];
        }
        return a;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        for (id k in (NSDictionary *)obj) {
            id v = [(NSDictionary *)obj objectForKey:k];
            if ([k isKindOfClass:[NSString class]] &&
                ([k isEqualToString:@"aid"] || [k isEqualToString:@"avid"])) {
                long long ll = 0;
                if ([v respondsToSelector:@selector(longLongValue)]) ll = [v longLongValue];
                if (ll > 0) {
                    long long f = [BRStore fakeAidForReal:ll];
                    if (f > 0) v = @(f);
                }
            } else if ([k isKindOfClass:[NSString class]] &&
                       [k isEqualToString:@"param"] &&
                       ([v isKindOfClass:[NSString class]] ||
                        [v isKindOfClass:[NSNumber class]])) {
                // [BRVZ_PARAM] ★★ 關鍵修正。
                //   老客戶端的影片模型把 aid 存成 32 位；而首頁卡片項目把影片 id
                //   放在 **`param`**（不是 aid/avid），且是 **15 位真實 aid**。
                //   virtualizeAids 原本只轉 aid/avid → `param` 沒被虛擬化
                //   → 15 位數字進到 32 位模型 → 飽和成 2147483647
                //   → 詳情請求 ?aid=2147483647 → 404「啥都木有」→「視頻不見了喲」。
                //
                //   安全條件：**只有「大於 INT32_MAX 的純數字」才轉**。
                //   rid（1/3/167）、season_id（5538）、room_id（37034）等小數字
                //   一律原樣，不會被誤傷。
                long long ll = 0;
                NSString *sv = [v isKindOfClass:[NSString class]]
                    ? (NSString *)v : [v description];
                BOOL allDigits = ([sv length] > 0);
                for (NSUInteger i = 0; i < [sv length]; i++) {
                    unichar ch = [sv characterAtIndex:i];
                    if (ch < '0' || ch > '9') { allDigits = NO; break; }
                }
                if (allDigits) ll = [sv longLongValue];
                if (ll > 2147483647LL) {
                    long long f = [BRStore fakeAidForReal:ll];
                    if (f > 0) {
                        BRDBG(@"[改写] param 虚拟化 %lld -> %lld", ll, f);
                        v = [NSString stringWithFormat:@"%lld", f];
                        // [BRVZ_INJECT] ★ App 自己的卡片項目只有 param（字串），
                        //   沒有 aid / id —— 而舊版 `legacyVideoFrom:`（實測推薦卡
                        //   能進入詳情）是把 aid 與 id 都輸出成**數字**。
                        //   所以在這裡一併補上（數字型別），讓點擊有東西可讀。
                        if ([d objectForKey:@"aid"] == nil)
                            [d setObject:@(f) forKey:@"aid"];
                        if ([d objectForKey:@"id"] == nil)
                            [d setObject:@(f) forKey:@"id"];
                        if ([d objectForKey:@"avid"] == nil)
                            [d setObject:@(f) forKey:@"avid"];
                    }
                }
            } else {
                id nv = [self virtualizeAids:v];
                if (nv != nil) v = nv;
            }
            [d setObject:(v ?: [NSNull null]) forKey:k];
        }
        return d;
    }
    return obj;
}

+ (NSData *)convertResponse:(NSData *)body forRoute:(BRRoute *)route {
    // [BRGUNZIP_IN_CONV] ★ 若是 gzip 压缩体，先解压再处理。
    //   之前几轮「改了数据但界面没变」很可能就是这个原因：
    //   数据换了、Content-Encoding 没换 → App 拿未压缩数据当 gzip 解压 → 失败。
    BOOL brWasGzip = (BRRespWasGzip() == YES);   // [BRFILL_V2]
    if (brWasGzip) {
        body = [BRRouter gunzip:body];
        BRDBG(@"[改写] 已解压 gzip，得到 %lu 字节", (unsigned long)[body length]);
    }

    // ★★★ 转换器开关（细粒度）：
    //   /tmp/br-noconv         关全部
    //   /tmp/br-noconv-<kind>  只关某一类（feed/search/rank/view/region/playurl）
    //   这样不重新编译就能逐个验证是哪个转换器的问题。

    {
        if (BRConvOff(route.kind)) {
            BRDBG(@"[改写] 转换器被开关禁用: %@", route.kind);
            return body;
        }
    }

    // ★ 先做 ID 虚拟化（与结构无关，永远生效，防止 int32 溢出）
    {
        NSDictionary *jj = [self jsonFromData:body];
        if (jj != nil) {
            id v = [BRRouter virtualizeAids:jj];
            NSData *vd = [self dataFromJSON:v];
            if (vd != nil) body = vd;
        }
    }

    // ================= [BRLIVEX] 直播清單轉換 =================
    if ([route.kind isEqualToString:@"livelistx"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-nolive"]) {
            BRINFO(@"[改写] 直播转换已被 /tmp/br-nolive 关闭");
            return body;
        }
        @try {
            NSDictionary *j = [self jsonFromData:body];
            NSDictionary *dd = [j objectForKey:@"data"];
            if (![dd isKindOfClass:[NSDictionary class]]) {
                BRINFO(@"[改写] 直播回应没有 data 字典，原样返回");
                return body;
            }
            // 先收 room_list[].list（字段最全），再补 recommend_room_list
            NSMutableArray *raw = [NSMutableArray array];
            id rl = [dd objectForKey:@"room_list"];
            if ([rl isKindOfClass:[NSArray class]]) {
                for (id mod in rl) {
                    if (![mod isKindOfClass:[NSDictionary class]]) continue;
                    id inner = [mod objectForKey:@"list"];
                    if ([inner isKindOfClass:[NSArray class]]) [raw addObjectsFromArray:inner];
                }
            }
            id rec = [dd objectForKey:@"recommend_room_list"];
            if ([rec isKindOfClass:[NSArray class]]) [raw addObjectsFromArray:rec];

            NSMutableArray *rooms = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            for (id it in raw) {
                if (![it isKindOfClass:[NSDictionary class]]) continue;
                // 跳過廣告位
                id isAd = [it objectForKey:@"is_ad"];
                if (isAd != nil && [isAd respondsToSelector:@selector(boolValue)] && [isAd boolValue])
                    continue;
                NSDictionary *o = [BRRouter brLiveRoomFromDict:it];
                if (o == nil) continue;
                NSString *k = [[o objectForKey:@"room_id"] description];
                if (k == nil || [seen containsObject:k]) continue;
                [seen addObject:k];
                [rooms addObject:o];
            }
            NSUInteger n = [rooms count];
            BRINFO(@"[改写] 直播转换：xlive → livelist %lu 间", (unsigned long)n);
            if (n == 0) {
                BRINFO(@"[改写] 直播转换得到 0 间，原样返回（避免给 App 空结构）");
                return body;
            }
            NSDictionary *inner = @{
                @"count": @(n), @"hasNext": @0, @"has_next": @0, @"hasnext": @0,
                @"livelist": rooms, @"list": rooms, @"rooms": rooms,
                @"page": @1, @"status": @0,
                @"totalCount": @(n), @"total_count": @(n),
                @"totalPage": @1, @"total_page": @1,
            };
            // [BRDATAARRAY] ★ App 明確在要「陣列」——
            //   真機日誌顯示它印的是 `[self.response arrayValue] return nil`，
            //   而我們把 data 給成字典（inner）。所以 data 改放項目陣列；
            //   原本的字典（count/page/totalCount…）改放 result 保留。
            NSDictionary *o = @{ @"code": @0, @"message": @"ok",
                                 @"data": rooms, @"result": inner,
                                 @"count": @(n), @"page": @1,
                                 @"totalCount": @(n), @"totalPage": @1,
                                 @"livelist": rooms, @"list": rooms };
            NSData *nd = [self dataFromJSON:[self fixImages:o]];
            if (nd != nil) return nd;
        } @catch (NSException *e) {
            BRERR(@"[改写] 直播转换失败: %@", [e description]);
        }
        return body;
    }

    // ================= [BRLIVEX] 番剧时间表转换 =================
    if ([route.kind isEqualToString:@"bangumitlx"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-nobangumi"]) {
            BRINFO(@"[改写] 番剧转换已被 /tmp/br-nobangumi 关闭");
            return body;
        }
        @try {
            NSDictionary *o = [BRRouter brTimelineToOld:[self jsonFromData:body]];
            if (o == nil) {
                BRINFO(@"[改写] 番剧时间表转换失败，原样返回");
                return body;
            }
            NSData *nd = [self dataFromJSON:[self fixImages:o]];
            if (nd != nil) return nd;
        } @catch (NSException *e) {
            BRERR(@"[改写] 番剧时间表转换异常: %@", [e description]);
        }
        return body;
    }

    // ================= [BRLIVEX] 番剧首页拼装 =================
    if ([route.kind isEqualToString:@"bangumihome"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-nobangumi"]) {
            BRINFO(@"[改写] 番剧转换已被 /tmp/br-nobangumi 关闭");
            return body;
        }
        @try {
            // body 是 timeline；再抓一次索引拿 finishedBangumis
            NSDictionary *idx = nil;
            @try {
                NSString *iu = @"https://api.bilibili.com/pgc/season/index/result"
                               @"?st=1&order=3&season_type=1&page=1&pagesize=8&type=1";
                NSData *id2 = BRRegionHttpGet(iu);
                if (id2 != nil) idx = [self jsonFromData:id2];
            } @catch (NSException *e) { }
            NSDictionary *o = [BRRouter brBangumiHomeFromTimeline:[self jsonFromData:body]
                                                            index:idx];
            if (o == nil) {
                BRINFO(@"[改写] 番剧首页拼装失败，原样返回");
                return body;
            }
            NSData *nd = [self dataFromJSON:[self fixImages:o]];
            if (nd != nil) return nd;
        } @catch (NSException *e) {
            BRERR(@"[改写] 番剧首页拼装异常: %@", [e description]);
        }
        return body;
    }

    // ================= [BRREGIONDYN] 二級分區內容 =================
    //   2026-10-16 實測：/x/v2/region/show/dynamic 回 {"code":0,"data":[]}（空），
    //   newlist 對二級 tid 全部 0 筆（二級分區服務已關停），
    //   而 ranking/region 對二級 tid 4/4 都有資料 → 改走它。
    //   元素欄位名取自二進位抽出的 BBPhoneMovieZoneRelatesModel
    //   { aid, pic, play, review, title, video_review }（老式扁平影片物件）。
    if ([route.kind isEqualToString:@"regiondynx"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-noregiondyn"]) {
            BRINFO(@"[改写] 二级分区内容转换已被 /tmp/br-noregiondyn 关闭");
            return body;
        }
        @try {
            NSDictionary *j = [self jsonFromData:body];
            id list = [j objectForKey:@"data"];
            if (![list isKindOfClass:[NSArray class]] || [list count] == 0) {
                BRINFO(@"[改写] 二级分区内容：上游没有资料，原样返回");
                return body;
            }
            NSMutableArray *out = [NSMutableArray array];
            for (id one in list) {
                if (![one isKindOfClass:[NSDictionary class]]) continue;
                id aidRaw = [one objectForKey:@"aid"];
                if (aidRaw == nil) aidRaw = [one objectForKey:@"id"];
                long long aidLL = 0;
                if ([aidRaw respondsToSelector:@selector(longLongValue)])
                    aidLL = [aidRaw longLongValue];
                else if ([aidRaw isKindOfClass:[NSString class]])
                    aidLL = [(NSString *)aidRaw longLongValue];
                long long fake = [BRStore fakeAidForReal:aidLL];
                if (fake <= 0) continue;
                NSDictionary *st = [one objectForKey:@"stat"];
                if (![st isKindOfClass:[NSDictionary class]]) st = @{};
                id play = [one objectForKey:@"play"];
                if (play == nil) play = [st objectForKey:@"view"];
                id dm = [one objectForKey:@"video_review"];
                if (dm == nil) dm = [st objectForKey:@"danmaku"];
                id rv = [one objectForKey:@"review"];
                if (rv == nil) rv = [st objectForKey:@"reply"];
                // aid 用虛擬化後的值（老客戶端 avid 是 int32，真實 15 位會溢出）
                [out addObject:@{
                    @"aid":          [NSString stringWithFormat:@"%lld", fake],
                    @"title":        [one objectForKey:@"title"] ?: @"",
                    @"pic":          BRPicFix([one objectForKey:@"pic"] ?: @""),
                    @"play":         (play ?: @0),
                    @"video_review": (dm ?: @0),
                    @"review":       (rv ?: @0),
                    @"favorites":    ([st objectForKey:@"favorite"] ?: @0),
                    @"coins":        ([st objectForKey:@"coin"] ?: @0),
                    @"author":       ([one objectForKey:@"author"] ?: @""),
                    @"mid":          ([one objectForKey:@"mid"] ?: @0),
                    @"duration":     ([one objectForKey:@"duration"] ?: @""),
                    @"create":       ([one objectForKey:@"create"] ?: @""),
                    @"description":  ([one objectForKey:@"description"] ?: @""),
                    @"typename":     ([one objectForKey:@"typename"] ?: @""),
                }];
            }
            if ([out count] == 0) return body;
            BRINFO(@"[改写] 二级分区内容转换：%lu 笔", (unsigned long)[out count]);
            NSDictionary *o = @{ @"code": @0, @"message": @"0",
                                 @"data": out, @"result": out, @"list": out };
            NSData *nd = [self dataFromJSON:[self fixImages:o]];
            if (nd != nil) return nd;
        } @catch (NSException *e) {
            BRERR(@"[改写] 二级分区内容转换异常: %@", [e description]);
        }
        return body;
    }

    // ================= [BRREGIONHOME] 分區選單 =================
    //   2026-10-16 實測：伺服器對 /x/v2/region 回 code=-400、/x/v2/partition 回 404、
    //   /x/v2/region/show/dynamic 回空陣列 —— 舊分區介面全掛了。
    //   而 App 自己帶了完整清單 tidMetaNIirV2.json（13 個一級分區 + children），
    //   結構正好對應 BBPhoneRegionModel { banners, catalogys, recommends } 與
    //   BBPhoneVideoCategoryMeta { tid, name, children }（兩個獨立來源形狀一致）。
    //   所以直接用 App 自帶的檔案組出回應。
    if ([route.kind isEqualToString:@"regionhome"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-noregionhome"]) {
            BRINFO(@"[改写] 分区菜单转换已被 /tmp/br-noregionhome 关闭");
            return body;
        }
        @try {
            // 優先讀完整清單，其次退回較小的 tidMetaV2
            NSString *path = [[NSBundle mainBundle] pathForResource:@"tidMetaNIirV2" ofType:@"json"];
            if (path == nil) path = [[NSBundle mainBundle] pathForResource:@"tidMetaV2" ofType:@"json"];
            if (path == nil) {
                BRERR(@"[改写] 找不到本机分区清单（tidMetaNIirV2.json）");
                return body;
            }
            NSData *fd = [NSData dataWithContentsOfFile:path];
            NSArray *cats = fd ? [self jsonFromData:fd] : nil;
            if (![cats isKindOfClass:[NSArray class]] || [cats count] == 0) {
                BRERR(@"[改写] 分区清单解析失败或为空");
                return body;
            }
            NSMutableArray *out = [NSMutableArray array];
            for (id one in cats) {
                if (![one isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *c = [NSMutableDictionary dictionary];
                id tid = [one objectForKey:@"tid"];
                [c setObject:(tid ?: @0) forKey:@"tid"];
                [c setObject:([one objectForKey:@"name"] ?: @"") forKey:@"name"];
                id kids = [one objectForKey:@"children"];
                if (![kids isKindOfClass:[NSArray class]]) kids = @[];
                [c setObject:kids forKey:@"children"];
                // 老模型另有這幾個欄位，補上空值避免 nil
                [c setObject:@0 forKey:@"needNavigation"];
                [c setObject:@0 forKey:@"selfAsChild"];
                if (tid != nil) [c setObject:tid forKey:@"parentTid"];
                NSMutableArray *ids = [NSMutableArray array];
                for (id k in kids) {
                    if ([k isKindOfClass:[NSDictionary class]]) {
                        id kt = [k objectForKey:@"tid"];
                        if (kt != nil) [ids addObject:kt];
                    }
                }
                [c setObject:ids forKey:@"childrenIdArray"];
                [c setObject:kids forKey:@"childrenArray"];
                [out addObject:c];
            }
            NSDictionary *inner = @{
                @"banners": @[],
                @"catalogys": out,
                @"catalogs": out,              // 常見的拼法，兩種都給
                @"recommends": @[],
            };
            BRINFO(@"[改写] 分区菜单：用本机清单组出 %lu 个一级分区", (unsigned long)[out count]);
            NSData *nd = [self dataFromJSON:[self fixImages:@{
                @"code": @0, @"message": @"0", @"data": inner, @"result": inner }]];
            if (nd != nil) return nd;
        } @catch (NSException *e) {
            BRERR(@"[改写] 分区菜单组装修败: %@", [e description]);
        }
        return body;
    }

    // [BROLDHOME] 首页：填充各分区卡片的空 body
    if ([route.kind isEqualToString:@"oldhome"]) {
        // [BRNEWLISTX] 安全开关：/tmp/br-fill-off 存在时完全不碰首页，
        //   保证 App 稳定（分区卡片会是空的，但绝不崩）。
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/br-fill-off"]) {
            BRINFO(@"[改写] oldhome 填充已被 /tmp/br-fill-off 关闭，原样透传");
            return body;
        }
        @try {
            NSDictionary *oh = [self jsonFromData:body];
            if (oh == nil) {
                BRINFO(@"[改写] oldhome 响应不是 JSON（%lu 字节，可能仍是压缩体）",
                       (unsigned long)[body length]);
                return body;
            }
            id dataArr = [oh objectForKey:@"data"];
            if (![dataArr isKindOfClass:[NSArray class]]) {
                BRINFO(@"[改写] oldhome data 不是数组，跳过");
                return body;
            }
            NSMutableArray *cards = [NSMutableArray arrayWithArray:dataArr];
            NSUInteger filled = 0;
            // [BRBUDGET] 时间预算护栏。
            //   首页填充跑在同步路径上（hook 的是 sendSynchronousRequest），
            //   卡太久会被 iOS 看门狗当成死锁杀掉（0x8badf00d）。
            //   实测：14 张卡 52 秒；本版改成三级数据源后，条目不足的分区
            //   还要多发一次 newlist，最坏约 19 个请求 × 3 秒 = 57 秒。
            //   超过预算就停止续填 —— 剩下的卡片保持原样，
            //   保证首页一定画得出来（宁可少填几张，也不要整页被杀）。
            NSTimeInterval brFillStart = [[NSDate date] timeIntervalSince1970];
            const NSTimeInterval BR_FILL_BUDGET = 55.0;
            if ([cards count] > 0 && [[cards objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
                BRINFO(@"[改写] oldhome 卡片键名样本: %@（共 %lu 张卡片）",
                       [[[cards objectAtIndex:0] allKeys] componentsJoinedByString:@","],
                       (unsigned long)[cards count]);
            }
            // [BRPREFETCH] 先並行預取所有需要的分區榜單 —— 迴圈接著全部命中快取，
            //   把原本循序 52 秒的首頁填充降到約 10 秒。
            {
                NSMutableArray *prefetchRids = [NSMutableArray array];
                for (NSUInteger pi = 0; pi < [cards count]; pi++) {
                    id pc = [cards objectAtIndex:pi];
                    if (![pc isKindOfClass:[NSDictionary class]]) continue;
                    NSString *pr = nil;
                    for (NSString *pk in @[@"param", @"rid", @"tid"]) {
                        id pv = [pc objectForKey:pk];
                        if (pv == nil) continue;
                        NSString *ps = [NSString stringWithFormat:@"%@", pv];
                        if ([ps length] && [ps intValue] > 0) { pr = ps; break; }
                    }
                    if (pr != nil && ![prefetchRids containsObject:pr]) {
                        [prefetchRids addObject:pr];
                    }
                }
                BRPrefetchRegionRank(prefetchRids);
            }
            for (NSUInteger ci = 0; ci < [cards count]; ci++) {
                // [BRBUDGET] 逾預算就停手，避免整頁被看門狗殺
                if ([[NSDate date] timeIntervalSince1970] - brFillStart > BR_FILL_BUDGET) {
                    BRINFO(@"[改写] oldhome 填充已达 %.0f 秒预算，停止续填（已填 %lu 张，剩余保持原样）",
                           BR_FILL_BUDGET, (unsigned long)filled);
                    break;
                }
                id c = [cards objectAtIndex:ci];
                if (![c isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *card = [NSMutableDictionary dictionaryWithDictionary:c];

                // [BRFILL_V2] 槽位字段名（已由 App 自带的 home_init/config 证实是 "body"）
                NSString *bodyKey = nil;
                for (NSString *k in @[@"body", @"items", @"list"]) {
                    id v = [card objectForKey:k];
                    if ([v isKindOfClass:[NSArray class]]) { bodyKey = k; break; }
                }
                NSArray *curBody = bodyKey ? [card objectForKey:bodyKey] : nil;

                // [BRFILL_V2] rid 来源 = 卡片的 param（config 中 动画区=1 / 音乐区=3 …）
                NSString *rid = nil;
                for (NSString *k in @[@"param", @"rid", @"tid"]) {
                    id v = [card objectForKey:k];
                    if (v != nil) {
                        NSString *s = [NSString stringWithFormat:@"%@", v];
                        if ([s length] && [s intValue] > 0) { rid = s; break; }
                    }
                }
                NSString *ttl = [card objectForKey:@"title"] ?: [card objectForKey:@"name"] ?: @"?";

                // [BRFILL_V2] 判断「这一槽位到底有没有真数据」——
                //   光看个数是错的：老接口已死，body 常常是 4 个长度非 0 的空壳
                //   （正好对应界面上的灰框 / 播放量「-」/ 弹幕 0）。
                // [BRUSABLE2] ★ 判斷「這一槽位到底有沒有可顯示的資料」。
                //   原本只看 title + param，但 App 自己的空殼常常**有這兩個、
                //   卻沒有封面也沒有播放量**（畫面症狀：灰框 + 播放量「-」+ 彈幕「0」）。
                //   那樣會被誤判成「有資料」而 continue → 永遠不填。
                //   所以再加上 cover 與 play 兩個必要條件。
                NSUInteger usable = 0;
                for (id e in curBody) {
                    if (![e isKindOfClass:[NSDictionary class]]) continue;
                    id t2 = [e objectForKey:@"title"];
                    id p2 = [e objectForKey:@"param"];
                    id c2 = [e objectForKey:@"cover"];
                    id v2 = [e objectForKey:@"play"];
                    NSString *ts = (t2 && t2 != [NSNull null]) ? [NSString stringWithFormat:@"%@", t2] : @"";
                    NSString *ps = (p2 && p2 != [NSNull null]) ? [NSString stringWithFormat:@"%@", p2] : @"";
                    NSString *cs = (c2 && c2 != [NSNull null]) ? [NSString stringWithFormat:@"%@", c2] : @"";
                    long long pv = 0;
                    if ([v2 respondsToSelector:@selector(longLongValue)]) pv = [v2 longLongValue];
                    else if ([v2 isKindOfClass:[NSString class]]) pv = [(NSString *)v2 longLongValue];
                    if ([ts length] > 0 && [ps length] > 0 && [ps intValue] > 0 &&
                        [cs length] > 0 && pv > 0) usable++;
                }

                // 每张卡片都记日志（15 张全印），这样一眼能看出真实字段名与槽位状态
                BRINFO(@"[改写] oldhome 卡片%lu: title=%@ type=%@ rid=%@ bodyKey=%@ count=%lu usable=%lu keys=%@",
                       (unsigned long)ci, ttl, [card objectForKey:@"type"] ?: @"?",
                       rid ?: @"-", bodyKey ?: @"-",
                       (unsigned long)[curBody count], (unsigned long)usable,
                       [[card allKeys] componentsJoinedByString:@","]);

                if (usable > 0) continue;      // 真有数据 → 保留原样
                // [BRBRANCHORDER] ★ 注意順序：
                //   「有沒有 rid」不可以放在下面三個型別分支之前 ——
                //   recommend 與 live 卡的 param 是空的（rid == nil），
                //   若先判 rid 就會 continue，那兩個分支永遠到不了（實際踩過）。
                //   正確順序：usable → recommend → live → bangumi → rid → region。

                // [BRRECCARD] 「热门焦点」卡（type=recommend，param=''）
                //   這是首頁第一張卡，param 是空的 → 原本被 rid 判斷跳過，從未被填。
                if ([[card objectForKey:@"type"] isKindOfClass:[NSString class]] &&
                    [[card objectForKey:@"type"] isEqualToString:@"recommend"]) {
                    NSArray *rs = BRRecommendCardItems(6);
                    if ([rs count] > 0) {
                        NSString *bk4 = bodyKey ?: @"body";
                        [card setObject:rs forKey:bk4];
                        [cards replaceObjectAtIndex:ci withObject:card];
                        filled++;
                        BRINFO(@"[改写] oldhome 已填热门焦点卡 %lu 条", (unsigned long)[rs count]);
                    } else {
                        BRDBG(@"[改写] oldhome 热门焦点卡取不到内容，保持原样");
                    }
                    continue;
                }

                // [BRLIVECARD] 「正在直播」卡（type=live，param=''）
                //   因為 param 不是正整數，原本會被下面的 rid 判斷跳過 → 從未被填。
                //   形狀取自 config 樣本，資料用 xlive getList。
                if ([[card objectForKey:@"type"] isKindOfClass:[NSString class]] &&
                    [[card objectForKey:@"type"] isEqualToString:@"live"]) {
                    NSArray *ls = BRLiveCardItems(4);
                    if ([ls count] > 0) {
                        NSString *bk3 = bodyKey ?: @"body";
                        [card setObject:ls forKey:bk3];
                        [cards replaceObjectAtIndex:ci withObject:card];
                        filled++;
                        BRINFO(@"[改写] oldhome 已填直播推荐卡 %lu 间", (unsigned long)[ls count]);
                    } else {
                        BRDBG(@"[改写] oldhome 直播推荐卡取不到内容，保持原样");
                    }
                    continue;
                }

                // [BRBANGUMICARD] 「番劇推薦」卡（type=bangumi）要的是**番劇**形狀
                //   { title, cover, param(season_id), finish, index, mtime, status }，
                //   不是 region 形狀。config 的樣本 param='5538' 就是 season_id。
                if ([[card objectForKey:@"type"] isKindOfClass:[NSString class]] &&
                    [[card objectForKey:@"type"] isEqualToString:@"bangumi"]) {
                    NSArray *bs = BRBangumiCardItems(4);
                    if ([bs count] > 0) {
                        NSString *bk2 = bodyKey ?: @"body";
                        [card setObject:bs forKey:bk2];
                        [cards replaceObjectAtIndex:ci withObject:card];
                        filled++;
                        BRINFO(@"[改写] oldhome 已填番剧推荐卡（rid=%@）%lu 条", rid,
                               (unsigned long)[bs count]);
                    } else {
                        BRDBG(@"[改写] oldhome 番剧推荐卡取不到内容，保持原样");
                    }
                    continue;
                }

                // [BRBRANCHORDER] 到這裡才檢查 rid —— 不是分區卡就跳過
                if (rid == nil) {
                    BRDBG(@"[改写] oldhome 卡片%lu 跳过（无 rid，非分区卡）", (unsigned long)ci);
                    continue;
                }

                // 取新数据填进去
                NSArray *vs = [BRRouter fetchRegionVideos:rid count:4];
                if ([vs count] > 0) {
                    NSString *bk = bodyKey ?: @"body";
                    [card setObject:vs forKey:bk];
                    [cards replaceObjectAtIndex:ci withObject:card];
                    filled++;
                    BRINFO(@"[改写] oldhome 已填 %@（rid=%@）%lu 条", ttl, rid,
                           (unsigned long)[vs count]);
                    // [BRGOTOACTION] 改成一行的緊湊 JSON ——
                    //   先前是多行（description 會換行），日誌只截到 "{" 看不出內容。
                    @try {
                        NSData *jd = [self dataFromJSON:[vs objectAtIndex:0]];
                        NSString *js = jd ? [[NSString alloc] initWithData:jd
                                                                  encoding:NSUTF8StringEncoding]
                                          : nil;
                        BRINFO(@"[改写] oldhome 填进去的第一个元素(JSON): %@",
                               js ?: [vs objectAtIndex:0]);
                    } @catch (NSException *e) {
                        BRINFO(@"[改写] oldhome 填进去的第一个元素: %@", [vs objectAtIndex:0]);
                    }
                }
            }
            NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:oh];
            [out setObject:cards forKey:@"data"];
            NSData *nd = [self dataFromJSON:out];
            if (nd != nil) {
                BRINFO(@"[改写] oldhome 填充完成：%lu 张卡片 / 填入 %lu 张",
                       (unsigned long)[cards count], (unsigned long)filled);
                return nd;
            }
        } @catch (NSException *e) {
            BRERR(@"[改写] oldhome 失败: %@", [e description]);
        }
        return body;
    }

    NSString *kind = route.kind;
    if ([kind isEqualToString:@"danmaku"] || [kind isEqualToString:@"raw"]) return body;

    NSDictionary *j = [self jsonFromData:body];
    if (j == nil) return body;   // 不是 JSON（例如某些 XML）就原样返回

    // [BRRESPLOG] 记录每个响应的 code 与长度 —— 用于定位是哪个上游在失败
    @try {
        id c = [j objectForKey:@"code"];
        id msg = [j objectForKey:@"message"];
        BRINFO(@"[响应] %@ code=%@ len=%lu msg=%@",
               route.note ?: route.kind ?: @"?",
               c ?: @"-", (unsigned long)[body length],
               ([msg isKindOfClass:[NSString class]] ? msg : @"-"));
    } @catch (NSException *e) { }

    // ---------- nav：注入登录态 ----------
    if ([kind isEqualToString:@"nav"]) {
        NSMutableDictionary *o = [j mutableCopy];
        NSMutableDictionary *d = [o[@"data"] isKindOfClass:[NSDictionary class]]
                               ? [o[@"data"] mutableCopy] : [NSMutableDictionary dictionary];
        if ([BRSession hasUserCookie]) {
            // 老客户端只读自己的 Model，光有 Cookie 它不知道你登录了。
            // 代理层无法 hook，等价做法是改写它本来就会读的 nav 响应。
            d[@"isLogin"] = @YES;
            if (d[@"money"] == nil) d[@"money"] = @0;
            if (d[@"vipStatus"] == nil) d[@"vipStatus"] = @0;
            o[@"data"] = d;
            if ([o[@"code"] integerValue] == -101) o[@"code"] = @0;
            BRINFO(@"nav 已注入登录态");
        }
        return [self dataFromJSON:[self fixImages:o]];
    }

    // [BRNEWLISTX] 分区数据专用转换器。
    //   newlist 的原生结构是 {"code":0,"data":{"archives":[...]}} ——
    //   既不是 data.items，也不是 data 数组，所以**绝不能**塞给 feed 分支
    //   （那正是「填不进去、没有『已填』日志」的原因）。
    //   这里输出严格等于 App 自带 home_init/config 里的元素结构：
    //     {title, cover, param, play, danmaku, finish}
    //   型别也必须一致（play/danmaku/finish 是数字，title/cover/param 是字符串），
    //   否则老客户端渲染时会 EXC_CRASH (SIGILL)。
    if ([kind isEqualToString:@"newlistx"]) {
        NSDictionary *j = [self jsonFromData:body];
        NSDictionary *dd = [j objectForKey:@"data"];
        NSArray *src = nil;
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id ar = [dd objectForKey:@"archives"];
            if ([ar isKindOfClass:[NSArray class]]) src = ar;
            if (src == nil) {
                id li = [dd objectForKey:@"list"];
                if ([li isKindOfClass:[NSArray class]]) src = li;
            }
        } else if ([dd isKindOfClass:[NSArray class]]) {
            src = dd;
        }
        NSMutableArray *out = [NSMutableArray array];
        for (id raw in src) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *it = raw;

            // param = 虚拟化后的 aid（老客户端 avid 是 int32，真实 15 位 aid 会溢出）
            id aidRaw = [it objectForKey:@"aid"];
            if (aidRaw == nil) aidRaw = [it objectForKey:@"id"];
            long long aidLL = 0;
            if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
            else if ([aidRaw isKindOfClass:[NSString class]]) aidLL = [(NSString *)aidRaw longLongValue];
            long long fakeAidLL = [BRStore fakeAidForReal:aidLL];
            if (fakeAidLL <= 0) continue;            // 没有可用 aid 的条目直接跳过

            NSDictionary *stat = [it objectForKey:@"stat"];
            if (![stat isKindOfClass:[NSDictionary class]]) stat = @{};

            NSString *pic = BRPicFix([it objectForKey:@"pic"] ?: [it objectForKey:@"cover"] ?: @"");
            // App 自带 config 里分区卡的 cover 带 _320x200.jpg 缩略图规格
            if ([pic length] > 0 && [pic rangeOfString:@"_320x200"].location == NSNotFound
                && [pic rangeOfString:@"hdslb.com"].location != NSNotFound) {
                pic = [pic stringByAppendingString:@"_320x200.jpg"];
            }

            [out addObject:@{
                @"title":   [it objectForKey:@"title"] ?: @"",
                @"cover":   pic ?: @"",
                @"param":   [NSString stringWithFormat:@"%lld", fakeAidLL],
                @"play":    [stat objectForKey:@"view"]    ?: @0,
                @"danmaku": [stat objectForKey:@"danmaku"] ?: @0,
                @"finish":  @0,
            }];
        }
        NSDictionary *o = @{
            @"code":    @0,
            @"message": @"0",
            @"data": @{@"archives": out, @"list": out,
                       @"num": @([out count]), @"page": @1, @"size": @([out count])},
            @"archives": out,
            @"list": out,
        };
        BRINFO(@"[改写] newlistx 转换完成：%lu 条", (unsigned long)[out count]);
        if ([out count] > 0) {
            BRINFO(@"[改写] newlistx 元素样本: %@", [out objectAtIndex:0]);
        }
        return [self dataFromJSON:[self fixImages:o]];
    }

    // ---------- 推荐流：老客户端要 data 是数组 ----------
    // ================= 首页推荐（照搬 5.9 参考实现 feed_to_old）=================
    if ([kind isEqualToString:@"feed"]) {
        NSDictionary *j = [self jsonFromData:body];
        NSDictionary *dd = [j objectForKey:@"data"];
        NSArray *src = nil;
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id it = [dd objectForKey:@"item"];
            if ([it isKindOfClass:[NSArray class]]) src = it;
            else {
                id its = [dd objectForKey:@"items"];
                if ([its isKindOfClass:[NSArray class]]) src = its;
            }
        } else if ([dd isKindOfClass:[NSArray class]]) {
            src = dd;
        }
        NSMutableArray *out = [NSMutableArray array];
        for (id raw in src) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *it = raw;
            NSDictionary *owner = [it objectForKey:@"owner"];
            if (![owner isKindOfClass:[NSDictionary class]]) owner = @{};
            NSDictionary *stat = [it objectForKey:@"stat"];
            if (![stat isKindOfClass:[NSDictionary class]]) stat = @{};

            // ★★★ 过滤广告与占位卡片。
            //   新版 feed 会混入广告条目（goto 不是 av、或带 ad_info、或 is_ad），
            //   原样传过去 App 会渲染成灰色占位
            //   （用户反馈：「推薦的 6 個視頻有時候會有幾個灰色的東西」）。
            {
                NSString *g = [it objectForKey:@"goto"];
                if ([g isKindOfClass:[NSString class]] && [g length] > 0 &&
                    ![g isEqualToString:@"av"] && ![g isEqualToString:@"video"]) {
                    BRDBG(@"[改写] feed 跳过非视频条目 goto=%@", g);
                    continue;
                }
                if ([it objectForKey:@"ad_info"] != nil) {
                    BRDBG(@"[改写] feed 跳过广告条目(ad_info)");
                    continue;
                }
                id isAd = [it objectForKey:@"is_ad"];
                if (isAd != nil && [isAd respondsToSelector:@selector(boolValue)] &&
                    [isAd boolValue]) {
                    BRDBG(@"[改写] feed 跳过广告条目(is_ad)");
                    continue;
                }
            }

            // ★ 新版把 aid 放在 id 字段，不是 aid
            id aidRaw = [it objectForKey:@"id"];
            if (aidRaw == nil) aidRaw = [it objectForKey:@"aid"];
            long long aidLL = 0;
            if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
            else if ([aidRaw isKindOfClass:[NSString class]]) aidLL = [(NSString *)aidRaw longLongValue];
            long long fakeAidLL = [BRStore fakeAidForReal:aidLL];
            NSNumber *fakeAid = (fakeAidLL > 0) ? @(fakeAidLL) : nil;

            NSString *pic  = BRPicFix([it objectForKey:@"pic"] ?: [it objectForKey:@"pic_4_3"] ?: @"");
            NSString *face = BRPicFix([owner objectForKey:@"face"] ?: @"");
            id dm = [stat objectForKey:@"danmaku"];
            // ★★★ uri 必须用 App 原生 scheme，绝不能用上游给的网页地址！
            //   上游 URI 形如 https://www.bilibili.com/video/BVxxx ——
            //   带上它 App 会去开「新版网页播放器」，而不是客户端的
            //   简介/评论/播放页（用户反馈：「點進去是新版的網頁播放器」）。
            NSString *uri = nil;
            if (fakeAid != nil)
                uri = [NSString stringWithFormat:@"bilibili://video/%@", fakeAid];
            if (uri == nil) uri = @"";

            [out addObject:@{
                @"goto":        [it objectForKey:@"goto"] ?: @"av",
                @"card_type":   [it objectForKey:@"card_type"] ?: @"small_cover_v2",
                @"card_goto":   [it objectForKey:@"card_goto"] ?: @"av",
                @"param":       fakeAid ? [NSString stringWithFormat:@"%@", fakeAid] : @"",
                @"uri":         uri ?: @"",
                @"id":          fakeAid ?: [NSNull null],
                @"aid":         fakeAid ?: [NSNull null],
                // ★ 同上：bvid 留空，避免与虚拟化后的 aid 不一致导致 int32 溢出
                @"bvid":        @"",
                // ★ cid 也必须虚拟化：真实 cid 已 11 位，超 int32 上限，
                //   直接下发会溢出 → 整条数据被判无效丢弃 → 列表全空（百页）。
                @"cid":         [self fakeCid:[it objectForKey:@"cid"] forAid:aidRaw],
                @"title":       [it objectForKey:@"title"] ?: @"",
                @"cover":       pic,
                @"pic":         pic,
                @"author":      [owner objectForKey:@"name"] ?: @"",
                @"mid":         [owner objectForKey:@"mid"] ?: @0,
                @"face":        face,
                @"play":        [stat objectForKey:@"view"] ?: @0,
                @"danmaku":     dm ?: @0,
                @"video_review": dm ?: @0,
                @"favorites":   [stat objectForKey:@"favorite"] ?: @0,
                @"review":      [stat objectForKey:@"reply"] ?: @0,
                @"duration":    BRFmtDuration([it objectForKey:@"duration"]),
                @"pubdate":     [it objectForKey:@"pubdate"] ?: @0,
                @"create":      @"",
                @"description": @"",
                @"pages":       @1,
                @"track_id":    [it objectForKey:@"track_id"] ?: @"",
            }];
        }
        // ★ 容器：data / item / items 三个键都要给同一个数组
        NSDictionary *box = @{@"code": @0, @"message": @"0",
                              @"data": out, @"item": out, @"items": out,
                              @"num": @([out count])};

        // ★★★ 关键修正：首页是**卡片数组**，不是视频数组。
        //   依据：App 自带的 home_init/config（用户也确认：
        //   「首頁綜合推薦卡片 6 個視頻，然後會有各有 4 個視頻的分區推薦」）：
        //     {"code":0,"data":[
        //        {"type":"recommend","style":"medium","title":"热门焦点",
        //         "body":[6 个视频]}, ...
        //     ]}
        //   之前直接输出扁平视频数组 → App 在 data[0] 里找不到 type/body → 整页空白。
        {
            // ★ 推荐卡不带 param 字段：
            //   带上空 param 可能被 App 当成「可刷新」→ 卡片下面多出一个刷新键
            //   （用户反馈：「推薦那 6 個视頱 下面多了一個刷新鍵」）。
            // ★★★ App 的推荐卡固定渲染 6 个位置，
            //   过滤掉广告后不足 6 条会留下空白
            //   （用户反馈：「灰色的视頱沒了，但那裡變成一處空白」）。
            //   所以不足 6 条时，从其他分区借视频补齐。
            NSMutableArray *recBody = [NSMutableArray arrayWithArray:out];
            if ([recBody count] < 6) {
                NSArray *padRids = @[@"1", @"3", @"4", @"5", @"36", @"119"];
                for (NSString *pr in padRids) {
                    if ([recBody count] >= 6) break;
                    @try {
                        NSArray *pv = [BRRouter fetchRegionVideos:pr count:6];
                        for (id one in pv) {
                            if ([recBody count] >= 6) break;
                            [recBody addObject:one];
                        }
                    } @catch (NSException *e) { }
                }
                BRINFO(@"[改写] 推荐卡补齐至 %lu 条", (unsigned long)[recBody count]);
            }
            NSDictionary *recCard = @{
                @"type":  @"recommend",
                @"style": @"medium",
                @"title": @"热门焦点",
                @"body":  recBody
            };
            NSMutableArray *cards = [NSMutableArray array];
            [cards addObject:recCard];

            // ★★★ 补上分区推荐卡片。
            //   用户反馈「首页划不下去，只有推荐那 6 个」——
            //   因为 App 期望首页一次返回所有卡片（推荐 + 各分区），
            //   而现代接口只给视频列表，所以由插件自己补齐。
            // ★ 一级分区（首页分区卡片用这些）
            // ★ 防递归：若本 route 标了 nopartition（分区取数复用 feed 流水线时会标），
            //   就跳过补分区卡片，否则会无限递归。
            BOOL brNoPart = [[route.extra objectForKey:@"nopartition"] boolValue];
            NSArray *rids = brNoPart
                          ? (NSArray *)@[]
                          // ★ 只取 3 个分区：每个同步请求约 4 秒，
                          //   8 个会把首页卡 30 秒以上 → App 被看门狗杀掉
                          //   （用户截图：一直停在「正在玩命加载数据」）。
                          : (NSArray *)@[@"1", @"4", @"36"];
            for (NSString *r in rids) {
                @try {
                    NSArray *vs = [BRRouter fetchRegionVideos:r count:4];
                    if ([vs count] > 0) {
                        // ★★★ type 必须是 region！
                        //   用 recommend 的话 App 会把它当成「热门推荐」板块渲染
                        //   （用户反馈：「全是熱門推薦板塊」）。
                        //   老首页的分区推荐卡片用 region，靠 param(rid) 关联。
                        [cards addObject:@{
                            @"type":  @"region",
                            @"style": @"medium",
                            @"title": BRRegionNameForRid(r),
                            @"param": r,
                            @"body":  vs
                        }];
                        BRINFO(@"[改写] 已补分区卡片 type=region %@（%@）%lu 条",
                               r, BRRegionNameForRid(r), (unsigned long)[vs count]);
                    }
                } @catch (NSException *e) { }
            }

            NSMutableDictionary *fixed = [NSMutableDictionary dictionaryWithDictionary:box];
            [fixed setObject:cards forKey:@"data"];
            // [BRDUMPCARDS] 把最终交给 App 的卡片 JSON 写进日志
            //   （之前一直只看请求/响应日志，从没看过界面真正拿到的数据）
            @try {
                NSData *dj = [self dataFromJSON:fixed];
                if (dj != nil) {
                    NSUInteger n = MIN((NSUInteger)1600, [dj length]);
                    NSString *dh = [[NSString alloc] initWithData:
                        [dj subdataWithRange:NSMakeRange(0, n)] encoding:NSUTF8StringEncoding];
                    BRINFO(@"[BRDUMPCARDS] len=%lu head=%@", (unsigned long)[dj length],
                           [dh stringByReplacingOccurrencesOfString:@"\\n" withString:@" "]);
                }
            } @catch (NSException *e) { }
            BRINFO(@"[改写] feed 已包成卡片数组（共 %lu 张卡片，推荐 %lu 条）",
                   (unsigned long)[cards count], (unsigned long)[out count]);
            box = fixed;
        };
        BRINFO(@"[改写] feed 输出 %lu 条", (unsigned long)[out count]);
        {
            NSData *dbg = [self dataFromJSON:box];   // [BRDUMP]
            if (dbg != nil) {
                NSString *s = [[NSString alloc] initWithData:
                    [dbg subdataWithRange:NSMakeRange(0, MIN((NSUInteger)700, [dbg length]))]
                    encoding:NSUTF8StringEncoding];
                BRINFO(@"[feed转换结果] %@", s ?: @"(非UTF8)");
                return dbg;
            }
        }
        return [self dataFromJSON:box];
    }


    // ---------- 分区（UWP dynamic/child）----------
    if ([kind isEqualToString:@"region"] && [route.extra[@"uwp"] boolValue]) {
        NSMutableDictionary *o = [j mutableCopy];
        NSDictionary *d = [j objectForKey:@"data"];
        NSArray *src = [d isKindOfClass:[NSDictionary class]] ? [d objectForKey:@"new"] : nil;
        NSMutableArray *archives = [NSMutableArray array];
        if ([src isKindOfClass:[NSArray class]]) {
            for (NSDictionary *it in src) [archives addObject:[self legacyVideoFrom:it]];
        }
        o[@"data"] = @{@"archives": archives,
                       @"num": @([archives count]),
                       @"page": route.extra[@"pn"] ?: @1,
                       @"size": @([archives count])};
        o[@"list"] = archives;
        BRDBG(@"分区返回 %lu 条", (unsigned long)[archives count]);
        return [self dataFromJSON:[self fixImages:o]];
    }

    // ---------- 伪二级分区（搜索结果 → 分区结构）----------
    // [BR_UWP_REGION] UWP dynamic/child 的响应结构（data.new[]，字段名完全不同）
    if ([kind isEqualToString:@"region"] && [route.extra[@"uwp"] boolValue]) {
        NSDictionary *j = [self jsonFromData:body];
        NSArray *src = nil;
        id dd = [j objectForKey:@"data"];
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id nw = [dd objectForKey:@"new"];
            if ([nw isKindOfClass:[NSArray class]]) src = nw;
            else {
                id a = [dd objectForKey:@"archives"];
                if ([a isKindOfClass:[NSArray class]]) src = a;
            }
        }
        NSMutableArray *items = [NSMutableArray array];
        for (id raw in src) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *it = raw;
            // ★ aid 放在 param 字段里
            long long aidLL = 0;
            id aidRaw = [it objectForKey:@"param"];
            if (aidRaw == nil) aidRaw = [it objectForKey:@"aid"];
            if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
            long long fakeLL = [BRStore fakeAidForReal:aidLL];
            NSNumber *fake = (fakeLL > 0) ? @(fakeLL) : nil;
            id dm = [it objectForKey:@"danmaku"];

            [items addObject:@{
                @"aid":          fake ?: @0,
                @"bvid":         [it objectForKey:@"bvid"] ?: @"",
                @"title":        [it objectForKey:@"title"] ?: @"",
                @"pic":          BRPicFix([it objectForKey:@"cover"] ?: [it objectForKey:@"pic"] ?: @""),
                @"description":  [it objectForKey:@"desc"] ?: @"",
                @"author":       [it objectForKey:@"name"] ?: [it objectForKey:@"author"] ?: @"",
                @"face":         BRPicFix([it objectForKey:@"face"] ?: @""),
                @"mid":          [it objectForKey:@"mid"] ?: @0,
                @"play":         [it objectForKey:@"play"] ?: @0,
                @"video_review": dm ?: @0,
                @"danmaku":      dm ?: @0,
                @"review":       [it objectForKey:@"reply"] ?: @0,
                @"favorites":    [it objectForKey:@"favourite"] ?: @0,
                @"duration":     [it objectForKey:@"duration"] ?: @"",
                @"create":       [it objectForKey:@"pubdate"] ?: @"",
                @"typename":     [it objectForKey:@"rname"] ?: @"",
                @"rid":          [it objectForKey:@"rid"] ?: @0,
            }];
        }
        NSString *pnS = route.extra[@"pn"] ?: @"1";
        NSDictionary *box = @{@"code": @0, @"message": @"0",
                              @"data": @{@"archives": items, @"list": items,
                                         @"num": @([items count]), @"page": @([pnS intValue]),
                                         @"size": ([items count] ? @([items count]) : @20)},
                              @"list": items};
        BRINFO(@"[改写] UWP真分区输出 %lu 条 (rid=%@)", (unsigned long)[items count], route.extra[@"rid"] ?: @"?");
        return [self dataFromJSON:box];
    }

    // ================= 分区（照搬 5.9 参考实现 region_to_old / search_to_region）===
    // ★ 老 App 从 data.archives[] 取列表，并且**必须给 page / size**
    //   否则分页算不出来 → 排版错乱（用户实测反馈）。
    if ([kind isEqualToString:@"region"] || [kind isEqualToString:@"regiontag"]) {
        NSDictionary *j = [self jsonFromData:body];
        NSArray *arcs = nil;
        id dd = [j objectForKey:@"data"];
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id a = [dd objectForKey:@"archives"];
            if ([a isKindOfClass:[NSArray class]]) arcs = a;
            else {
                id l = [dd objectForKey:@"list"];
                if ([l isKindOfClass:[NSArray class]]) arcs = l;
            }
        }
        NSMutableArray *items = [NSMutableArray array];
        for (id raw in arcs) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *r = raw;
            NSDictionary *owner = [r objectForKey:@"owner"];
            if (![owner isKindOfClass:[NSDictionary class]]) owner = @{};
            NSDictionary *stat = [r objectForKey:@"stat"];
            if (![stat isKindOfClass:[NSDictionary class]]) stat = @{};

            long long aidLL = 0;
            id aidRaw = [r objectForKey:@"aid"];
            if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
            long long fakeLL = [BRStore fakeAidForReal:aidLL];
            NSNumber *fake = (fakeLL > 0) ? @(fakeLL) : nil;

            id play = [r objectForKey:@"play"];   if (play == nil) play = [stat objectForKey:@"view"];
            // [BRRANKLEGACY] 老介面（x/web-interface/ranking）的彈幕欄位叫
            //   video_review，不是 danmaku —— 少了這個 fallback 彈幕會顯示 0。
            id dm   = [r objectForKey:@"danmaku"];
            if (dm == nil) dm = [r objectForKey:@"video_review"];
            if (dm == nil) dm = [stat objectForKey:@"danmaku"];
            id author = [r objectForKey:@"author"]; if (author == nil) author = [owner objectForKey:@"name"];
            id mid    = [r objectForKey:@"mid"];    if (mid == nil) mid = [owner objectForKey:@"mid"];
            id face   = [r objectForKey:@"face"];   if (face == nil) face = [owner objectForKey:@"face"];
            id pub    = [r objectForKey:@"pubdate"]; if (pub == nil) pub = [r objectForKey:@"ctime"];

            [items addObject:@{
                @"aid":          fake ?: @0,
                @"bvid":         [r objectForKey:@"bvid"] ?: @"",
                @"title":        [r objectForKey:@"title"] ?: @"",
                @"pic":          BRPicFix([r objectForKey:@"pic"] ?: @""),
                @"author":       author ?: @"",
                @"mid":          mid ?: @0,
                @"face":         BRPicFix(face ?: @""),
                @"play":         play ?: @0,
                @"video_review": dm ?: @0,
                @"danmaku":      dm ?: @0,
                @"duration":     BRFmtDuration([r objectForKey:@"duration"]),
                @"pubdate":      pub ?: @0,
                @"typename":     [r objectForKey:@"tname"] ?: @"",
                // [BRTIDKEY] 二進位反查：typeid → 0 次、tid → 185 次。
                //   這個 App 讀的是 tid；而這裡是「新建字典」，上游的 tid
                //   不會被保留 → App 讀不到分區 id。兩個都發。
                @"tid":          [r objectForKey:@"tid"] ?: @0,
                @"typeid":       [r objectForKey:@"tid"] ?: @0,
                @"arcurl":       [NSString stringWithFormat:@"http://www.bilibili.com/video/av%lld", aidLL],
            }];
        }
        // ★ 关键：archives + list + num + pages + page + size 都要给
        NSDictionary *box = @{@"code": @0, @"message": @"0",
                              @"data": @{@"archives": items, @"list": items,
                                         @"num": @([items count]), @"pages": @1,
                                         @"page": @1, @"size": ([items count] ? @([items count]) : @20)},
                              @"list": items, @"archives": items};
        BRINFO(@"[改写] region 输出 %lu 条（含 page/size）", (unsigned long)[items count]);

        // [BRREGIONCARD] ★ 分区推荐卡片也要用「卡片数组」结构。
        //   依据：首页 6 个推荐视频用卡片数组后已正常显示，而分区卡片仍是空白，
        //   且 App 自带 home_init/config 里分区卡片的形状是：
        //     {"param":"13","type":"bangumi","style":"medium",
        //      "title":"番剧推荐","body":[4 个视频]}
        //   这里把同一批视频也包成一张卡片，并把 data 换成卡片数组。
        @try {
            NSArray *regItems = nil;
            if ([items isKindOfClass:[NSArray class]]) regItems = items;
            if (regItems == nil) {
                id dd = [box objectForKey:@"data"];
                if ([dd isKindOfClass:[NSDictionary class]]) {
                    id ar = [dd objectForKey:@"archives"];
                    if ([ar isKindOfClass:[NSArray class]]) regItems = ar;
                } else if ([dd isKindOfClass:[NSArray class]]) {
                    regItems = dd;
                }
            }
            // ★★★ 刷新时（pn>=2）不能再包卡片！
            //   App 点「换一换」时期望拿到普通视频列表来替换卡片内容，
            //   而我每次都返回一张新卡片 → 界面不更新。
            //   （日志证据：pn=1..5 都发了请求、数据也是新的，但界面不变）
            NSString *pnNow = [route.extra objectForKey:@"pn"];
            BOOL brIsRefresh = (pnNow != nil && [pnNow integerValue] >= 2);
            if (brIsRefresh && [regItems isKindOfClass:[NSArray class]]) {
                // ★ 只放 data（外加 archives 作兼容别名）。
                //   之前放了 data/archives/list/item/items 五个键，
                //   JSON 序列化会把同一份数组写 5 遍 → 体积翻倍
                //   （实测：27693 -> 51084 字节）。
                NSMutableDictionary *plain = [NSMutableDictionary dictionaryWithDictionary:box];
                [plain setObject:regItems forKey:@"data"];
                [plain setObject:regItems forKey:@"archives"];
                box = plain;
                BRINFO(@"[改写] region 刷新(pn=%@) → 返回普通列表 %lu 条",
                       pnNow, (unsigned long)[regItems count]);
            } else if ([regItems isKindOfClass:[NSArray class]]) {
                NSString *rtitle = route.note ?: @"推荐";
                // ★ 从改写后的 URL 里取出 rid（各分区卡片是单独请求的）
                NSString *rid2 = @"";
                @try {
                    NSString *u = route.url ?: @"";
                    NSRange rr = [u rangeOfString:@"rid="];
                    if (rr.location != NSNotFound) {
                        NSString *rest = [u substringFromIndex:rr.location + 4];
                        NSRange amp = [rest rangeOfString:@"&"];
                        rid2 = (amp.location == NSNotFound) ? rest
                                                            : [rest substringToIndex:amp.location];
                    }
                } @catch (NSException *e) { }
                // title 用真实分区名（App 自带 tidMetaV2.json 的映射）
                NSString *showTitle = [rid2 length] ? BRRegionNameForRid(rid2) : rtitle;
                NSDictionary *rc = @{
                    @"type":  @"recommend",
                    @"style": @"medium",
                    @"title": showTitle,
                    @"param": rid2,
                    @"body":  regItems
                };
                NSMutableDictionary *fx = [NSMutableDictionary dictionaryWithDictionary:box];
                [fx setObject:@[rc] forKey:@"data"];
                box = fx;
                BRINFO(@"[改写] region 已包成卡片数组（%@，body %lu 条）",
                       rtitle, (unsigned long)[regItems count]);
            }
        } @catch (NSException *e) { }
        return [self dataFromJSON:box];
    }


    // ---------- 分区（PGC 番剧）----------
    if ([kind isEqualToString:@"region"] && [route.extra[@"pgc"] boolValue]) {
        NSMutableDictionary *o = [j mutableCopy];
        NSDictionary *d = [j objectForKey:@"data"];
        NSArray *src = [d isKindOfClass:[NSDictionary class]] ? [d objectForKey:@"list"] : nil;
        NSMutableArray *archives = [NSMutableArray array];
        if ([src isKindOfClass:[NSArray class]]) {
            for (NSDictionary *it in src) {
                NSMutableDictionary *v = [self legacyVideoFrom:it];
                if (it[@"season_id"]) [v setObject:it[@"season_id"] forKey:@"season_id"];
                [archives addObject:v];
            }
        }
        o[@"data"] = @{@"archives": archives, @"num": @([archives count]), @"page": @1,
                       @"size": @([archives count])};
        o[@"list"] = archives;
        return [self dataFromJSON:[self fixImages:o]];
    }

    // ---------- 搜索：老客户端要顶层 list + page ----------
    // ================= 搜索（照搬 5.9 参考实现 search_to_old）=================
    // [BRSEARCH_RAW] 搜尋一律原樣透傳（理由見路由層註解）。
    //   保留原本的轉換器程式碼（以備日後需要），但不再執行。
    if ([kind isEqualToString:@"search"]) {
        BRINFO(@"[改写] search 原樣透傳（App 原生就能解析 data.items）");
        return body;
    }
    if (0 && [kind isEqualToString:@"search"]) {
        NSDictionary *j = [self jsonFromData:body];
        NSDictionary *dd = [j objectForKey:@"data"];
        NSArray *result = nil;
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id r = [dd objectForKey:@"result"];
            if ([r isKindOfClass:[NSArray class]]) result = r;
            // [BRFIXALL] ★ 真機診斷：裝置拿到的回應是 `data.items`，
            //   **沒有 data.result**（data 的鍵是 trackid,keyword,all_double_column,
            //   page,app_display_option,nav,items,exp_str,next,attribute）。
            //   所以兩個都要讀：items 可能是陣列，也可能是 {video:[...], media_bangumi:[...]}。
            if (result == nil) {
                id it = [dd objectForKey:@"items"];
                if ([it isKindOfClass:[NSArray class]]) {
                    result = it;
                } else if ([it isKindOfClass:[NSDictionary class]]) {
                    for (NSString *sub in @[@"video", @"media_bangumi", @"media_ft",
                                            @"live_room", @"live", @"article", @"up"]) {
                        id sv = [it objectForKey:sub];
                        if ([sv isKindOfClass:[NSArray class]] && [sv count] > 0) {
                            result = sv;
                            BRINFO(@"[改写] search 从 data.items.%@ 取到 %lu 条",
                                   sub, (unsigned long)[sv count]);
                            break;
                        }
                    }
                }
            }
        }
        // [BRSEARCHDIAG] ★ 診斷：把實際回應結構印出來。
        //   本地實測 /x/web-interface/search/type?search_type=video 會回
        //     data.result = 20 筆、每筆 type='video'
        //   但真機上「search 输出 0 条」→ 裝置拿到的結構與實測不同，
        //   所以直接把 頂層鍵 / data 型別 / data 的鍵 / result 筆數 全部印出來。
        @try {
            NSString *topKeys = [[j allKeys] componentsJoinedByString:@","];
            NSString *dType = dd ? NSStringFromClass([dd class]) : @"(nil)";
            NSString *dKeys = [dd isKindOfClass:[NSDictionary class]]
                ? [[dd allKeys] componentsJoinedByString:@","] : @"-";
            NSString *rType = result ? @"array" : @"(nil)";
            id r0 = ([result isKindOfClass:[NSArray class]] && [result count])
                ? [result objectAtIndex:0] : nil;
            NSString *r0Keys = [r0 isKindOfClass:[NSDictionary class]]
                ? [[r0 allKeys] componentsJoinedByString:@","] : @"-";
            BRINFO(@"[改写] search 诊断: body=%lu 顶层键=[%@] data型别=%@ data键=[%@] result=%@(%lu) 首项键=[%@]",
                   (unsigned long)[body length], topKeys, dType, dKeys, rType,
                   (unsigned long)([result isKindOfClass:[NSArray class]] ? [result count] : 0),
                   r0Keys);
        } @catch (NSException *e) { }
        NSMutableArray *videos = [NSMutableArray array];
        for (id raw in result) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *r = raw;
            NSString *ty = [r objectForKey:@"type"];
            if ([ty length] && ![ty isEqualToString:@"video"]) continue;
            id dm = [r objectForKey:@"danmaku"];
            if (dm == nil) dm = [r objectForKey:@"video_review"];
            long long aidLL = 0;
            id aidRaw = [r objectForKey:@"aid"];
            if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
            long long fakeLL = [BRStore fakeAidForReal:aidLL];
            NSNumber *fake = (fakeLL > 0) ? @(fakeLL) : nil;
            [videos addObject:@{
                @"type":         @"video",
                @"aid":          fake ?: @0,
                @"title":        BRStripEm([r objectForKey:@"title"]),
                @"pic":          BRPicFix([r objectForKey:@"pic"] ?: @""),
                @"description":  BRStripEm([r objectForKey:@"description"] ?: @""),
                @"author":       [r objectForKey:@"author"] ?: @"",
                @"mid":          [r objectForKey:@"mid"] ?: @0,
                @"duration":     [r objectForKey:@"duration"] ?: @"",
                @"play":         [r objectForKey:@"play"] ?: @0,
                @"video_review": dm ?: @0,
                @"danmaku":      dm ?: @0,
                @"create":       [r objectForKey:@"pubdate"] ?: [r objectForKey:@"create"] ?: @"",
                @"bvid":         [r objectForKey:@"bvid"] ?: @"",
                @"typename":     [r objectForKey:@"typename"] ?: @"",
                @"arcurl":       [r objectForKey:@"arcurl"] ?: @"",
            }];
        }
        long long totalPage = 0;
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id np = [dd objectForKey:@"numPages"];
            if ([np respondsToSelector:@selector(longLongValue)]) totalPage = [np longLongValue];
            if (totalPage <= 0) {
                id nr = [dd objectForKey:@"numResults"];
                if ([nr respondsToSelector:@selector(longLongValue)]) totalPage = [nr longLongValue] / 20 + 1;
            }
        }
        if (totalPage <= 0) totalPage = 1;
        // ★ 顶层 list + page（不要嵌在 data.items.video 里）
        // [BRDATAARRAY] 同上：data 必須是陣列（App 用 arrayValue 取值）。
        NSDictionary *box = @{@"code": @0, @"message": @"0",
                              @"list": videos, @"page": @(totalPage),
                              @"data": videos,
                              @"result": @{@"list": videos, @"page": @(totalPage)}};
        BRINFO(@"[改写] search 输出 %lu 条 / %lld 页", (unsigned long)[videos count], totalPage);
        return [self dataFromJSON:box];
    }


    // ---------- 视频详情 ----------
    // ================= 视频详情（照搬 5.9 参考实现 view_to_old）=================
    // App 会读顶层 data.author / mid / face / created / cid / page / part，
    // 而新接口把这些放在 data.owner 与 data.pages[0] 里 —— 不提升就会
    // 「code:0 但内容加载不出来」。
    if ([kind isEqualToString:@"view"]) {
        NSDictionary *j = [self jsonFromData:body];
        if (![j isKindOfClass:[NSDictionary class]]) return body;
        id dObj = [j objectForKey:@"data"];
        if (![dObj isKindOfClass:[NSDictionary class]]) return body;

        NSMutableDictionary *d = [dObj mutableCopy];
        NSDictionary *owner = [d objectForKey:@"owner"];
        if (![owner isKindOfClass:[NSDictionary class]]) owner = @{};

        if ([d objectForKey:@"author"] == nil && [owner objectForKey:@"name"] != nil)
            [d setObject:[owner objectForKey:@"name"] forKey:@"author"];
        if ([d objectForKey:@"mid"] == nil && [owner objectForKey:@"mid"] != nil)
            [d setObject:[owner objectForKey:@"mid"] forKey:@"mid"];
        if ([d objectForKey:@"face"] == nil && [owner objectForKey:@"face"] != nil)
            [d setObject:[owner objectForKey:@"face"] forKey:@"face"];
        if ([d objectForKey:@"created"] == nil && [d objectForKey:@"pubdate"] != nil)
            [d setObject:[d objectForKey:@"pubdate"] forKey:@"created"];
        // [BRTYPENAME] 二進位反查結果：
        //     @"typename"  → 0 次   （我原本只發這個 → App 不會讀 → 分類名空白）
        //     @"type_name" → 10 次  （BBPhoneVideoV2 的 ivar 就是 _type_name）
        //   所以兩個都發：type_name 是這個 App 真正讀的，typename 留作相容別名。
        if ([d objectForKey:@"tname"] != nil) {
            id tn = [d objectForKey:@"tname"];
            if ([d objectForKey:@"type_name"] == nil)
                [d setObject:tn forKey:@"type_name"];
            if ([d objectForKey:@"typename"] == nil)
                [d setObject:tn forKey:@"typename"];
        }

        id pages = [d objectForKey:@"pages"];
        if ([pages isKindOfClass:[NSArray class]] && [(NSArray *)pages count]) {
            id p0 = [(NSArray *)pages objectAtIndex:0];
            if ([p0 isKindOfClass:[NSDictionary class]]) {
                for (NSString *k in @[@"cid", @"page", @"part", @"type", @"from",
                                      @"vid", @"weblink", @"dimension"]) {
                    if ([d objectForKey:k] == nil && [p0 objectForKey:k] != nil)
                        [d setObject:[p0 objectForKey:k] forKey:k];
                }
            }
            if ([d objectForKey:@"videos"] == nil)
                [d setObject:@([(NSArray *)pages count]) forKey:@"videos"];
        }

        NSDictionary *stat = [d objectForKey:@"stat"];
        if ([stat isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in @[@"view", @"danmaku", @"reply", @"favorite",
                                  @"coin", @"share", @"like"]) {
                if ([d objectForKey:k] == nil && [stat objectForKey:k] != nil)
                    [d setObject:[stat objectForKey:k] forKey:k];
            }
        }

        if ([d objectForKey:@"aid"] == nil && [d objectForKey:@"avid"] != nil)
            [d setObject:[d objectForKey:@"avid"] forKey:@"aid"];
        if ([d objectForKey:@"desc"] == nil)
            [d setObject:([d objectForKey:@"dynamic"] ?: @"") forKey:@"desc"];
        if ([d objectForKey:@"state"] == nil)
            [d setObject:@0 forKey:@"state"];

        NSMutableDictionary *out = [j mutableCopy];
        [out setObject:d forKey:@"data"];
        BRINFO(@"[改写] view 已提升字段 (cid=%@ author=%@)",
               [d objectForKey:@"cid"] ?: @"?", [d objectForKey:@"author"] ?: @"?");
        return [self dataFromJSON:out];
    }


    // ---------- 播放地址：把 cid 换成真实值后原样返回 ----------
    // ================= 排行榜（照搬 5.9 参考实现 rank_to_old）=================
    if ([kind isEqualToString:@"list"]) {
        NSDictionary *j = [self jsonFromData:body];
        NSArray *lst = nil;
        id dd = [j objectForKey:@"data"];
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id l = [dd objectForKey:@"list"];
            if ([l isKindOfClass:[NSArray class]]) lst = l;
        } else if ([dd isKindOfClass:[NSArray class]]) {
            lst = dd;
        }
        NSMutableArray *items = [NSMutableArray array];
        for (id raw in lst) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *r = raw;
            NSDictionary *owner = [r objectForKey:@"owner"];
            if (![owner isKindOfClass:[NSDictionary class]]) owner = @{};
            NSDictionary *stat = [r objectForKey:@"stat"];
            if (![stat isKindOfClass:[NSDictionary class]]) stat = @{};

            long long aidLL = 0;
            id aidRaw = [r objectForKey:@"aid"];
            if ([aidRaw respondsToSelector:@selector(longLongValue)]) aidLL = [aidRaw longLongValue];
            long long fakeLL = [BRStore fakeAidForReal:aidLL];
            NSNumber *fake = (fakeLL > 0) ? @(fakeLL) : nil;

            id play = [r objectForKey:@"play"];   if (play == nil) play = [stat objectForKey:@"view"];
            id dm   = [r objectForKey:@"danmaku"]; if (dm == nil) dm = [stat objectForKey:@"danmaku"];
            id author = [r objectForKey:@"author"]; if (author == nil) author = [owner objectForKey:@"name"];
            id mid    = [r objectForKey:@"mid"];    if (mid == nil) mid = [owner objectForKey:@"mid"];
            id face   = [r objectForKey:@"face"];   if (face == nil) face = [owner objectForKey:@"face"];
            id pts    = [r objectForKey:@"score"];  if (pts == nil) pts = [r objectForKey:@"pts"];
            id pub    = [r objectForKey:@"pubdate"]; if (pub == nil) pub = [r objectForKey:@"ctime"];

            [items addObject:@{
                @"aid":          fake ?: @0,
                @"bvid":         [r objectForKey:@"bvid"] ?: @"",
                @"title":        [r objectForKey:@"title"] ?: @"",
                @"pic":          BRPicFix([r objectForKey:@"pic"] ?: @""),
                @"author":       author ?: @"",
                @"mid":          mid ?: @0,
                @"face":         BRPicFix(face ?: @""),
                @"play":         play ?: @0,
                @"video_review": dm ?: @0,
                @"danmaku":      dm ?: @0,
                @"coins":        [stat objectForKey:@"coin"] ?: @0,
                @"favorites":    [stat objectForKey:@"favorite"] ?: @0,
                @"like":         [stat objectForKey:@"like"] ?: @0,
                @"reply":        [stat objectForKey:@"reply"] ?: @0,
                @"duration":     BRFmtDuration([r objectForKey:@"duration"]),
                @"pubdate":      pub ?: @0,
                @"pts":          pts ?: @0,
                @"typename":     [r objectForKey:@"tname"] ?: @"",
                // [BRTIDKEY] 二進位反查：typeid → 0 次、tid → 185 次。
                //   這個 App 讀的是 tid；而這裡是「新建字典」，上游的 tid
                //   不會被保留 → App 讀不到分區 id。兩個都發。
                @"tid":          [r objectForKey:@"tid"] ?: @0,
                @"typeid":       [r objectForKey:@"tid"] ?: @0,
                @"arcurl":       [NSString stringWithFormat:@"http://www.bilibili.com/video/av%lld", aidLL],
            }];
        }
        NSDictionary *box = @{@"code": @0, @"message": @"0",
                              @"data": @{@"note": @"", @"list": items, @"num": @([items count]), @"pages": @1},
                              @"list": items, @"num": @([items count])};
        BRINFO(@"[改写] rank 输出 %lu 条", (unsigned long)[items count]);
        return [self dataFromJSON:box];
    }

    if ([kind isEqualToString:@"playurl"]) {
        NSMutableDictionary *o = [j mutableCopy];
        NSDictionary *d = [j objectForKey:@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *nd = [d mutableCopy];
            long long realCid = [route.extra[@"cid"] longLongValue];
            if (realCid > 0) nd[@"cid"] = @(realCid);
            // 老客户端读 durl[]，新接口可能只给 dash
            if (nd[@"durl"] == nil && nd[@"dash"] != nil) {
                // 有 durl 就不动；没有则保持原样（老客户端会走自己的降级逻辑）
            }
            o[@"data"] = nd;
        }
        return [self dataFromJSON:[self fixImages:o]];
    }

    // 其余类型（reply / list）原样返回，只补图片前缀
    return [self dataFromJSON:[self fixImages:j]] ?: body;
}

@end
