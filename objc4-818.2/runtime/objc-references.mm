/*
 * Copyright (c) 2004-2007 Apple Inc. All rights reserved.
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
/*
  Implementation of the weak / associative references for non-GC mode.
*/


#include "objc-private.h"
#include <objc/message.h>
#include <map>
#include "DenseMapExtras.h"

// expanded policy bits.

enum {
    OBJC_ASSOCIATION_SETTER_ASSIGN      = 0,
    OBJC_ASSOCIATION_SETTER_RETAIN      = 1,
    OBJC_ASSOCIATION_SETTER_COPY        = 3,            // NOTE:  both bits are set, so we can simply test 1 bit in releaseValue below.
    OBJC_ASSOCIATION_GETTER_READ        = (0 << 8),
    OBJC_ASSOCIATION_GETTER_RETAIN      = (1 << 8),
    OBJC_ASSOCIATION_GETTER_AUTORELEASE = (2 << 8),
    OBJC_ASSOCIATION_SYSTEM_OBJECT      = _OBJC_ASSOCIATION_SYSTEM_OBJECT, // 1 << 16
};

// 全局的自旋锁(互斥锁)
spinlock_t AssociationsManagerLock;

namespace objc {

class ObjcAssociation {
    uintptr_t _policy; // 关联策略
    id _value; // 关联值
public:
    // 构造函数,初始化列表初始化 policy 和 value
    ObjcAssociation(uintptr_t policy, id value) : _policy(policy), _value(value) {}
    // 构造函数,初始化列表, policy = 0,value = nil
    ObjcAssociation() : _policy(0), _value(nil) {}
    // 复制构造函数采用默认
    ObjcAssociation(const ObjcAssociation &other) = default;
    // 赋值操作符,采用默认
    ObjcAssociation &operator=(const ObjcAssociation &other) = default;
    // 和 other 交换 policy 和 value
    ObjcAssociation(ObjcAssociation &&other) : ObjcAssociation() {
        swap(other);
    }

    inline void swap(ObjcAssociation &other) {
        std::swap(_policy, other._policy);
        std::swap(_value, other._value);
    }
    
    // 内联函数,获取 policy
    inline uintptr_t policy() const { return _policy; }
    // 内联函数,获取 value
    inline id value() const { return _value; }

    // 在 setter 时使用,判断是否需要持有 value
    inline void acquireValue() {
        if (_value) {
            switch (_policy & 0xFF) {
            case OBJC_ASSOCIATION_SETTER_RETAIN:
                _value = objc_retain(_value);
                break;
            case OBJC_ASSOCIATION_SETTER_COPY:
                _value = ((id(*)(id, SEL))objc_msgSend)(_value, @selector(copy));
                break;
            }
        }
    }

    // 在 setter 时使用,与上面的 acquireValue 函数对应,释放旧值 value
    inline void releaseHeldValue() {
        if (_value && (_policy & OBJC_ASSOCIATION_SETTER_RETAIN)) {
            objc_release(_value);
        }
    }
    // 在 getter 的时候使用,根据关联策略判断是否对关联值进行 retain 操作
    inline void retainReturnedValue() {
        if (_value && (_policy & OBJC_ASSOCIATION_GETTER_RETAIN)) {
            objc_retain(_value);
        }
    }
    
    // 在 getter 时使用,根据关联策略判断是否需要把关联值放进自动释放池
    inline id autoreleaseReturnedValue() {
        if (slowpath(_value && (_policy & OBJC_ASSOCIATION_GETTER_AUTORELEASE))) {
            return objc_autorelease(_value);
        }
        return _value;
    }
};

// ObjectAssociationMap 是以const void *为 key,ObjcAssociation为 value的哈希表
typedef DenseMap<const void *, ObjcAssociation> ObjectAssociationMap;
// AssociationsHashMap 是以 DisguisedPtr<objc_object> 为 key,ObjectAssociationMap为 value 的哈希表.
// DisguisedPtr<objc_object> 可以理解为把 objc_object 地址变成一个证书.可以参考DisguisedPtr的注释
typedef DenseMap<DisguisedPtr<objc_object>, ObjectAssociationMap> AssociationsHashMap;

// class AssociationsManager manages a lock / hash table singleton pair.
// AssociationsManager 管理一个 lock/哈希表的单例pair
// Allocating an instance acquires the lock
// 分配实例获取锁

class AssociationsManager {
    // Convenience class for Dense Maps & Sets
    // template <typename Key, typename Value>
    // class ExplicitInitDenseMap : public ExplicitInit<DenseMap<Key, Value>> { };
    // Storage 模板类名
    using Storage = ExplicitInitDenseMap<DisguisedPtr<objc_object>, ObjectAssociationMap>;
    // 静态变量 _mapStorage,用于存储 AssociationsHashMap 数据
    static Storage _mapStorage;

public:
    // 构造函数,获取全局的 AssociationsManagerLock 加锁
    AssociationsManager()   { AssociationsManagerLock.lock(); }
    // 析构函数,获取全局的 AssociationsManagerLock 解锁
    ~AssociationsManager()  { AssociationsManagerLock.unlock(); }
    
