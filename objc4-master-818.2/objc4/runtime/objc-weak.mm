/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
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

#include "objc-private.h"

#include "objc-weak.h"

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <libkern/OSAtomic.h>

/*
 用于获取weak_entry_t或 weak_table_t 的哈希数组当前分配的总容量.
 - 在 weak_entry_t 中,当对象的弱引用数量不超过 4 的时候,就使用 weak_referrer_t inline_referrers[WEAK_INLINE_COUNT]这个固定长度为 4 的数组存放 weak_referrer_他.当长度大于 4,就要使用 weak_referret_t *referrers这个哈希数组存放 weak_referent_t 数据.
 - weak_table_t的哈希数组初始化长度是 64,当存储占比超过 3/4 后,哈希数组会扩容为总容量的 2 倍,然后会把之前的数据重新哈希化存放到新空间.当一些数据从哈希数组中移除后,为了提高查找效率势必要对哈希数组的总长度做缩小操作,规则是当哈希数组总容量超过 1024且已使用部分少于总容量1/16 时,缩小为总容量的 1/8,缩小后同样会把原始数据重新哈希化存储到新空间.(缩小和扩展都是实用 calloc 函数开辟新空间,cache_t 扩容后是直接忽略旧数据,这里可以比较记忆).牢记以上只是针对 weak_table_t 的哈希数组而言.
 - 
 */
#define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)

static void append_referrer(weak_entry_t *entry, objc_object **new_referrer);

BREAKPOINT_FUNCTION(
    void objc_weak_error(void)
);

static void bad_weak_table(weak_entry_t *entries)
{
    _objc_fatal("bad weak table at %p. This may be a runtime bug or a "
                "memory error somewhere else.", entries);
}

/** 
 * Unique hash function for object pointers only. 唯一的哈希函数仅适用于对象指针
 * 
 * @param key The object pointer
 * 
 * @return Size unrestricted hash of pointer.
 *
 * 哈希函数,与 mask 做与操作,防止 index 越界
 * hash_pointer(referent) 调用通用的指针哈希函数，后面的 & weak_table->mask 位操作来确保得到的 begin 不会越界，同我们日常使用的取模操作（%）是一样的功能，只是改为了位操作，提升了效率。
 */
static inline uintptr_t hash_pointer(objc_object *key) {
    // 把指针强转化为 unsigned long,然后调用 ptr_hash 函数
    return ptr_hash((uintptr_t)key);
}

/** 
 * Unique hash function for weak object pointers only.
 * 
 * @param key The weak object pointer. 
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t w_hash_pointer(objc_object **key) {
    return ptr_hash((uintptr_t)key);
}

/** 
 * Grow the entry's hash table of referrers. Rehashes each
 * of the referrers.
 * 
 * @param entry Weak pointer hash set for a particular object.
 */
__attribute__((noinline, used))
static void grow_refs_and_insert(weak_entry_t *entry, 
                                 objc_object **new_referrer)
{
    ASSERT(entry->out_of_line());

    size_t old_size = TABLE_SIZE(entry);
    size_t new_size = old_size ? old_size * 2 : 8;

    size_t num_refs = entry->num_refs;
    weak_referrer_t *old_refs = entry->referrers;
    entry->mask = new_size - 1;
    
    entry->referrers = (weak_referrer_t *)
        calloc(TABLE_SIZE(entry), sizeof(weak_referrer_t));
    entry->num_refs = 0;
    entry->max_hash_displacement = 0;
    
    for (size_t i = 0; i < old_size && num_refs > 0; i++) {
        if (old_refs[i] != nil) {
            append_referrer(entry, old_refs[i]);
            num_refs--;
        }
    }
    // Insert
    append_referrer(entry, new_referrer);
    if (old_refs) free(old_refs);
}

