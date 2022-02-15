/*
 * Copyright (c) 2019 Apple Inc.  All Rights Reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#ifndef DENSEMAPEXTRAS_H
#define DENSEMAPEXTRAS_H

#include "llvm-DenseMap.h"
#include "llvm-DenseSet.h"

namespace objc {

// We cannot use a C++ static initializer to initialize certain globals because
// libc calls us before our C++ initializers run. We also don't want a global
// pointer to some globals because of the extra indirection.
//
// ExplicitInit / LazyInit wrap doing it the hard way.
/*
 我们不能使用 C++ static initializer 来初始化某些全局变量，因为 libc 在 C++ initializers 调用之前调用了我们。
 因为额外的间接性,我们也不需要指向某些全局变量的全局指针。ExplicitInit / LazyInit 包装很难做到这一点。
 */
template <typename Type>
class ExplicitInit {
    // typedef unsigned char uint8_t 长度为 1 个字符的 int,实际类型是无符号的 char
    
    // alignas(Type) 表示 _storage 内存对齐方式通抽象类型Type
    // _storage 的长度为 sizeof(Type) 的 uint8_t 类型数组
    alignas(Type) uint8_t _storage[sizeof(Type)];

public:
    // 初始化
    template <typename... Ts>
    void init(Ts &&... Args) {
        new (_storage) Type(std::forward<Ts>(Args)...);
    }
    // 把_storage数组起始地址强制转化为Type *
    Type &get() {
        return *reinterpret_cast<Type *>(_storage);
    }
};

template <typename Type>
class LazyInit {
    // alignas(Type) 表示 _storage 内存对齐方式通抽象类型Type
    // _storage 的长度为 sizeof(Type) 的 uint8_t 类型数组
    alignas(Type) uint8_t _storage[sizeof(Type)];
    // 是否已经初始化过
    bool _didInit;

public:
    // 把_storage数组起始地址强制转化为Type *
    template <typename... Ts>
    Type *get(bool allowCreate, Ts &&... Args) {
        if (!_didInit) {
            if (!allowCreate) {
                return nullptr;
            }
            new (_storage) Type(std::forward<Ts>(Args)...);
            _didInit = true;
        }
        return reinterpret_cast<Type *>(_storage);
    }
};

// Convenience class for Dense Maps & Sets
template <typename Key, typename Value>
class ExplicitInitDenseMap : public ExplicitInit<DenseMap<Key, Value>> { };

template <typename Key, typename Value>
class LazyInitDenseMap : public LazyInit<DenseMap<Key, Value>> { };

template <typename Value>
class ExplicitInitDenseSet : public ExplicitInit<DenseSet<Value>> { };

template <typename Value>
class LazyInitDenseSet : public LazyInit<DenseSet<Value>> { };

} // namespace objc

#endif /* DENSEMAPEXTRAS_H */
