//
//  BRRouter.h —— 路由与响应改写
//
//  职责：把已失效的旧接口映射到现行接口，并把新结构的响应用老客户端能吃的
//  结构返回。所有规则都来自之前代理版本里已经实测验证过的逻辑。
//

#import <Foundation/Foundation.h>

@interface BRRoute : NSObject
@property (nonatomic, copy)   NSString *url;          // 上游地址（nil = 原样转发）
@property (nonatomic, copy)   NSString *kind;         // 响应类型，决定怎么改写
@property (nonatomic, copy)   NSString *ua;           // 指定 UA（nil = Chrome 指纹）
@property (nonatomic, strong) NSDictionary *extra;    // 附加参数（pn/rid/tag 等）
@property (nonatomic, strong) NSDictionary *extraHeaders;
@property (nonatomic, copy)   NSString *extraCookie;
@property (nonatomic, assign) BOOL anonymous;         // 匿名请求（不发任何 Cookie）
@property (nonatomic, assign) BOOL drop;              // 直接丢弃
@property (nonatomic, copy)   NSString *note;         // 日志说明
@end

@interface BRRouter : NSObject

// 根据进来的请求决定上游 URL
+ (BRRoute *)routeForRequest:(NSURLRequest *)req;

// 把上游响应改写成老客户端期望的结构
+ (NSData *)convertResponse:(NSData *)body forRoute:(BRRoute *)route;

// ---- 供 handler 使用的工具 ----
+ (NSDictionary *)jsonFromData:(NSData *)d;
+ (NSData *)dataFromJSON:(id)obj;
+ (NSData *)gunzip:(NSData *)src;

// 由 Tweak.xm 在调用 convertResponse 前设置：原始响应是否 gzip
// [BRFILL_V2] gzip 旗标改成类方法，避免每个 hook 入口各自维护一个全局量
//   （之前只有同步路径会设置它 → 旗标会残留上一次请求的值）
// ★ 纯 C 函数，被 Tweak.xm（Objective-C++）引用 → 必须 extern "C"，
//   否则 C++ 名字修饰会与 BRRouter.m（纯 ObjC）导出的名字不一致 → dyld 崩溃。
#ifdef __cplusplus
extern "C" {
#endif
void  BRSetRespWasGzip(BOOL v);
BOOL  BRRespWasGzip(void);
#ifdef __cplusplus
}
#endif
// [BRLIVEX] 直播：一條房間 → 老客戶端 BiliLiveItem 的欄位
+ (NSDictionary *)brLiveRoomFromDict:(NSDictionary *)it;
// [BRLIVEX] 番劇時間表：pgc timeline → 舊欄位名（ep_id/ep_index/dayIndex…）
+ (NSDictionary *)brTimelineToOld:(NSDictionary *)j;
// [BRLIVEX] 番劇首頁：用 timeline + 索引拼出 BBPhoneBangumiHomeModel
+ (NSDictionary *)brBangumiHomeFromTimeline:(NSDictionary *)j
                                      index:(NSDictionary *)idx;

// [BRSTAT3] 把一条视频映射成 App 分区卡片期望的 6 字段
//   （title/cover/param/play/danmaku/finish，型别与 home_init/config 一致）。
//   play/danmaku 显式传入（ranking/region 的 play/video_review）；
//   传 nil 则从 stat.view / stat.danmaku 取（popular）。seen 用于跨源去重。
+ (NSDictionary *)brRegionElement:(NSDictionary *)it
                        playValue:(id)play
                     danmakuValue:(id)dm
                             seen:(NSMutableSet *)seen;
+ (NSNumber *)fakeCid:(id)cid forAid:(id)aid;
// 递归把 protocol-relative 的图片地址补上 http: 前缀
+ (id)fixImages:(id)obj;

@end
