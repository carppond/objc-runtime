//
//  main.m
//  test_objc
//
//  Created by YL on 2022/1/13.
//

#import <UIKit/UIKit.h>

int main(int argc, char * argv[]) {
    @autoreleasepool {
     
        id obj = [NSObject new];
        id obj2 = [NSObject new];
        printf("start tag\n");
        {
            __weak id weakPtr = obj; // 调用 objc_initWeak 进行 weak 变量初始化
            weakPtr = obj2; // 修改 weak 变量指向
        }
        // 除了这个右括号调用 objc_destroyWeak 函数进行 weak 销毁
        // 这里是 weak 变量销毁,并时不时 weak 变量指向的对象销毁
        
        printf("end tag\n"); //  ⬅️ 断点打在这里
    }
    return 0;
    
}