/** 
 * Add the given referrer to set of weak pointers in this entry.
 * Does not perform duplicate checking (b/c weak pointers are never
 * added to a set twice). 
 *
 * @param entry The entry holding the set of weak pointers. 
 * @param new_referrer The new weak pointer to be added.
 */
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer)
{
    if (! entry->out_of_line()) {
        // Try to insert inline.
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == nil) {
                entry->inline_referrers[i] = new_referrer;
                return;
            }
        }

        // Couldn't insert inline. Allocate out of line.
        weak_referrer_t *new_referrers = (weak_referrer_t *)
            calloc(WEAK_INLINE_COUNT, sizeof(weak_referrer_t));
        // This constructed table is invalid, but grow_refs_and_insert
        // will fix it and rehash it.
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            new_referrers[i] = entry->inline_referrers[i];
        }
        entry->referrers = new_referrers;
        entry->num_refs = WEAK_INLINE_COUNT;
        entry->out_of_line_ness = REFERRERS_OUT_OF_LINE;
        entry->mask = WEAK_INLINE_COUNT-1;
        entry->max_hash_displacement = 0;
    }

    ASSERT(entry->out_of_line());

    if (entry->num_refs >= TABLE_SIZE(entry) * 3/4) {
        return grow_refs_and_insert(entry, new_referrer);
    }
    size_t begin = w_hash_pointer(new_referrer) & (entry->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (entry->referrers[index] != nil) {
        hash_displacement++;
        index = (index+1) & entry->mask;
        if (index == begin) bad_weak_table(entry);
    }
    if (hash_displacement > entry->max_hash_displacement) {
        entry->max_hash_displacement = hash_displacement;
    }
    weak_referrer_t &ref = entry->referrers[index];
    ref = new_referrer;
    entry->num_refs++;
}

/** 
 * Remove old_referrer from set of referrers, if it's present.
 * Does not remove duplicates, because duplicates should not exist. 
 * 
 * @todo this is slow if old_referrer is not present. Is this ever the case? 
 *
 * @param entry The entry holding the referrers.
 * @param old_referrer The referrer to remove. 
 */
static void remove_referrer(weak_entry_t *entry, objc_object **old_referrer)
{
    if (! entry->out_of_line()) {
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == old_referrer) {
                entry->inline_referrers[i] = nil;
                return;
            }
        }
        _objc_inform("Attempted to unregister unknown __weak variable "
                     "at %p. This is probably incorrect use of "
                     "objc_storeWeak() and objc_loadWeak(). "
                     "Break on objc_weak_error to debug.\n", 
                     old_referrer);
        objc_weak_error();
        return;
    }

    size_t begin = w_hash_pointer(old_referrer) & (entry->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (entry->referrers[index] != old_referrer) {
        index = (index+1) & entry->mask;
        if (index == begin) bad_weak_table(entry);
        hash_displacement++;
        if (hash_displacement > entry->max_hash_displacement) {
            _objc_inform("Attempted to unregister unknown __weak variable "
                         "at %p. This is probably incorrect use of "
                         "objc_storeWeak() and objc_loadWeak(). "
                         "Break on objc_weak_error to debug.\n", 
                         old_referrer);
            objc_weak_error();
            return;
        }
    }
    entry->referrers[index] = nil;
    entry->num_refs--;
}

/** 
 * Add new_entry to the object's table of weak references.
 * 添加 new_entry 到保存对象的 weak 变量地址的哈希表中
 * Does not check whether the referent is already in the table.
 * 不用刚检查引用对象是否已在表中
 */
