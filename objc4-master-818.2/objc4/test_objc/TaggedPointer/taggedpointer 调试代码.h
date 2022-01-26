//
//  taggedpointer 调试代码.h
//  objc
//
//  Created by YL on 2022/1/26.
//

#import "objc-internal.h"

#define NSLOG_NUMBER(x) printTaggedPointerNumber(x, @#x)
#define NSLOG_NUMBER1(x) printTaggedPointerNumber1(x, @#x)
void printTaggedPointerNumber(NSNumber *number, NSString *desc) {
    intptr_t maybeTagged = (intptr_t)number;
    if (maybeTagged >= 0LL) {
        NSLog(@"desc: %@ --not tagged pointer",desc);
        return;
    }
    intptr_t decoded = _objc_decodeTaggedPointer((__bridge const void * _Nullable)(number));
    NSLog(@"-- %@ - 0x%016lx", desc, decoded);
    //0x%016lx 打印16 进制
}

void printTaggedPointerNumber1(NSString *number, NSString *desc) {
    intptr_t maybeTagged = (intptr_t)number;
    if (maybeTagged >= 0LL) {
        NSLog(@"desc: %@ --not tagged pointer",desc);
        return;
    }
    intptr_t decoded = _objc_decodeTaggedPointer((__bridge const void * _Nullable)(number));
    NSLog(@"-- %@ - 0x%016lx", desc, decoded);
    //0x%016lx 打印16 进制
}
int main(int argc, char * argv[]) {
    
    NSLOG_NUMBER([NSNumber numberWithChar:1]);
    NSLOG_NUMBER([NSNumber numberWithUnsignedChar:1]);
    NSLOG_NUMBER([NSNumber numberWithShort:1]);
    NSLOG_NUMBER([NSNumber numberWithUnsignedShort:1]);
    NSLOG_NUMBER([NSNumber numberWithInt:1]);
    NSLOG_NUMBER([NSNumber numberWithUnsignedInt:1]);
    NSLOG_NUMBER([NSNumber numberWithInteger:1]);
    NSLOG_NUMBER([NSNumber numberWithUnsignedInteger:1]);
    NSLOG_NUMBER([NSNumber numberWithLong:1]);
    NSLOG_NUMBER([NSNumber numberWithUnsignedLong:1]);
    NSLOG_NUMBER([NSNumber numberWithLongLong:1]);
    NSLOG_NUMBER([NSNumber numberWithUnsignedLongLong:1]);
    NSLOG_NUMBER([NSNumber numberWithFloat:1]);
    NSLOG_NUMBER([NSNumber numberWithDouble:1]);
    
    NSLOG_NUMBER1([NSString stringWithFormat:@"a"]);
    
    printf("");
}
/**
 十六进制转换为二进制
   
 @param hex 十六进制数
 @return 二进制数
 */
 NSString *getBinaryByHex(NSString *hex) {
    
    NSMutableDictionary *hexDic = [[NSMutableDictionary alloc] initWithCapacity:16];
    [hexDic setObject:@"0000" forKey:@"0"];
    [hexDic setObject:@"0001" forKey:@"1"];
    [hexDic setObject:@"0010" forKey:@"2"];
    [hexDic setObject:@"0011" forKey:@"3"];
    [hexDic setObject:@"0100" forKey:@"4"];
    [hexDic setObject:@"0101" forKey:@"5"];
    [hexDic setObject:@"0110" forKey:@"6"];
    [hexDic setObject:@"0111" forKey:@"7"];
    [hexDic setObject:@"1000" forKey:@"8"];
    [hexDic setObject:@"1001" forKey:@"9"];
    [hexDic setObject:@"1010" forKey:@"A"];
    [hexDic setObject:@"1011" forKey:@"B"];
    [hexDic setObject:@"1100" forKey:@"C"];
    [hexDic setObject:@"1101" forKey:@"D"];
    [hexDic setObject:@"1110" forKey:@"E"];
    [hexDic setObject:@"1111" forKey:@"F"];
    
    NSString *binary = @"";
    for (int i=0; i<[hex length]; i++) {
        
        NSString *key = [hex substringWithRange:NSMakeRange(i, 1)];
        NSString *value = [hexDic objectForKey:key.uppercaseString];
        if (value) {
            
            binary = [binary stringByAppendingString:value];
        }
    }
    return binary;
}
/*
 值验证 1:
 NSString *str1 = [NSString stringWithFormat:@"a"];
 NSString *str2 = [NSString stringWithFormat:@"ab"];
 NSString *str3 = [NSString stringWithFormat:@"abc"];
 NSString *str4 = [NSString stringWithFormat:@"abccddf"];
 uintptr_t value1 = _objc_getTaggedPointerValue((__bridge void *)str1);
 uintptr_t value2 = _objc_getTaggedPointerValue((__bridge void *)str2);
 uintptr_t value3 = _objc_getTaggedPointerValue((__bridge void *)str3);
 uintptr_t value4 = _objc_getTaggedPointerValue((__bridge void *)str4);
 NSLog(@"value1: %lx", value1);
 NSLog(@"value1: %lx", value1);
 NSLog(@"value2: %lx", value2);
 NSLog(@"value3: %lx", value3);
 NSLog(@"value4: %lx", value4);
 
 值验证 2:
 NSNumber *number1 = [NSNumber numberWithInteger:1];
 NSNumber *number2 = [NSNumber numberWithInteger:23];
 NSNumber *number3 = [NSNumber numberWithInteger:33];

 uintptr_t value1 = _objc_getTaggedPointerValue((__bridge void *)number1);
 uintptr_t value2 = _objc_getTaggedPointerValue((__bridge void *)number2);
 uintptr_t value3 = _objc_getTaggedPointerValue((__bridge void *)number3);
 NSLog(@"value1: %lx", value1);
 NSLog(@"value2: %lx", value2);
 NSLog(@"value3: %lx", value3);
 */
