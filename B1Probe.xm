#import <Foundation/Foundation.h>
#import "BHelper.h"
%ctor { @autoreleasepool { BWrite(@"b1.txt", @"B1 已加载 —— 最小可加载单元"); } }