// 把 weak_entry_t 添加到 weak_table_t -> weak_entries 中
static void weak_entry_insert(weak_table_t *weak_table, weak_entry_t *new_entry)
{
    // 哈希数组中的起始地址
    weak_entry_t *weak_entries = weak_table->weak_entries;
    ASSERT(weak_entries != nil);
    // 调用 hash_pointer 函数找到 new_entry 在 weak_table_t 的哈希数组中位置,可能会发生哈希冲突,&mask 的原理同上
    size_t begin = hash_pointer(new_entry->referent) & (weak_table->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (weak_entries[index].referent != nil) {
        // 如果发生哈希冲突,+1,继续向下探测
        index = (index+1) & weak_table->mask;
        // 如果 index 每次+1 加到值 == begin,还没有找到空位置,就触发bad_weak_table
        if (index == begin) bad_weak_table(weak_entries);
        
        // 记录偏移,用于更新 max_hash_displacemen
        hash_displacement++;
    }
    // new_entry 放入哈希数组
    weak_entries[index] = *new_entry;
    // 更新 num_entries
    weak_table->num_entries++;
    
    // 此操作正记录 weak_table_t 哈希数组发生哈希冲突时的最大偏移值
    if (hash_displacement > weak_table->max_hash_displacement) {
        weak_table->max_hash_displacement = hash_displacement;
    }
    
    /*
     综上,weak_entry_insert 函数可知 weak_resize 函数的整体作用,该函数对哈希数组长度进行扩大和缩小,
     首先根据 new_size 申请相应大小的内存,new_entries 指针指向这块新申请的内存.设置 weak_table 的 mask 为 new_size-1.
     此处 mask 的作用记录 weak_table 总容量的内存边界,此外 mask 还用于哈希函数中保证 index 不会发生哈希数组越界
     
     weak_table_t 的哈希数组可能会发生哈希碰撞,而 weak_table_t 使用了开放寻址法来处理碰撞.如果发生碰撞,
     将寻找相邻(如果已经到最尾端的话,则从头开始)的下一个空位.max_hash_displacement 记录当前 weak_table 发生过的最大的偏移值.辞职会在其他地方用到.例如: weak_entry_for_referent 函数,寻找给定的 referent 的弱引用表中的 entry 时如果在循环过程中 hash_displacement的值超过了weak_table->max_hash_displacement则表示,不存在要找到的 weak_entry_t
     */
}

// 扩大和缩小空间都会调用weak_resize公共函数,入参是 weak_table_t 和一个指定的长度
static void weak_resize(weak_table_t *weak_table, size_t new_size)
{
    // 这里是取得当前哈希数组的总长度
    // #define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)
    size_t old_size = TABLE_SIZE(weak_table);

    // 获取旧的 weak_entries 哈希数组的起始地址
    weak_entry_t *old_entries = weak_table->weak_entries;
    // 为新的 weak_entries 哈希数组申请指定长度的空间,并把起始地址返回
    // 内存空间总量为: nnew_size, sizeof(weak_entry_t)
    weak_entry_t *new_entries = (weak_entry_t *)
        calloc(new_size, sizeof(weak_entry_t));
    
    // 更新 mask
    weak_table->mask = new_size - 1;
    // 更新 hash 数组的起始地址
    weak_table->weak_entries = new_entries;
    // 最大哈希冲突偏移,默认 0
    weak_table->max_hash_displacement = 0;
    // 当前哈希数组的占用数量,默认 0
    weak_table->num_entries = 0;  // restored by weak_entry_insert below
    
    // 下面是把旧哈希数组中的数据重新哈希化放进新空间
    // 然后上面的默认 0 的 weak_table_t 的两个成员变量会在下面的 weak_entery_insert 函数中更新
    
    // 如果有旧的 weak_entry_t 需要更新,放到新的空间中
    if (old_entries) {
        weak_entry_t *entry;
        // 旧哈希数组的末尾
        weak_entry_t *end = old_entries + old_size;
        // 循环调用 weak_entry_insert 把旧哈希数组中的 weak_entry_t 插入到新的哈希数组中
        for (entry = old_entries; entry < end; entry++) {
            if (entry->referent) {
                weak_entry_insert(weak_table, entry);
            }
        }
        // 释放旧哈希数组的内存空间
        free(old_entries);
    }
}

/*
 以 weak_table_t 位参数,调用 weak_grow_maybe 和 weak_compact_maybe 函数,
 用来当 weak_table_t 哈希数组过满 或者过空的情况下及时调整其长度,优化内存的使用效率,并提高哈希查找效率.
 这两个函数通过调用 weak_resize 函数来调整 weak_table_t 哈希数组的长度
 */
// Grow the given zone's table of weak references if it is full.
// 如果给定区域的弱引用表已满,则进行扩展
static void weak_grow_maybe(weak_table_t *weak_table)
{
    // 这里是取得当前哈希数组的总长度
    // #define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)
    // mask + 1 表示当前 weak_table 哈希数组的总长度
    size_t old_size = TABLE_SIZE(weak_table);

    // Grow if at least 3/4 full.
    // 如果目前哈希数组存储的 weak_entry_t 的数量超过了总长度的 3/4,则进行扩展
    if (weak_table->num_entries >= old_size * 3 / 4) {
        // 如果 weak_table的哈希数组总长度是 0,则初始化哈希数组的总长度位 64,如果不是,则扩容到之前长度的两倍(old_size*2)
        weak_resize(weak_table, old_size ? old_size*2 : 64);
    }
    
    /*
     该函数用于扩充 weak_table 的 weak_entry_t *weak_entries 的长度,扩充条件是 num_entries 超过了 mask +1 的 3/4.看到 weak_entries 的初始化长度是 64,每次扩充的长度则是 mask+1 的 2 倍,扩充完毕后会把原哈希数组中的 weak_entry_t 重新哈希化插入到新空间内,并更新 weak_table_t 各成员变量.占据的内存空间的总容量则是(mask+1) *size(weak_entry_t) 字节. 综上 mask + 1 总是 2 的 N 次方.(初始时 N 是 2^6,以后则是 N>=6)
     */
}

/*
 此函数会在weak_entry_remove 函数中调用,旨在 weak_entry_t 从 weak_table_t 的哈希数组中移除后,如果哈希数组中占用比较低的话,缩小 weak_entry_t *weak_entries 的长度,优化内存使用,同时提高哈希效率.,
 */
// Shrink the table if it is mostly empty.
// 即当 weak_table_t 的 weak_entry_t *weak_entries 数组大部分空间为空的情况下,所以 weak_entries 的长度
static void weak_compact_maybe(weak_table_t *weak_table)
{
    // 这里是取得当前哈希数组的总长度
    // #define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)
    size_t old_size = TABLE_SIZE(weak_table);

    // Shrink if larger than 1024 buckets and at most 1/16 full.
    // old_size 超过了 1024 并低于 1/16 的空间占用比率则进行缩小
    if (old_size >= 1024  && old_size / 16 >= weak_table->num_entries) {
        // 缩小容量位 old_size的 1/8
        weak_resize(weak_table, old_size / 8);
        // 缩小为 1/8 和上面的空间占用小余 1/16,两个条件合并到一起,保证缩小后的容量占用比小余 1/2
        // leaves new table no more than 1/2 full
    }
    
    /*
     缩小 weak_entry_t *weak_entries 的长度的条件是目前的总长度超过了 1024,并且容量占用比小余 1/16,weak_entries 空间缩小到当前空间的 1/8
     */
}


/**
 * Remove entry from the zone's table of weak references.
 */
static void weak_entry_remove(weak_table_t *weak_table, weak_entry_t *entry)
{
    // remove entry
    if (entry->out_of_line()) free(entry->referrers);
    bzero(entry, sizeof(*entry));

    weak_table->num_entries--;

    weak_compact_maybe(weak_table);
}


/** 
 * Return the weak reference table entry for the given referent. 
 * If there is no entry for referent, return NULL. 
 * Performs a lookup. 根据给定的 referent (对象变量)和weak_table_t 哈希表,查找其中的 weak_entry_t(存放所有指向 referent 的弱引用变量的地址的哈希表)并返回,如果未找到返回 NULL
 *
 *
 * @param weak_table 通过&SideTables()[referent] 可以从全局的 SideTables 中找到 referent 所处的 SideTable ->weak_table_t
 * @param referent The object. Must not be nil. 对象必须不能是 nil
 * 
 * @return The table of weak referrers to this object.  返回值是 weak_entry_t 指针,weak_entry_t 中保存了 referent 的所有弱引用变量的地址
 */
static weak_entry_t *
weak_entry_for_referent(weak_table_t *weak_table, objc_object *referent)
{
    ASSERT(referent);
    // weak_table_t 中哈希函数的入口
    weak_entry_t *weak_entries = weak_table->weak_entries;

    if (!weak_entries) return nil;
    // hash_pointer 哈希函数返回值与 mask 做与操作,防止 index 越界,这里的&mask操作很巧妙,后面会进行详细讲解
    size_t begin = hash_pointer(referent) & weak_table->mask;
    size_t index = begin;
    size_t hash_displacement = 0;
    
    // 如果未发生哈希冲突的话,这里 weak_table->weak_entries[index] 就是要找的weak_entry_t了
    while (weak_table->weak_entries[index].referent != referent) {
        // 如果发生了哈希冲突,+1 继续往下探测(开放寻址法
        index = (index+1) & weak_table->mask;
        // 如果 index 每次加 1 加到值等于 begin,还没有找到 weak_entry_t,则触发 bad_weak_table
        if (index == begin) bad_weak_table(weak_table->weak_entries);
        // 触发探测偏移了多远
        hash_displacement++;
        // 如果探测偏移超过 了weak_table 的 max_hash_displacement
        // 说明在 weak_table 中没有 referent 的 weak_entry_t,则直接返回nil
        if (hash_displacement > weak_table->max_hash_displacement) {
            return nil;
        }
    }
    // 到这里找到了 weak_entry_t,然后取出它 333 的地址并返回
    return &weak_table->weak_entries[index];
}

/** 
 * Unregister an already-registered weak reference.
 * This is used when referrer's storage is about to go away, but referent
 * isn't dead yet. (Otherwise, zeroing referrer later would be a
 * bad memory access.)
 * Does nothing if referent/referrer is not a currently active weak reference.
 * Does not zero referrer.
 * 
 * FIXME currently requires old referent value to be passed in (lame)
 * FIXME unregistration should be automatic if referrer is collected
 * 
 * @param weak_table The global weak table.
 * @param referent The object.
 * @param referrer The weak reference.
 *
 * 从弱引用表里移除一对(object, weak pointer).(从对象的 weak_entry_t 哈希表中移除一个 weak 变量的地址)
 */
void
weak_unregister_no_lock(weak_table_t *weak_table, id referent_id, 
                        id *referrer_id)
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id;

    weak_entry_t *entry;

    if (!referent) return;

    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        remove_referrer(entry, referrer);
        bool empty = true;
        if (entry->out_of_line()  &&  entry->num_refs != 0) {
            empty = false;
        }
        else {
            for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
                if (entry->inline_referrers[i]) {
                    empty = false; 
                    break;
                }
            }
        }

        if (empty) {
            weak_entry_remove(weak_table, entry);
        }
    }

    // Do not set *referrer = nil. objc_storeWeak() requires that the 
    // value not change.
}

