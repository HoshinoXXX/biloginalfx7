#import "BRRouter.h"
#import "BRStore.h"
#import "BRSession.h"
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

@implementation BRRouter

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
        r.kind = @"search";
        // ★ 搜索接口必须用浏览器 UA（其它接口要用 App UA —— 要求正好相反）
        r.ua = [BRSession searchUA];
        r.note = @"搜索";
        return r;
    }

    // ================= 排行榜 =================
    if ([path hasPrefix:@"/index/rank/"] || [path isEqualToString:@"/x/v2/rank"] ||
        [path hasPrefix:@"/x/v2/rank"] || [path hasPrefix:@"/x/web-interface/ranking"]) {
        NSString *rid = qs[@"rid"] ?: @"0";
        if ([rid isEqualToString:@"all"]) rid = @"0";
        r.url = [NSString stringWithFormat:
                 @"https://api.bilibili.com/x/web-interface/ranking/v2?rid=%@&type=all", rid];
        r.kind = @"list";
        r.extra = @{@"listKey": @"list"};
        r.note = @"排行榜";
        return r;
    }

    // ================= 直播 =================
    if ([host hasPrefix:@"api.live.bilibili."] || [path hasPrefix:@"/xlive"]) {
        // 直播是 APP 签名体系，不要套 wbi
        r.url = [NSString stringWithFormat:@"https://%@%@?%@", host, path, rawQuery];
        r.kind = @"raw";
        r.note = @"直播";
        return r;
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
            r.kind = @"raw";
            r.note = @"直播列表（新接口）";
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

    // ---- 番剧时间表 ----
    if ([path hasPrefix:@"/pgc/web/timeline"] || [path hasPrefix:@"/x/v2/bangumi/timeline"]) {
        r.url = @"https://api.bilibili.com/pgc/web/timeline?types=1&before=6&after=6";
        r.kind = @"raw";
        r.note = @"番剧时间表";
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
        NSMutableString *u = [NSMutableString stringWithString:
                              @"https://api.bilibili.com/pgc/player/api/playurl?"];
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
            NSString *b = [NSString stringWithFormat:
                           @"https://api.bilibili.com/x/space/wbi/acc/info?mid=%@", mid];
            r.url = [BRSession wbiSignURL:b];
            r.kind = @"nav";
            r.note = @"个人主页信息";
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

    // ★ 一级分区：改用 UWP 客户端的专用通道 dynamic/child
    //   （接口与参数取自 UWP 3.5.0 的 Bibi.dll；newlist 现已泛化 ——
    //    rid=3 只返回无关的通用推荐，而本接口返回的确实是该分区的内容）
    long long ts = (long long)[[NSDate date] timeIntervalSince1970];
    r.url = [NSString stringWithFormat:
        @"https://app.bilibili.com/x/v2/region/dynamic/child"
        @"?build=6180000&channel=bilih5&mobi_app=win&platform=win"
        @"&rid=%@&tag_id=0&ts=%lld", rid, ts];
    r.kind = @"region";
    r.extra = @{@"uwp": @YES, @"pn": pn, @"rid": rid};
    r.note = [NSString stringWithFormat:@"一级分区(UWP rid=%@)", rid];
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
    // ★★★ 转换器开关（细粒度）：
    //   /tmp/br-noconv         关全部
    //   /tmp/br-noconv-<kind>  只关某一类（feed/search/rank/view/region/playurl）
    //   这样不重新编译就能逐个验证是哪个转换器的问题。
    // ★ 先做 ID 虚拟化（与结构无关，永远生效，防止 int32 溢出）
    {
        NSDictionary *jj = [self jsonFromData:body];
        if (jj != nil) {
            id v = [BRRouter virtualizeAids:jj];
            NSData *vd = [self dataFromJSON:v];
            if (vd != nil) body = vd;
        }
    }

    {
        if (BRConvOff(route.kind)) {
            BRDBG(@"[改写] 转换器被开关禁用: %@", route.kind);
            return body;
        }
    }

    NSString *kind = route.kind;
    if ([kind isEqualToString:@"danmaku"] || [kind isEqualToString:@"raw"]) return body;

    NSDictionary *j = [self jsonFromData:body];
    if (j == nil) return body;   // 不是 JSON（例如某些 XML）就原样返回

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
            NSString *uri = [it objectForKey:@"uri"];
            if (uri == nil && fakeAid != nil)
                uri = [NSString stringWithFormat:@"bilibili://video/%@", fakeAid];

            [out addObject:@{
                @"goto":        [it objectForKey:@"goto"] ?: @"av",
                @"card_type":   [it objectForKey:@"card_type"] ?: @"small_cover_v2",
                @"card_goto":   [it objectForKey:@"card_goto"] ?: @"av",
                @"param":       fakeAid ? [NSString stringWithFormat:@"%@", fakeAid] : @"",
                @"uri":         uri ?: @"",
                @"id":          fakeAid ?: [NSNull null],
                @"aid":         fakeAid ?: [NSNull null],
                @"bvid":        [it objectForKey:@"bvid"] ?: @"",
                @"cid":         [it objectForKey:@"cid"] ?: @0,
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
        BRINFO(@"[改写] feed 输出 %lu 条", (unsigned long)[out count]);
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
            id dm   = [r objectForKey:@"danmaku"]; if (dm == nil) dm = [stat objectForKey:@"danmaku"];
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
    if ([kind isEqualToString:@"search"]) {
        NSDictionary *j = [self jsonFromData:body];
        NSDictionary *dd = [j objectForKey:@"data"];
        NSArray *result = nil;
        if ([dd isKindOfClass:[NSDictionary class]]) {
            id r = [dd objectForKey:@"result"];
            if ([r isKindOfClass:[NSArray class]]) result = r;
        }
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
        NSDictionary *box = @{@"code": @0, @"message": @"0",
                              @"list": videos, @"page": @(totalPage),
                              @"data": @{@"list": videos, @"page": @(totalPage)}};
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
        if ([d objectForKey:@"typename"] == nil && [d objectForKey:@"tname"] != nil)
            [d setObject:[d objectForKey:@"tname"] forKey:@"typename"];

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