    // 返回内部保存的 AssociationsHashMap
    AssociationsHashMap &get() {
        return _mapStorage.get();
    }
    
    // init 初始化函数实现,只是调用 storage 的 init 函数
    static void init() {
        _mapStorage.init();
    }
};

// 其实这里有点想不明白，明明 AssociationsManager 已经定义了公开函数 get 获取内部 _mapStorage 的数据，

// 为什么这里在类定义外面还写了这句代码 ？
AssociationsManager::Storage AssociationsManager::_mapStorage;

/*
 总结:
 1. 通过 AssociationsManager 的 get 函数获取一个全局唯一的 AssociationsHashMap
 2. 根据原始对象的 DisguisedPtr<objc_object> 从 AssociationsHashMap 获取 ObjectAssociationMap
 3. 根据指定的关联 key(const void *) 从 ObjectAssociationMap 获取 ObjcAssociation
 4. ObjcAssociation 的两个成员变量,保存对象的关联策略 _policy 和关联值 _value
 */
} // namespace objc

using namespace objc;

void
_objc_associations_init()
{
    AssociationsManager::init();
}

id
_object_get_associative_reference(id object, const void *key)
{
    // 局部变量
    ObjcAssociation association{};

    {
        // 创建 manager 临时变量，枷锁
        AssociationsManager manager;
        // 获取全局唯一的AssociationsHashMap
        AssociationsHashMap &associations(manager.get());
        // 从全局的 AssociationsHashMap 中取得对象对应的 ObjectAssociationMap
        AssociationsHashMap::iterator i = associations.find((objc_object *)object);
        if (i != associations.end()) {
            // 如果 ObjectAssociationMap 存在
            ObjectAssociationMap &refs = i->second;
            // 从 ObjectAssocationMap 中取得 key 对应的 ObjcAssociation
            ObjectAssociationMap::iterator j = refs.find(key);
            if (j != refs.end()) {
                // 如果存在
                association = j->second;
                // 根据关联策略判断是否需要对 _value 执行 retain 操作
                association.retainReturnedValue();
            }
        }
        // 解锁，销毁 manager
    }
    // 返回 _value 并根据关联策略判断是否需要放入自动释放池
    return association.autoreleaseReturnedValue();
}

void
_object_set_associative_reference(id object, const void *key, id value, uintptr_t policy)
{
    // This code used to work when nil was passed for object and key. Some code
    // probably relies on that to not crash. Check and handle it explicitly.
    // rdar://problem/44094390
    // 判断对象和关联值都为 nil，则返回
    if (!object && !value) return;
    
    // 判断当前类是否允许关联对象
    if (object->getIsa()->forbidsAssociatedObjects())
        _objc_fatal("objc_setAssociatedObject called on instance (%p) of class %s which does not allow associated objects", object, object_getClassName(object));
    
    // 伪装 objc_object 指针为 disguised
    DisguisedPtr<objc_object> disguised{(objc_object *)object};
    // 根据入参创建一个 ObjcAssociation
    ObjcAssociation association{policy, value};

    // retain the new value (if any) outside the lock.
    // 在入参之前根据根据关联策略判断是否是 retain/copy 入参 value
    association.acquireValue();

    bool isFirstAssociation = false;
    {
        // 创建 manager 临时变量
        // 这里还有一步连带操作
        // 在其构造函数中 AssociationsManagerLock.lock() 加锁
        AssociationsManager manager;
        // 获取全局的 AssociationsHashMap
        AssociationsHashMap &associations(manager.get());
        
        // 如果 value 存在
        if (value) {
            // 这里 DenseMap 对我们而言是一个黑盒，这里只要看 try_emplace 函数
            
            // 在全局 AssociationsHashMap 中尝试插入 <DisguisedPtr<objc_object>, ObjectAssociationMap>
            // 返回值类型是 std::pair<iterator, bool>
            auto refs_result = associations.try_emplace(disguised, ObjectAssociationMap{});
            // 如果新插入成功
            if (refs_result.second) {
                /* it's the first association we make */
                // 第一次建立 association
                // 用于设置 uintptr_t has_assoc : 1; 位，标记该对象存在关联对象
                isFirstAssociation = true;
            }

            /* establish or replace the association */
            // 重建或者替换 association
            auto &refs = refs_result.first->second;
            auto result = refs.try_emplace(key, std::move(association));
            if (!result.second) {
                // 替换
                // 如果之前有旧值的话把旧值的成员变量交换到 association
                // 然后在 函数执行结束时把旧值根据对应的策略判断执行 release
                association.swap(result.first->second);
            }
        } else {
            // value 为 nil 的情况，表示要把之前的关联对象置为 nil
            // 也可理解为移除指定的关联对象
            auto refs_it = associations.find(disguised);
            if (refs_it != associations.end()) {
                auto &refs = refs_it->second;
                auto it = refs.find(key);
                if (it != refs.end()) {
                    association.swap(it->second);
                    // 清除指定的关联对象
                    refs.erase(it);
                    // 如果当前 object 的关联对象为空了，则同时从全局的 AssociationsHashMap
                    // 中移除该对象
                    if (refs.size() == 0) {
                        associations.erase(refs_it);

                    }
                }
            }
        }
        // 析构 mananger 临时变量
        // 这里还有一步连带操作
        // 在其析构函数中 AssociationsManagerLock.unlock() 解锁
    }

    // Call setHasAssociatedObjects outside the lock, since this
    // will call the object's _noteAssociatedObjects method if it
    // has one, and this may trigger +initialize which might do
    // arbitrary stuff, including setting more associated objects.
    // 在锁之外调用 setHasAssociatedObjects，因为如果对象有一个，这将调用对象的
    // _noteAssociatedObjects 方法，这可能会触发 +initialize 可能会做任意事情，包括设置更多关联对象。
    // 如果是第一次建立关联关系，则设置 uintptr_t has_assoc : 1; 位，标记该对象存在关联对象
    if (isFirstAssociation)
        object->setHasAssociatedObjects();

    // release the old value (outside of the lock).
    // 开始时 retain 的是新入参的 value, 这里释放的是旧值，association 内部的 value 已经被替换了
    association.releaseHeldValue();
}

