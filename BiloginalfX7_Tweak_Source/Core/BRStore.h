//
//  BRStore.h —— 32 位 ID 虚拟化（aid / cid / mid）
//
//  背景：老客户端的 model 里 avid / cid / mid 都是 int32，
//  而现代 aid 已 15 位、cid 已 11 位 —— 直接下发会**静默溢出**，
//  表现为「点进去是另一个视频」或「视频找不到了」。
//
//  做法：下发给 App 一个 int32 装得下的小数字（假 ID），
//  请求上游前再换回真 ID。双向映射持久化到 /var/mobile/bilifix/。
//

#import <Foundation/Foundation.h>

// 假 ID 段位。真实 aid 现阶段是 15 位，离 10 亿很远，用 10 亿起是安全的。
// ⚠️ 不要用 100 万段 —— 那个区间里有一大批真实老视频（av1000001 之类），
//    会把真实视频认成「映射丢失」，导致详情页打不开甚至串到别的视频。
#define BR_FAKE_AID_BASE   1000000000LL
#define BR_FAKE_CID_BASE   50000LL

// 老客户端用 2147483647 当「追番」伪合集 spid 和收藏页占位 aid，
// 假 ID 分配器绝不能撞上它。
#define BR_SENTINEL_ID     2147483647LL

@interface BRStore : NSObject

+ (void)load;
+ (void)flush;

// ---- aid ----
// 真 aid -> 假 aid（能塞进 int32 的老视频原样返回）
+ (long long)fakeAidForReal:(long long)realAid;
// 假 aid -> 真 aid（查不到且落在假区间时返回 0，表示「映射丢了，别当真 ID 用」）
+ (long long)realAidForFake:(long long)fakeAid;
// 判断某个值是否落在我们分配的假 ID 区间
+ (BOOL)looksLikeFakeAid:(long long)v;

// ---- cid ----
+ (long long)fakeCidForReal:(long long)realCid;
+ (long long)realCidForFake:(long long)fakeCid;

// ---- mid（UID 目前 10 亿量级未溢出，先预留同一套机制）----
+ (long long)fakeMidForReal:(long long)realMid;
+ (long long)realMidForFake:(long long)fakeMid;

// cid -> aid 反查（播放页只给 cid 时需要补 aid）
+ (void)rememberCid:(long long)cid forAid:(long long)aid;
+ (long long)aidForCid:(long long)cid;

@end