/** 
 * Registers a new (object, weak pointer) pair. Creates a new weak
 * object entry if it does not exist.
 * 
 * @param weak_table The global weak table.
 * @param referent The object pointed to by the weak reference.
 * @param referrer The weak pointer address.
 * 添加一对(object, weak pointer)到弱引用表里. 当一个对象存在第一个指向它的 weiak 变量时,此时会把对象注册进 weak_table_t 的哈希表中,同时也会把这第一个 weak 变量的地址保存进对象的 weak_entry_t 哈希表中,如果这个 weak 变量不是第一个的话,表明这个对象此时已经存在于 weak_table_t 哈希表中,此时需要把这个指向它的 weak 变量的地址保存进该对象的 weak_entry_t 哈希表中
 */
id 
weak_register_no_lock(weak_table_t *weak_table, id referent_id, 
                      id *referrer_id, WeakRegisterDeallocatingOptions deallocatingOptions)
{
    objc_object *referent = (objc_object *)referent_id;
    objc_object **referrer = (objc_object **)referrer_id;

    if (referent->isTaggedPointerOrNil()) return referent_id;

    // ensure that the referenced object is viable
    if (deallocatingOptions == ReturnNilIfDeallocating ||
        deallocatingOptions == CrashIfDeallocating) {
        bool deallocating;
        if (!referent->ISA()->hasCustomRR()) {
            deallocating = referent->rootIsDeallocating();
        }
        else {
            // Use lookUpImpOrForward so we can avoid the assert in
            // class_getInstanceMethod, since we intentionally make this
            // callout with the lock held.
            auto allowsWeakReference = (BOOL(*)(objc_object *, SEL))
            lookUpImpOrForwardTryCache((id)referent, @selector(allowsWeakReference),
                                       referent->getIsa());
            if ((IMP)allowsWeakReference == _objc_msgForward) {
                return nil;
            }
            deallocating =
            ! (*allowsWeakReference)(referent, @selector(allowsWeakReference));
        }

        if (deallocating) {
            if (deallocatingOptions == CrashIfDeallocating) {
                _objc_fatal("Cannot form weak reference to instance (%p) of "
                            "class %s. It is possible that this object was "
                            "over-released, or is in the process of deallocation.",
                            (void*)referent, object_getClassName((id)referent));
            } else {
                return nil;
            }
        }
    }

    // now remember it and where it is being stored
    weak_entry_t *entry;
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        append_referrer(entry, referrer);
    } 
    else {
        weak_entry_t new_entry(referent, referrer);
        weak_grow_maybe(weak_table);
        weak_entry_insert(weak_table, &new_entry);
    }

    // Do not set *referrer. objc_storeWeak() requires that the 
    // value not change.

    return referent_id;
}