// Unlike setting/getting an associated reference,
// this function is performance sensitive because of
// raw isa objects (such as OS Objects) that can't track
// whether they have associated objects.
// 与 setting/getting 关联引用不同，此函数对性能敏感，
// 因为原始的 isa 对象（例如 OS 对象）无法跟踪它们是否具有关联的对象。
void
_object_remove_assocations(id object, bool deallocating)
{
    // 对象对应的 ObjectAssociationMap
    ObjectAssociationMap refs{};

    {
        // 创建临时变量 manager，枷锁
        AssociationsManager manager;
        // 从 manager 中获取全局唯一的AssociationsHashMap
        AssociationsHashMap &associations(manager.get());
        // 取得对象的对应 ObjectAssociationMap，里面包含所有的 (key, ObjcAssociation)
        AssociationsHashMap::iterator i = associations.find((objc_object *)object);
        if (i != associations.end()) {
            // 把 i->second 的内容都转入 refs 对象中
            refs.swap(i->second);

            // If we are not deallocating, then SYSTEM_OBJECT associations are preserved.
            // 如果我们不deallocating，则保留 SYSTEM_OBJECT 关联。
            bool didReInsert = false;
            // 如果不在 dealloc, 也就是对象不在释放的情况下
            if (!deallocating) {
                //  遍历对象对应的关联对象哈希表中所有的 ObjcAssociation
                for (auto &ref: refs) {
                    // ref.second是ObjcAssociation类型对象{policy, value}
                    // 这里是比对关联策略释放,如果当前策略是OBJC_ASSOCIATION_SYSTEM_OBJECT
                    if (ref.second.policy() & OBJC_ASSOCIATION_SYSTEM_OBJECT) {
                        // 重新将关联策略是OBJC_ASSOCIATION_SYSTEM_OBJECT的对象插入
                        i->second.insert(ref);
                        didReInsert = true;
                    }
                }
            }
            // 如果没有重新插入关联策略为OBJC_ASSOCIATION_SYSTEM_OBJECT的对象
            if (!didReInsert)
                // 从全局 AssociationsHashMap 移除对象的 ObjectAssociationMap
                associations.erase(i);
        }
    }

    // Associations to be released after the normal ones.
    // 巧妙的设计：laterRefs起到释放association缓冲作用。
    // 若当前正在释放association（忙不过来了），则将其它的association装入laterRefs向量中等待后续释放。
    SmallVector<ObjcAssociation *, 4> laterRefs;

    // release everything (outside of the lock).
    // 遍历对象对应的关联对象哈希表中所有的ObjcAssociation类对象
    for (auto &i: refs) {
        // i.second是ObjcAssociation类型对象{policy, value}，且关联策略是OBJC_ASSOCIATION_SYSTEM_OBJECT
        if (i.second.policy() & OBJC_ASSOCIATION_SYSTEM_OBJECT) {
            // If we are not deallocating, then RELEASE_LATER associations don't get released.
            // 如果不调用deallocating，那么 RELEASE_LATER 关联就不会被释放。
            // 如果正在释放对象
            if (deallocating)
                // dealloc的时候，OBJC_ASSOCIATION_SYSTEM_OBJECT的关联对象，
                // 先放入laterRefs 稍后释放，否则不处理。
                laterRefs.append(&i.second);
        } else {
            // 释放非OBJC_ASSOCIATION_SYSTEM_OBJECT的关联对象
            i.second.releaseHeldValue();
        }
    }
    // 遍历上一步存入策略为OBJC_ASSOCIATION_SYSTEM_OBJECT的对象
    for (auto *later: laterRefs) {
        // dealloc 的情况下释放OBJC_ASSOCIATION_SYSTEM_OBJECT的关联对象
        later->releaseHeldValue();
    }
}
