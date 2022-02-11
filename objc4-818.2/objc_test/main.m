//
//  main.m
//  objc_test
//
//  Created by Yi Wang on 2021/5/7.
//

#import <Foundation/Foundation.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // insert code here...
        
        id obj = [NSObject new];
        __weak id weakPtr = obj; // 调用 objc_initWeak 进行 weak 变量初始化
        printf("start tag\n");
        {
            NSLog(@"%@", weakPtr);
        }
        printf("end tag\n"); //  ⬅️ 断点打在这里
    }
    return 0;
}