// 如果一个对象在弱引用表的某处,即该对象被保存都在弱引用表里(该对象存在弱引用),则返回 true
#if DEBUG
bool
weak_is_registered_no_lock(weak_table_t *weak_table, id referent_id) 
{
    return weak_entry_for_referent(weak_table, (objc_object *)referent_id);
}
#endif


/** 
 * Called by dealloc; nils out all weak pointers that point to the 
 * provided object so that they can no longer be used.
 * 
 * @param weak_table 
 * @param referent The object being deallocated.
 *
 * 当对象销毁的时候该函数会调用.设置所有剩余的__weak 变量指向 nil,此处正对应了我们日常挂在嘴边上的:__weak 变量在它指向的对象被销毁后它便会置为 nil 的机制
 */
void 
weak_clear_no_lock(weak_table_t *weak_table, id referent_id) 
{
    objc_object *referent = (objc_object *)referent_id;

    weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);
    if (entry == nil) {
        /// XXX shouldn't happen, but does with mismatched CF/objc
        //printf("XXX no entry for clear deallocating %p\n", referent);
        return;
    }

    // zero out references
    weak_referrer_t *referrers;
    size_t count;
    
    if (entry->out_of_line()) {
        referrers = entry->referrers;
        count = TABLE_SIZE(entry);
    } 
    else {
        referrers = entry->inline_referrers;
        count = WEAK_INLINE_COUNT;
    }
    
    for (size_t i = 0; i < count; ++i) {
        objc_object **referrer = referrers[i];
        if (referrer) {
            if (*referrer == referent) {
                *referrer = nil;
            }
            else if (*referrer) {
                _objc_inform("__weak variable at %p holds %p instead of %p. "
                             "This is probably incorrect use of "
                             "objc_storeWeak() and objc_loadWeak(). "
                             "Break on objc_weak_error to debug.\n", 
                             referrer, (void*)*referrer, (void*)referent);
                objc_weak_error();
            }
        }
    }
    
    weak_entry_remove(weak_table, entry);
}

