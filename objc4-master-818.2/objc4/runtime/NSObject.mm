/*
 * Copyright (c) 2010-2012 Apple Inc. All rights reserved.
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
#include "NSObject.h"

#include "objc-weak.h"
#include "DenseMapExtras.h"

#include <malloc/malloc.h>
#include <stdint.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <Block.h>
#include <map>
#include <execinfo.h>
#include "NSObject-internal.h"
//#include <os/feature_private.h>

extern "C" {
#include <os/reason_private.h>
#include <os/variant_private.h>
}

@interface NSInvocation
- (SEL)selector;
@end

OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_magic_offset  = __builtin_offsetof(AutoreleasePoolPageData, magic);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_next_offset   = __builtin_offsetof(AutoreleasePoolPageData, next);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_thread_offset = __builtin_offsetof(AutoreleasePoolPageData, thread);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_parent_offset = __builtin_offsetof(AutoreleasePoolPageData, parent);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_child_offset  = __builtin_offsetof(AutoreleasePoolPageData, child);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_depth_offset  = __builtin_offsetof(AutoreleasePoolPageData, depth);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_hiwat_offset  = __builtin_offsetof(AutoreleasePoolPageData, hiwat);
OBJC_EXTERN const uint32_t objc_debug_autoreleasepoolpage_begin_offset  = sizeof(AutoreleasePoolPageData);
#if __OBJC2__
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
OBJC_EXTERN const uintptr_t objc_debug_autoreleasepoolpage_ptr_mask = (AutoreleasePoolPageData::AutoreleasePoolEntry){ .ptr = ~(uintptr_t)0 }.ptr;
#else
OBJC_EXTERN const uintptr_t objc_debug_autoreleasepoolpage_ptr_mask = ~(uintptr_t)0;
#endif
OBJC_EXTERN const uint32_t objc_class_abi_version = OBJC_CLASS_ABI_VERSION_MAX;
#endif

/***********************************************************************
* Weak ivar support
**********************************************************************/

static id defaultBadAllocHandler(Class cls)
{
    _objc_fatal("attempt to allocate object of class '%s' failed", 
                cls->nameForLogging());
}

id(*badAllocHandler)(Class) = &defaultBadAllocHandler;

id _objc_callBadAllocHandler(Class cls)
{
    // fixme add re-entrancy protection in case allocation fails inside handler
    return (*badAllocHandler)(cls);
}

void _objc_setBadAllocHandler(id(*newHandler)(Class))
{
    badAllocHandler = newHandler;
}


static id _initializeSwiftRefcountingThenCallRetain(id objc);
static void _initializeSwiftRefcountingThenCallRelease(id objc);

explicit_atomic<id(*)(id)> swiftRetain{&_initializeSwiftRefcountingThenCallRetain};
explicit_atomic<void(*)(id)> swiftRelease{&_initializeSwiftRefcountingThenCallRelease};

static void _initializeSwiftRefcounting() {
    void *const token = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY | RTLD_LOCAL);
    ASSERT(token);
    swiftRetain.store((id(*)(id))dlsym(token, "swift_retain"), memory_order_relaxed);
    ASSERT(swiftRetain.load(memory_order_relaxed));
    swiftRelease.store((void(*)(id))dlsym(token, "swift_release"), memory_order_relaxed);
    ASSERT(swiftRelease.load(memory_order_relaxed));
    dlclose(token);
}

static id _initializeSwiftRefcountingThenCallRetain(id objc) {
  _initializeSwiftRefcounting();
  return swiftRetain.load(memory_order_relaxed)(objc);
}

static void _initializeSwiftRefcountingThenCallRelease(id objc) {
  _initializeSwiftRefcounting();
  swiftRelease.load(memory_order_relaxed)(objc);
}

namespace objc {
    extern int PageCountWarning;
}

namespace {

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
uint32_t numFaults = 0;
#endif

// The order of these bits is important.
#define SIDE_TABLE_WEAKLY_REFERENCED (1UL<<0)
#define SIDE_TABLE_DEALLOCATING      (1UL<<1)  // MSB-ward of weak bit
#define SIDE_TABLE_RC_ONE            (1UL<<2)  // MSB-ward of deallocating bit
#define SIDE_TABLE_RC_PINNED         (1UL<<(WORD_BITS-1))

#define SIDE_TABLE_RC_SHIFT 2
#define SIDE_TABLE_FLAG_MASK (SIDE_TABLE_RC_ONE-1)

struct RefcountMapValuePurgeable {
    static inline bool isPurgeable(size_t x) {
        return x == 0;
    }
};

// RefcountMap disguises its pointers because we 
// don't want the table to act as a root for `leaks`.
typedef objc::DenseMap<DisguisedPtr<objc_object>,size_t,RefcountMapValuePurgeable> RefcountMap;


// Template parameters. 模块参数
enum HaveOld { DontHaveOld = false, DoHaveOld = true }; // 是否有旧值
enum HaveNew { DontHaveNew = false, DoHaveNew = true }; // 是否有新值

/*
 struct SideTable定义在 NSObject.mm 中. 它管理了两块对开发者而言超级重要的内容, 一块是 RefcountMap refcnts 管理对象的引用计数;
 一块是 weak_table_t weak_table 管理对象的弱引用标量.refents 涉及的内容,暂时先不关注,着重看一下 weak_table 的内容
 */
struct SideTable {
    spinlock_t slock; // 每张SideTable表自带一把锁,而这把锁也对应了上面是抽象类型 T 必须为 StripedMap 提到的一些锁的接口函数
    RefcountMap refcnts; // 管理对象的引用计数
    weak_table_t weak_table; // 以 object ids为 keys,以 weak_entry_t 为 value 的哈希表,如果object ids有弱引用存在,则可从中找到对象的 weak_entry_t.

    // 构造函数,只做一件事,把 weak_table 的空间置为 0
    SideTable() {
        memset(&weak_table, 0, sizeof(weak_table));
    }
    // 析构函数(不能进行析构)
    ~SideTable() {
        // 看到 SideTable 是不能被析构的,如果进行析构则直接终止运行
        _objc_fatal("Do not delete SideTable.");
    }
    // 三个函数正对应了 StripeMap 中模板抽象类型 T 的接口要求,三个函数的内部都是直接调用 slock 的对应函数
    void lock() { slock.lock(); }
    void unlock() { slock.unlock(); }
    void forceReset() { slock.forceReset(); }

    // Address-ordered lock discipline for a pair of side tables.
    
    // HaveOld 和 HaveNew 分别表示 lock1 和 lock2 是否存在
    // 表示__weak 变量是否指向有旧值和目前要指向的新值
    
    // lock1 代表旧值对象所处的 SideTable
    // lock2 代表新值对象所处的 SideTable
    
    // lockTwo 是根据谁有值就调用谁的锁,触发加锁(c++方法重载)
    // 如果两个都有值,那么两个都加锁,并且根据谁低,先给谁加锁,然后另一个后加锁
    template<HaveOld, HaveNew> static void lockTwo(SideTable *lock1, SideTable *lock2);
    // 同上，对 slock 解锁
    template<HaveOld, HaveNew> static void unlockTwo(SideTable *lock1, SideTable *lock2);
};

/*
 struct SideTable 的结构很清晰:
 1. spinlock_t slock: 自旋锁,保证操作 SideTable 时的线程安全.看前面的两大块 weak_table_t 和 weak_entry_t 的时候,看到它们所有的操作函数都没有提及加解锁的事情,如果你仔细观察的话会发现它们的函数名后面都有一个 no_lock 的小微吗,正是用来提醒我们, 它们的操作完全并没有涉及到加锁.其实它们是把保证它们线程安全的任务交给了 SideTable,下面可以看到 SideTable 提供的函数都是线程安全的,而这都是由 slock 来完成的.
 2.RefcountMap refcnts: 以 DisguisedPtr<objc_object> 为 key,以 size_t 为 value 的哈希表,用来存储对象的引用计数.(仅在未使用 isa 优化或者 isa 优化情况下 isa_t 中保存的引用计数溢出时才会用到,这里涉及到 isa_t 里 uintptr has_sidetable_rc 和 uintptr extra_rc 两个字段,以前只是单纯的看 isa 的结构,到这里终于被用到了,还有这时候终于知道 rc 其实是 refcount(引用计数)的缩写). 作为哈希表,它使用的是平安探测法从哈希表中取值,而 weak_table_t 则是线性探测(开放寻址法).
 3.weak_table_t weak_table: 存储对象弱引用的哈希表,是 weak 功能实现的核心数据结构
 
 
 
 OS_UNFAIR_LOCK_AVAILABILITY
 typedef struct os_unfair_lock_s {
     uint32_t _os_unfair_lock_opaque;
 } os_unfair_lock, *os_unfair_lock_t;

 
 */
// lockTwo 和 unlockTwo的重载
template<>
void SideTable::lockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    spinlock_t::lockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::lockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    lock1->lock();
}

template<>
void SideTable::lockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    lock2->lock();
}

template<>
void SideTable::unlockTwo<DoHaveOld, DoHaveNew>
    (SideTable *lock1, SideTable *lock2)
{
    spinlock_t::unlockTwo(&lock1->slock, &lock2->slock);
}

template<>
void SideTable::unlockTwo<DoHaveOld, DontHaveNew>
    (SideTable *lock1, SideTable *)
{
    lock1->unlock();
}

template<>
void SideTable::unlockTwo<DontHaveOld, DoHaveNew>
    (SideTable *, SideTable *lock2)
{
    lock2->unlock();
}

/*
 SideTables 是一个类型是StripedMap<SideTable>的静态全局哈希.通过上面StripedMap的学习,
 已知在 iphone 下,它是固定长度为 8 的哈希数组,在 mac 下是固定长度为 64 的哈希数组,自带一个简单的哈希函数,
 根据 void*入参计算哈希值,然后根据哈希值取得哈希数组中对应的 T.
 SideTables 中则是取得的 T 是 SideTable
 */
// ExplicitInit 内部_storage 数组长度是: alignas(Type) uint8_t _storage[sizeof(Type)];
static objc::ExplicitInit<StripedMap<SideTable>> SideTablesMap;

static StripedMap<SideTable>& SideTables() {
    return SideTablesMap.get();
}

// anonymous namespace
};

/*
 SideTables() 下面定义了多个与锁相关的全局函数,内部实现是调用 StripeMap 的模板抽象类型 T 所支持的函数接口,
 对应 SideTables 的 T 类型是 SideTable, 而SideTable执行对应的函数时正式调用了它的spinlock_t slock成员变量的函数.
 这里采用了分离锁的机制,即一张 SideTable 一把锁,减轻并处理多个对象时阻塞压力.
 */
void SideTableLockAll() {
    SideTables().lockAll();
}

void SideTableUnlockAll() {
    SideTables().unlockAll();
}

void SideTableForceResetAll() {
    SideTables().forceResetAll();
}

void SideTableDefineLockOrder() {
    SideTables().defineLockOrder();
}

void SideTableLocksPrecedeLock(const void *newlock) {
    SideTables().precedeLock(newlock);
}

void SideTableLocksSucceedLock(const void *oldlock) {
    SideTables().succeedLock(oldlock);
}

void SideTableLocksPrecedeLocks(StripedMap<spinlock_t>& newlocks) {
    int i = 0;
    const void *newlock;
    while ((newlock = newlocks.getLock(i++))) {
        SideTables().precedeLock(newlock);
    }
}

void SideTableLocksSucceedLocks(StripedMap<spinlock_t>& oldlocks) {
    int i = 0;
    const void *oldlock;
    while ((oldlock = oldlocks.getLock(i++))) {
        SideTables().succeedLock(oldlock);
    }
}

// Call out to the _setWeaklyReferenced method on obj, if implemented.
static void callSetWeaklyReferenced(id obj) {
    if (!obj)
        return;

    Class cls = obj->getIsa();

    if (slowpath(cls->hasCustomRR() && !object_isClass(obj))) {
        ASSERT(((objc_class *)cls)->isInitializing() || ((objc_class *)cls)->isInitialized());
        void (*setWeaklyReferenced)(id, SEL) = (void(*)(id, SEL))
        class_getMethodImplementation(cls, @selector(_setWeaklyReferenced));
        if ((IMP)setWeaklyReferenced != _objc_msgForward) {
          (*setWeaklyReferenced)(obj, @selector(_setWeaklyReferenced));
        }
    }
}

//
// The -fobjc-arc flag causes the compiler to issue calls to objc_{retain/release/autorelease/retain_block}
//

id objc_retainBlock(id x) {
    return (id)_Block_copy(x);
}

//
// The following SHOULD be called by the compiler directly, but the request hasn't been made yet :-)
//

BOOL objc_should_deallocate(id object) {
    return YES;
}

id
objc_retain_autorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}


void
objc_storeStrong(id *location, id obj)
{
    id prev = *location;
    if (obj == prev) {
        return;
    }
    objc_retain(obj);
    *location = obj;
    objc_release(prev);
}


// 分析 storeWeak 函数源码实现：
// Update a weak variable.
// If HaveOld is true, the variable has an existing value 
//   that needs to be cleaned up. This value might be nil.
// If HaveNew is true, there is a new value that needs to be 
//   assigned into the variable. This value might be nil.
// If CrashIfDeallocating is true, the process is halted if newObj is 
//   deallocating or newObj's class does not support weak references. 
//   If CrashIfDeallocating is false, nil is stored instead.
/*
 更新一个 weak 变量.如果HaveOld为 true,则该 weak 变量需要清除现有值.该值可能为 nil.如果HaveNew为 true,则需要将一个新值分配给 weak
 变量.该值可能为 nil.如果CrashIfDeallocating为 true,如果 newObj 的 isa 已经被标记为deallocating或 newObj所有的类不支持弱引用,
 程序将 crash;如果CrashIfDeallocating为 false,则发生以上问题只是在 weak 变量中存入 nil 的时候
 */
enum CrashIfDeallocating { // 所属的类不支持弱引用，函数执行时会 crash，
    DontCrashIfDeallocating = false, DoCrashIfDeallocating = true
};

template <HaveOld haveOld, HaveNew haveNew,
          enum CrashIfDeallocating crashIfDeallocating>

static id 
storeWeak(id *location, objc_object *newObj)
{
    // 如果haveOld为假且haveNew也为假,表示没有新值也没有旧值,则执行断言
    ASSERT(haveOld  ||  haveNew);
    
    // 如果一开始就标识没有新值,切你的 newObj == nil 确实没有新值,则能正常执行函数,否则直接断言
    if (!haveNew) ASSERT(newObj == nil);

    // 指向 objc_class 的指针,指向 newObj的 Class,标记 newObj 的 Class 已经完成初始化
    Class previouslyInitializedClass = nil;
    // __weak 变量之前指向的旧对象
    id oldObj;
    
    // 这里有个疑问,对象是在什么时候放进 SideTable 中的
    
    // 旧值所处的 SideTable
    SideTable *oldTable;
    // 新值所处的 SideTable
    SideTable *newTable;

    // Acquire locks for old and new values.
    // Order by lock address to prevent lock ordering problems. 
    // Retry if the old value changes underneath us.
    
    // 取得旧值和新值所处的 SideTable 里面的spinlock_t.(SideTable->slock)
    // 根据上面两个锁的锁地址进行排序,以防止出现加锁时出现锁排序问题
    // 重试,如果旧值在下面函数执行过程中发生了改变
    // 这里用到 C 语言的 goto 语句,goto 语句可以直接跳到指定位置执行.(直接修改函数执行顺序)
 retry:
    if (haveOld) {
        // 如果有旧值,这个旧值表示是传进来的 weak 变量目前指向的对象
        // 解引用(*location)赋给oldObj
        oldObj = *location;
        // 取得旧值所处的SideTable
        oldTable = &SideTables()[oldObj];
    } else {
        // 如果 weak ptr 目前没有指向其他对象,则给oldTable赋值 nil
        oldTable = nil;
    }
    if (haveNew) {
        // 取得 newObj 所处的newTable
        newTable = &SideTables()[newObj];
    } else {
        // 没有新值,newObj 位 nil,newTable也赋值 nil
        newTable = nil;
    }
    // 这里根据haveOld和 haveNew 两个值,判断是否对 oldTable 和 newTable 这两个 SideTable 加锁
    
    // 加锁擦咯做,防止多线程中竞争冲突
    SideTable::lockTwo<haveOld, haveNew>(oldTable, newTable);

    // 此处*location 应该与 oldObj 保持一致,如果不同,说明在加锁之前*location 已被其他线程修改
    if (haveOld  &&  *location != oldObj) {
        // 解锁,跳转到 retry 处再重新执行函数
        SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
        goto retry;
    }

    // Prevent a deadlock between the weak reference machinery
    // and the +initialize machinery by ensuring that no 
    // weakly-referenced object has an un-+initialized isa.
    
    // 确保没有弱引用的对象具有未初始化的 isa
    // 防止 weak reference machinery 和 +initialize machinery 之间出现死锁
    
    // 有新值 haveNew 并且 newObj 不为 nil,判断 newObj 所属的类有没有初始化,如果没有初始化就进行初始化
    if (haveNew  &&  newObj) {
        // newObj所处的类
        Class cls = newObj->getIsa();
        // previouslyInitializedClass 记录正在进行初始化的类防止重复进入
        // 如果当前类没有初始化就初始化
        if (cls != previouslyInitializedClass  &&  
            !((objc_class *)cls)->isInitialized()) 
        {
            // 如果 cls 还没有初始化,先初始化,在尝试设置 weak
            
            // 解锁
            SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);
            // 调用对象所在类(不是元类)的初始化方法,即调用的是[newObj initlize] 类方法
            class_initialize(cls, (id)newObj);

            // If this class is finished with +initialize then we're good.
            // 如果这个 class 完成了 +initialize初始化,这对我们而言是一个好结果
            
            // If this class is still running +initialize on this thread 
            // (i.e. +initialize called storeWeak on an instance of itself)
            // then we may proceed but it will appear initializing and 
            // not yet initialized to the check above.
            // 如果这个类在这个线程中完成了+initialize的任务,那么这很好
            // 如果这个类还在这个线程中继续执行着+initialize任何,(比如这个类的实例在调用 storeWeak 方法,而 storeWeak 方法调用了+initialize).这样我们可以继续执行,但是上面它将进行初始化和尚未初始化的检查
            // 相反,在重试时设置previouslyInitializedClass位 newObj 的 class 来识别它
            // Instead set previouslyInitializedClass to recognize it on retry.
            //这里记录一下previouslyInitializedClass,防止该 if 分支再次进入
            previouslyInitializedClass = cls;

            goto retry;
        }
    }

    // Clean up old value, if any.
    // 清理旧值,如果有旧值,就进行weak_unregister_no_lock操作
    if (haveOld) {
        // 把 location 从 oldObj的 weak_entry_t 的哈希数组中移除
        weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
    }

    // Assign new value, if any.
    // 如果有新值,则执行weak_register_no_lock操作
    
    if (haveNew) {
        // 调用weak_register_no_lock方法把 weak ptr 的地址记录到 newObj 的 weak_entry_t 的哈希数组中
        // 如果newObj 的 isa 已经被标记为 deallocating 或 newObj 所属的类不支持弱引用,则weak_register_no_lock中会 crash
        newObj = (objc_object *)
            weak_register_no_lock(&newTable->weak_table, (id)newObj, location, 
                                  crashIfDeallocating ? CrashIfDeallocating : ReturnNilIfDeallocating);
        // weak_register_no_lock returns nil if weak store should be rejected

        // Set is-weakly-referenced bit in refcount table.
        
        /*
         设置一个对象有弱引用分为两种情况
         - 当对象的 isa 是有优化的 isa 时,更新 newObj 的 isa 的 weakly_referenced 标识位
         - 如果对象的 isa 是原始 class 指针时,它的引用计数和弱引用标识等信息都是在 refcount 中引用计数内.(不同的标识不同的信息)
            - 需要从 refcount 中找到对象的引用计数值(类型是 size_t),该引用计数值的第一位标识标识该对象是否有弱引用(SIDE_TABLE_WEAKLY_REFERENCED)
         
         */
        if (!newObj->isTaggedPointerOrNil()) {
            // 终于找到了,设置 struct objc_object 的 isa(isa_t)中 uintptr weakly_referenced : 1
            // 如果 isa 是原始指针时,设置 isa 最后一位是 1
            newObj->setWeaklyReferenced_nolock();
        }

        // Do not set *location anywhere else. That would introduce a race.
        // 请勿在其他地方设置*location,可能会引起竞争
        // *location 赋值,weak ptr 直接指向 newObj,可以看到这里并没有将 newObj 的引用计数+1
        *location = (id)newObj;
    }
    else {
        // No new value. The storage is not changed.
        // 没有新值,不发生改变
    }
    
    // 解锁,其他线程可以访问haveOld, haveNew了
    SideTable::unlockTwo<haveOld, haveNew>(oldTable, newTable);

    // This must be called without the locks held, as it can invoke
    // arbitrary code. In particular, even if _setWeaklyReferenced
    // is not implemented, resolveInstanceMethod: may be, and may
    // call back into the weak reference machinery.
    // 返回 new,此时的 newObj 与传入时相比,weakly_referenced 位被置为 1(如果开始就是 1,不发生改变)
    callSetWeaklyReferenced((id)newObj);

    return (id)newObj;
    /*
     storeWeak 实际上接收 5 个参数,其中 HaveOld haveOld, HaveNew haveNew, CrashIfDeallocating crashIfDeallocating
     这三个参数是以模板枚举的方式传入的,其实这是 3 个 bool 参数,具体到 objc_initweak 函数,这三个值分别为 false,true,true.因为是初始化 weak 变量必然有新值,没有旧值
     */
}


/** 
 * This function stores a new value into a __weak variable. It would
 * be used anywhere a __weak variable is the target of an assignment.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return \e newObj
 */
id
objc_storeWeak(id *location, id newObj)
{
    return storeWeak<DoHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * This function stores a new value into a __weak variable. 
 * If the new object is deallocating or the new object's class 
 * does not support weak references, stores nil instead.
 * 
 * @param location The address of the weak pointer itself
 * @param newObj The new object this weak ptr should now point to
 * 
 * @return The value stored (either the new object or nil)
 */
id
objc_storeWeakOrNil(id *location, id newObj)
{
    return storeWeak<DoHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object *)newObj);
}


/** 
 * Initialize a fresh weak pointer to some object location. 
 * It would be used for code like: 
 *
 * (The nil case) 
 * __weak id weakPtr;
 * (The non-nil case) 
 * NSObject *o = ...;
 * __weak id weakPtr = o;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 *
 * 初始化指向某个对象位置的新的 weak pointer（当旧 weak pointer 发生赋值（修改指向）时：首先对当前的指向进行清理工作）。对于 weak 变量的并发修改，此函数不是线程安全的。（并发进行 weak clear 是线程安全的（概念上可以理解为是并发读操作是线程安全的））
 *
 * @param location Address of __weak ptr.
 * __weak 变量的地址 (objc_object **) (ptr 是 pointer 的缩写，id 是 struct objc_object *)
 *
 * @param newObj Object ptr.  对象实例指针
 */
id
objc_initWeak(id *location, id newObj)
{
    // 如果对象不存在
    if (!newObj) {
        // 看到这个赋值用的是 *location,表示把__weak变量指向 nil,然后直接 return nil
        *location = nil;
        return nil;
    }

    /*
     storeWeak是一个模板函数,DontHaveOld表示没有旧值,表示这里是新初始化__weak变量.
     DoHaveNew表示有新值,新值即为newObj
     DoCrashIfDeallocating如果 newObj 的 isa 已经被标记为 deallocating 或者 newObj 所属的类不支持弱引用,则crash
     */
    return storeWeak<DontHaveOld, DoHaveNew, DoCrashIfDeallocating>
        (location, (objc_object*)newObj);
    /*
     objc_initWeak 函数接收两个参数:
     - id *location: __weak 变量的地址,即示例代码中 weak 变量取地址:&weakPtr,它是一个指针的指针,之所以要存储指针的指针,是因为 weak 变量指向的对象释放后,要把 weak 变量指向置为 nil,如果仅存指针(即 weak 变量所指向的地址值)的话,是不能够完成这个设置的.
        > 这里联想到对链表做一些操作时,函数入参会使链表头指针的指针
        > 这里如果对指针不是特别熟悉的话，可能会有一些迷糊，为什么用指针的指针，我们直接在函数内修改参数的指向时，不是同样也修改了外部指针的指向吗？其实非然！
     一定要理清，当函数形参是指针时，实参传入的是一个地址，然后在函数内部创建一个临时指针变量，这个临时指针变量指向的地址是实参传入的地址，此时如果你修改指向的话，修改的只是函数内部的临时指针变量的指向。外部的指针变量是与它无关的，有关的只是初始时它们两个指向的地址是一样的。而我们对这个地址里面内容的所有操作，都是可反应到指向该地址的指针变量那里的。这个地址是指针指向的地址，如果没有 `const`限制，我们可以对该地址里面的内容做任何操作即使把内容置空放0，这些操作都是对这个地址的内存做的，不管怎样这块内存都是存在的，它地址一直都在这里，而我们的原始指针一直就是指向它，此时我们需要的是修改原始指针的指向，那我们只有知道指针自身的地址才行，我们把指针自身的地址的内存空间里面放 `0x0`, 才能表示把我们的指针指向置为了 `nil`！
     - id newObj: 所用的的对象,即示例代码中的 obj
     
     该方法有一个返回值,返回的是 storeWeak 函数的返回值: 返回的其实还是 obj,但是已经对 obj 的 isa(isa_t)的 weakly_referenced
     位设置为 1,标识该对象有弱引用存在,当该对象销毁时,要处理指向它的那些弱引用,weak 变量被置为 nil的机制就是从这里实现的.
     
     看objc_initWeak函数的实现可知,它内部是调用 storeWeak 函数,且执行时的模板参数是DontHaveOld(没有旧值),这里实质 weakPtr 之前没有指向任何对象,我们的 weakPtr 是刚刚初始化的,自然没有指向旧值.这里涉及到的是,当 weak 变量改变指向时,要把该 weak 变量地址从它之前指向对象的 weak_entry_t哈希数组中移除.DoHaveNew表示有新值.
     
     
     storeWeak 函数实现的核心功能如下:
     - 将 weak 变量的地址 location 存入 obj 对应的 weak_entry_t 哈希数组(或定长为 4 的内部数组)中,用于在 obj 析构时,
       通过该weak_entry_t 哈希数组(或定长为 4 的内部数组)找到其所有的 weak 变量地址,将 weak 变量指向地址(*location)置为 nil
     - 如果启用了 isa 优化,则将 obj 的 isa_t 的 weakly_referenced 位置为 1,置为 1 的作用是标记该 obj 存在 weak 引用.当对象
        dealloc 时,runtime 会根据 weakly_referenced 标志位来判断是否需要查找 weak_entry_t,并将它的所有弱引用置为 nil
     
     __weak id weakPtr = obj 一句完整的白话理解就是:拿着 weakPtr 的地址和 obj,调用 objc_initWeak函数,把 weakPtr 的地址添加到 objc 的弱引用哈希表 weak_entry_t 的哈希数数组中.并把 obj 的地址赋给*location(*location = (id)newObj),然后把 obj 的 isa 的weakly_referenced字段置为 1,最后返回 obj.
     
     从 storeWeak 函数实现就要和前几篇内容连起来了,激动
     */
}

id
objc_initWeakOrNil(id *location, id newObj)
{
    if (!newObj) {
        *location = nil;
        return nil;
    }

    return storeWeak<DontHaveOld, DoHaveNew, DontCrashIfDeallocating>
        (location, (objc_object*)newObj);
}


/** 
 * Destroys the relationship between a weak pointer
 * and the object it is referencing in the internal weak
 * table. If the weak pointer is not referencing anything, 
 * there is no need to edit the weak table. 
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the weak variable. (Concurrent weak clear is safe.)
 * 
 * @param location The weak pointer address. 
 */
void
objc_destroyWeak(id *location)
{
    (void)storeWeak<DoHaveOld, DontHaveNew, DontCrashIfDeallocating>
        (location, nil);
}


/*
  Once upon a time we eagerly cleared *location if we saw the object 
  was deallocating. This confuses code like NSPointerFunctions which 
  tries to pre-flight the raw storage and assumes if the storage is 
  zero then the weak system is done interfering. That is false: the 
  weak system is still going to check and clear the storage later. 
  This can cause objc_weak_error complaints and crashes.
  So we now don't touch the storage until deallocation completes.
*/

id
objc_loadWeakRetained(id *location)
{
    id obj;
    id result;
    Class cls;

    SideTable *table;
    
 retry:
    // fixme std::atomic this load
    obj = *location;
    if (obj->isTaggedPointerOrNil()) return obj;
    
    table = &SideTables()[obj];
    
    table->lock();
    if (*location != obj) {
        table->unlock();
        goto retry;
    }
    
    result = obj;

    cls = obj->ISA();
    if (! cls->hasCustomRR()) {
        // Fast case. We know +initialize is complete because
        // default-RR can never be set before then.
        ASSERT(cls->isInitialized());
        if (! obj->rootTryRetain()) {
            result = nil;
        }
    }
    else {
        // Slow case. We must check for +initialize and call it outside
        // the lock if necessary in order to avoid deadlocks.
        // Use lookUpImpOrForward so we can avoid the assert in
        // class_getInstanceMethod, since we intentionally make this
        // callout with the lock held.
        if (cls->isInitialized() || _thisThreadIsInitializingClass(cls)) {
            BOOL (*tryRetain)(id, SEL) = (BOOL(*)(id, SEL))
                lookUpImpOrForwardTryCache(obj, @selector(retainWeakReference), cls);
            if ((IMP)tryRetain == _objc_msgForward) {
                result = nil;
            }
            else if (! (*tryRetain)(obj, @selector(retainWeakReference))) {
                result = nil;
            }
        }
        else {
            table->unlock();
            class_initialize(cls, obj);
            goto retry;
        }
    }
        
    table->unlock();
    return result;
}

/** 
 * This loads the object referenced by a weak pointer and returns it, after
 * retaining and autoreleasing the object to ensure that it stays alive
 * long enough for the caller to use it. This function would be used
 * anywhere a __weak variable is used in an expression.
 * 
 * @param location The weak pointer address
 * 
 * @return The object pointed to by \e location, or \c nil if \e location is \c nil.
 */
id
objc_loadWeak(id *location)
{
    if (!*location) return nil;
    return objc_autorelease(objc_loadWeakRetained(location));
}


/** 
 * This function copies a weak pointer from one location to another,
 * when the destination doesn't already contain a weak pointer. It
 * would be used for code like:
 *
 *  __weak id src = ...;
 *  __weak id dst = src;
 * 
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to the destination variable. (Concurrent weak clear is safe.)
 *
 * @param dst The destination variable.
 * @param src The source variable.
 */
void
objc_copyWeak(id *dst, id *src)
{
    id obj = objc_loadWeakRetained(src);
    objc_initWeak(dst, obj);
    objc_release(obj);
}

/** 
 * Move a weak pointer from one location to another.
 * Before the move, the destination must be uninitialized.
 * After the move, the source is nil.
 *
 * This function IS NOT thread-safe with respect to concurrent 
 * modifications to either weak variable. (Concurrent weak clear is safe.)
 *
 */
void
objc_moveWeak(id *dst, id *src)
{
    id obj;
    SideTable *table;

retry:
    obj = *src;
    if (obj == nil) {
        *dst = nil;
        return;
    }

    table = &SideTables()[obj];
    table->lock();
    if (*src != obj) {
        table->unlock();
        goto retry;
    }

    weak_unregister_no_lock(&table->weak_table, obj, src);
    weak_register_no_lock(&table->weak_table, obj, dst, DontCheckDeallocating);
    *dst = obj;
    *src = nil;
    table->unlock();
}


/***********************************************************************
   Autorelease pool implementation

   A thread's autorelease pool is a stack of pointers. 
   Each pointer is either an object to release, or POOL_BOUNDARY which is 
     an autorelease pool boundary.
   A pool token is a pointer to the POOL_BOUNDARY for that pool. When 
     the pool is popped, every object hotter than the sentinel is released.
   The stack is divided into a doubly-linked list of pages. Pages are added 
     and deleted as necessary. 
   Thread-local storage points to the hot page, where newly autoreleased 
     objects are stored. 
**********************************************************************/

BREAKPOINT_FUNCTION(void objc_autoreleaseNoPool(id obj));
BREAKPOINT_FUNCTION(void objc_autoreleasePoolInvalid(const void *token));

class AutoreleasePoolPage : private AutoreleasePoolPageData
{
	friend struct thread_data_t;

public:
	static size_t const SIZE =
#if PROTECT_AUTORELEASEPOOL
		PAGE_MAX_SIZE;  // must be multiple of vm page size
#else
		PAGE_MIN_SIZE;  // size and alignment, power of 2
#endif
    
private:
	static pthread_key_t const key = AUTORELEASE_POOL_KEY;
	static uint8_t const SCRIBBLE = 0xA3;  // 0xA3A3A3A3 after releasing
	static size_t const COUNT = SIZE / sizeof(id);
    static size_t const MAX_FAULTS = 2;

    // EMPTY_POOL_PLACEHOLDER is stored in TLS when exactly one pool is 
    // pushed and it has never contained any objects. This saves memory 
    // when the top level (i.e. libdispatch) pushes and pops pools but 
    // never uses them.
#   define EMPTY_POOL_PLACEHOLDER ((id*)1)

#   define POOL_BOUNDARY nil

    // SIZE-sizeof(*this) bytes of contents follow

    static void * operator new(size_t size) {
        return malloc_zone_memalign(malloc_default_zone(), SIZE, SIZE);
    }
    static void operator delete(void * p) {
        return free(p);
    }

    inline void protect() {
#if PROTECT_AUTORELEASEPOOL
        mprotect(this, SIZE, PROT_READ);
        check();
#endif
    }

    inline void unprotect() {
#if PROTECT_AUTORELEASEPOOL
        check();
        mprotect(this, SIZE, PROT_READ | PROT_WRITE);
#endif
    }

    void checkTooMuchAutorelease()
    {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        bool objcModeNoFaults = DisableFaults || getpid() == 1 ||
            !os_variant_has_internal_diagnostics("com.apple.obj-c");
        if (!objcModeNoFaults) {
            if (depth+1 >= (uint32_t)objc::PageCountWarning && numFaults < MAX_FAULTS) {  //depth is 0 when first page is allocated
                os_fault_with_payload(OS_REASON_LIBSYSTEM,
                        OS_REASON_LIBSYSTEM_CODE_FAULT,
                        NULL, 0, "Large Autorelease Pool", 0);
                numFaults++;
            }
        }
#endif
    }

	AutoreleasePoolPage(AutoreleasePoolPage *newParent) :
		AutoreleasePoolPageData(begin(),
								objc_thread_self(),
								newParent,
								newParent ? 1+newParent->depth : 0,
								newParent ? newParent->hiwat : 0)
    {
        if (objc::PageCountWarning != -1) {
            checkTooMuchAutorelease();
        }

        if (parent) {
            parent->check();
            ASSERT(!parent->child);
            parent->unprotect();
            parent->child = this;
            parent->protect();
        }
        protect();
    }

    ~AutoreleasePoolPage() 
    {
        check();
        unprotect();
        ASSERT(empty());

        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        ASSERT(!child);
    }

    template<typename Fn>
    void
    busted(Fn log) const
    {
        magic_t right;
        log("autorelease pool page %p corrupted\n"
             "  magic     0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  should be 0x%08x 0x%08x 0x%08x 0x%08x\n"
             "  pthread   %p\n"
             "  should be %p\n", 
             this, 
             magic.m[0], magic.m[1], magic.m[2], magic.m[3], 
             right.m[0], right.m[1], right.m[2], right.m[3], 
             this->thread, objc_thread_self());
    }

    __attribute__((noinline, cold, noreturn))
    void
    busted_die() const
    {
        busted(_objc_fatal);
        __builtin_unreachable();
    }

    inline void
    check(bool die = true) const
    {
        if (!magic.check() || thread != objc_thread_self()) {
            if (die) {
                busted_die();
            } else {
                busted(_objc_inform);
            }
        }
    }

    inline void
    fastcheck() const
    {
#if CHECK_AUTORELEASEPOOL
        check();
#else
        if (! magic.fastcheck()) {
            busted_die();
        }
#endif
    }


    id * begin() {
        return (id *) ((uint8_t *)this+sizeof(*this));
    }

    id * end() {
        return (id *) ((uint8_t *)this+SIZE);
    }

    bool empty() {
        return next == begin();
    }

    bool full() { 
        return next == end();
    }

    bool lessThanHalfFull() {
        return (next - begin() < (end() - begin()) / 2);
    }

    id *add(id obj)
    {
        ASSERT(!full());
        unprotect();
        id *ret;

#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        if (!DisableAutoreleaseCoalescing || !DisableAutoreleaseCoalescingLRU) {
            if (!DisableAutoreleaseCoalescingLRU) {
                if (!empty() && (obj != POOL_BOUNDARY)) {
                    AutoreleasePoolEntry *topEntry = (AutoreleasePoolEntry *)next - 1;
                    for (uintptr_t offset = 0; offset < 4; offset++) {
                        AutoreleasePoolEntry *offsetEntry = topEntry - offset;
                        if (offsetEntry <= (AutoreleasePoolEntry*)begin() || *(id *)offsetEntry == POOL_BOUNDARY) {
                            break;
                        }
                        if (offsetEntry->ptr == (uintptr_t)obj && offsetEntry->count < AutoreleasePoolEntry::maxCount) {
                            if (offset > 0) {
                                AutoreleasePoolEntry found = *offsetEntry;
                                memmove(offsetEntry, offsetEntry + 1, offset * sizeof(*offsetEntry));
                                *topEntry = found;
                            }
                            topEntry->count++;
                            ret = (id *)topEntry;  // need to reset ret
                            goto done;
                        }
                    }
                }
            } else {
                if (!empty() && (obj != POOL_BOUNDARY)) {
                    AutoreleasePoolEntry *prevEntry = (AutoreleasePoolEntry *)next - 1;
                    if (prevEntry->ptr == (uintptr_t)obj && prevEntry->count < AutoreleasePoolEntry::maxCount) {
                        prevEntry->count++;
                        ret = (id *)prevEntry;  // need to reset ret
                        goto done;
                    }
                }
            }
        }
#endif
        ret = next;  // faster than `return next-1` because of aliasing
        *next++ = obj;
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        // Make sure obj fits in the bits available for it
        ASSERT(((AutoreleasePoolEntry *)ret)->ptr == (uintptr_t)obj);
#endif
     done:
        protect();
        return ret;
    }

    void releaseAll() 
    {
        releaseUntil(begin());
    }

    void releaseUntil(id *stop) 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        
        while (this->next != stop) {
            // Restart from hotPage() every time, in case -release 
            // autoreleased more objects
            AutoreleasePoolPage *page = hotPage();

            // fixme I think this `while` can be `if`, but I can't prove it
            while (page->empty()) {
                page = page->parent;
                setHotPage(page);
            }

            page->unprotect();
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
            AutoreleasePoolEntry* entry = (AutoreleasePoolEntry*) --page->next;

            // create an obj with the zeroed out top byte and release that
            id obj = (id)entry->ptr;
            int count = (int)entry->count;  // grab these before memset
#else
            id obj = *--page->next;
#endif
            memset((void*)page->next, SCRIBBLE, sizeof(*page->next));
            page->protect();

            if (obj != POOL_BOUNDARY) {
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                // release count+1 times since it is count of the additional
                // autoreleases beyond the first one
                for (int i = 0; i < count + 1; i++) {
                    objc_release(obj);
                }
#else
                objc_release(obj);
#endif
            }
        }

        setHotPage(this);

#if DEBUG
        // we expect any children to be completely empty
        for (AutoreleasePoolPage *page = child; page; page = page->child) {
            ASSERT(page->empty());
        }
#endif
    }

    void kill() 
    {
        // Not recursive: we don't want to blow out the stack 
        // if a thread accumulates a stupendous amount of garbage
        AutoreleasePoolPage *page = this;
        while (page->child) page = page->child;

        AutoreleasePoolPage *deathptr;
        do {
            deathptr = page;
            page = page->parent;
            if (page) {
                page->unprotect();
                page->child = nil;
                page->protect();
            }
            delete deathptr;
        } while (deathptr != this);
    }

    static void tls_dealloc(void *p) 
    {
        if (p == (void*)EMPTY_POOL_PLACEHOLDER) {
            // No objects or pool pages to clean up here.
            return;
        }

        // reinstate TLS value while we work
        setHotPage((AutoreleasePoolPage *)p);

        if (AutoreleasePoolPage *page = coldPage()) {
            if (!page->empty()) objc_autoreleasePoolPop(page->begin());  // pop all of the pools
            if (slowpath(DebugMissingPools || DebugPoolAllocation)) {
                // pop() killed the pages already
            } else {
                page->kill();  // free all of the pages
            }
        }
        
        // clear TLS value so TLS destruction doesn't loop
        setHotPage(nil);
    }

    static AutoreleasePoolPage *pageForPointer(const void *p) 
    {
        return pageForPointer((uintptr_t)p);
    }

    static AutoreleasePoolPage *pageForPointer(uintptr_t p) 
    {
        AutoreleasePoolPage *result;
        uintptr_t offset = p % SIZE;

        ASSERT(offset >= sizeof(AutoreleasePoolPage));

        result = (AutoreleasePoolPage *)(p - offset);
        result->fastcheck();

        return result;
    }


    static inline bool haveEmptyPoolPlaceholder()
    {
        id *tls = (id *)tls_get_direct(key);
        return (tls == EMPTY_POOL_PLACEHOLDER);
    }

    static inline id* setEmptyPoolPlaceholder()
    {
        ASSERT(tls_get_direct(key) == nil);
        tls_set_direct(key, (void *)EMPTY_POOL_PLACEHOLDER);
        return EMPTY_POOL_PLACEHOLDER;
    }

    static inline AutoreleasePoolPage *hotPage() 
    {
        AutoreleasePoolPage *result = (AutoreleasePoolPage *)
            tls_get_direct(key);
        if ((id *)result == EMPTY_POOL_PLACEHOLDER) return nil;
        if (result) result->fastcheck();
        return result;
    }

    static inline void setHotPage(AutoreleasePoolPage *page) 
    {
        if (page) page->fastcheck();
        tls_set_direct(key, (void *)page);
    }

    static inline AutoreleasePoolPage *coldPage() 
    {
        AutoreleasePoolPage *result = hotPage();
        if (result) {
            while (result->parent) {
                result = result->parent;
                result->fastcheck();
            }
        }
        return result;
    }


    static inline id *autoreleaseFast(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page && !page->full()) {
            return page->add(obj);
        } else if (page) {
            return autoreleaseFullPage(obj, page);
        } else {
            return autoreleaseNoPage(obj);
        }
    }

    static __attribute__((noinline))
    id *autoreleaseFullPage(id obj, AutoreleasePoolPage *page)
    {
        // The hot page is full. 
        // Step to the next non-full page, adding a new page if necessary.
        // Then add the object to that page.
        ASSERT(page == hotPage());
        ASSERT(page->full()  ||  DebugPoolAllocation);

        do {
            if (page->child) page = page->child;
            else page = new AutoreleasePoolPage(page);
        } while (page->full());

        setHotPage(page);
        return page->add(obj);
    }

    static __attribute__((noinline))
    id *autoreleaseNoPage(id obj)
    {
        // "No page" could mean no pool has been pushed
        // or an empty placeholder pool has been pushed and has no contents yet
        ASSERT(!hotPage());

        bool pushExtraBoundary = false;
        if (haveEmptyPoolPlaceholder()) {
            // We are pushing a second pool over the empty placeholder pool
            // or pushing the first object into the empty placeholder pool.
            // Before doing that, push a pool boundary on behalf of the pool 
            // that is currently represented by the empty placeholder.
            pushExtraBoundary = true;
        }
        else if (obj != POOL_BOUNDARY  &&  DebugMissingPools) {
            // We are pushing an object with no pool in place, 
            // and no-pool debugging was requested by environment.
            _objc_inform("MISSING POOLS: (%p) Object %p of class %s "
                         "autoreleased with no pool in place - "
                         "just leaking - break on "
                         "objc_autoreleaseNoPool() to debug", 
                         objc_thread_self(), (void*)obj, object_getClassName(obj));
            objc_autoreleaseNoPool(obj);
            return nil;
        }
        else if (obj == POOL_BOUNDARY  &&  !DebugPoolAllocation) {
            // We are pushing a pool with no pool in place,
            // and alloc-per-pool debugging was not requested.
            // Install and return the empty pool placeholder.
            return setEmptyPoolPlaceholder();
        }

        // We are pushing an object or a non-placeholder'd pool.

        // Install the first page.
        AutoreleasePoolPage *page = new AutoreleasePoolPage(nil);
        setHotPage(page);
        
        // Push a boundary on behalf of the previously-placeholder'd pool.
        if (pushExtraBoundary) {
            page->add(POOL_BOUNDARY);
        }
        
        // Push the requested object or pool.
        return page->add(obj);
    }


    static __attribute__((noinline))
    id *autoreleaseNewPage(id obj)
    {
        AutoreleasePoolPage *page = hotPage();
        if (page) return autoreleaseFullPage(obj, page);
        else return autoreleaseNoPage(obj);
    }

public:
    static inline id autorelease(id obj)
    {
        ASSERT(!obj->isTaggedPointerOrNil());
        id *dest __unused = autoreleaseFast(obj);
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
        ASSERT(!dest  ||  dest == EMPTY_POOL_PLACEHOLDER  ||  (id)((AutoreleasePoolEntry *)dest)->ptr == obj);
#else
        ASSERT(!dest  ||  dest == EMPTY_POOL_PLACEHOLDER  ||  *dest == obj);
#endif
        return obj;
    }


    static inline void *push() 
    {
        id *dest;
        if (slowpath(DebugPoolAllocation)) {
            // Each autorelease pool starts on a new pool page.
            dest = autoreleaseNewPage(POOL_BOUNDARY);
        } else {
            dest = autoreleaseFast(POOL_BOUNDARY);
        }
        ASSERT(dest == EMPTY_POOL_PLACEHOLDER || *dest == POOL_BOUNDARY);
        return dest;
    }

    __attribute__((noinline, cold))
    static void badPop(void *token)
    {
        // Error. For bincompat purposes this is not 
        // fatal in executables built with old SDKs.

        if (DebugPoolAllocation || sdkIsAtLeast(10_12, 10_0, 10_0, 3_0, 2_0)) {
            // OBJC_DEBUG_POOL_ALLOCATION or new SDK. Bad pop is fatal.
            _objc_fatal
                ("Invalid or prematurely-freed autorelease pool %p.", token);
        }

        // Old SDK. Bad pop is warned once.
        static bool complained = false;
        if (!complained) {
            complained = true;
            _objc_inform_now_and_on_crash
                ("Invalid or prematurely-freed autorelease pool %p. "
                 "Set a breakpoint on objc_autoreleasePoolInvalid to debug. "
                 "Proceeding anyway because the app is old. Memory errors "
                 "are likely.",
                     token);
        }
        objc_autoreleasePoolInvalid(token);
    }

    template<bool allowDebug>
    static void
    popPage(void *token, AutoreleasePoolPage *page, id *stop)
    {
        if (allowDebug && PrintPoolHiwat) printHiwat();

        page->releaseUntil(stop);

        // memory: delete empty children
        if (allowDebug && DebugPoolAllocation  &&  page->empty()) {
            // special case: delete everything during page-per-pool debugging
            AutoreleasePoolPage *parent = page->parent;
            page->kill();
            setHotPage(parent);
        } else if (allowDebug && DebugMissingPools  &&  page->empty()  &&  !page->parent) {
            // special case: delete everything for pop(top)
            // when debugging missing autorelease pools
            page->kill();
            setHotPage(nil);
        } else if (page->child) {
            // hysteresis: keep one empty child if page is more than half full
            if (page->lessThanHalfFull()) {
                page->child->kill();
            }
            else if (page->child->child) {
                page->child->child->kill();
            }
        }
    }

    __attribute__((noinline, cold))
    static void
    popPageDebug(void *token, AutoreleasePoolPage *page, id *stop)
    {
        popPage<true>(token, page, stop);
    }

    static inline void
    pop(void *token)
    {
        AutoreleasePoolPage *page;
        id *stop;
        if (token == (void*)EMPTY_POOL_PLACEHOLDER) {
            // Popping the top-level placeholder pool.
            page = hotPage();
            if (!page) {
                // Pool was never used. Clear the placeholder.
                return setHotPage(nil);
            }
            // Pool was used. Pop its contents normally.
            // Pool pages remain allocated for re-use as usual.
            page = coldPage();
            token = page->begin();
        } else {
            page = pageForPointer(token);
        }

        stop = (id *)token;
        if (*stop != POOL_BOUNDARY) {
            if (stop == page->begin()  &&  !page->parent) {
                // Start of coldest page may correctly not be POOL_BOUNDARY:
                // 1. top-level pool is popped, leaving the cold page in place
                // 2. an object is autoreleased with no pool
            } else {
                // Error. For bincompat purposes this is not 
                // fatal in executables built with old SDKs.
                return badPop(token);
            }
        }

        if (slowpath(PrintPoolHiwat || DebugPoolAllocation || DebugMissingPools)) {
            return popPageDebug(token, page, stop);
        }

        return popPage<false>(token, page, stop);
    }

    static void init()
    {
        int r __unused = pthread_key_init_np(AutoreleasePoolPage::key, 
                                             AutoreleasePoolPage::tls_dealloc);
        ASSERT(r == 0);
    }

    __attribute__((noinline, cold))
    void print()
    {
        _objc_inform("[%p]  ................  PAGE %s %s %s", this, 
                     full() ? "(full)" : "", 
                     this == hotPage() ? "(hot)" : "", 
                     this == coldPage() ? "(cold)" : "");
        check(false);
        for (id *p = begin(); p < next; p++) {
            if (*p == POOL_BOUNDARY) {
                _objc_inform("[%p]  ################  POOL %p", p, p);
            } else {
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                AutoreleasePoolEntry *entry = (AutoreleasePoolEntry *)p;
                if (entry->count > 0) {
                    id obj = (id)entry->ptr;
                    _objc_inform("[%p]  %#16lx  %s  autorelease count %u",
                                 p, (unsigned long)obj, object_getClassName(obj),
                                 entry->count + 1);
                    goto done;
                }
#endif
                _objc_inform("[%p]  %#16lx  %s",
                             p, (unsigned long)*p, object_getClassName(*p));
             done:;
            }
        }
    }

    __attribute__((noinline, cold))
    static void printAll()
    {
        _objc_inform("##############");
        _objc_inform("AUTORELEASE POOLS for thread %p", objc_thread_self());

        AutoreleasePoolPage *page;
        ptrdiff_t objects = 0;
        for (page = coldPage(); page; page = page->child) {
            objects += page->next - page->begin();
        }
        _objc_inform("%llu releases pending.", (unsigned long long)objects);

        if (haveEmptyPoolPlaceholder()) {
            _objc_inform("[%p]  ................  PAGE (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
            _objc_inform("[%p]  ################  POOL (placeholder)", 
                         EMPTY_POOL_PLACEHOLDER);
        }
        else {
            for (page = coldPage(); page; page = page->child) {
                page->print();
            }
        }

        _objc_inform("##############");
    }

#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
    __attribute__((noinline, cold))
    unsigned sumOfExtraReleases()
    {
        unsigned sumOfExtraReleases = 0;
        for (id *p = begin(); p < next; p++) {
            if (*p != POOL_BOUNDARY) {
                sumOfExtraReleases += ((AutoreleasePoolEntry *)p)->count;
            }
        }
        return sumOfExtraReleases;
    }
#endif

    __attribute__((noinline, cold))
    static void printHiwat()
    {
        // Check and propagate high water mark
        // Ignore high water marks under 256 to suppress noise.
        AutoreleasePoolPage *p = hotPage();
        uint32_t mark = p->depth*COUNT + (uint32_t)(p->next - p->begin());
        if (mark > p->hiwat + 256) {
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
            unsigned sumOfExtraReleases = 0;
#endif
            for( ; p; p = p->parent) {
                p->unprotect();
                p->hiwat = mark;
                p->protect();
                
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
                sumOfExtraReleases += p->sumOfExtraReleases();
#endif
            }

            _objc_inform("POOL HIGHWATER: new high water mark of %u "
                         "pending releases for thread %p:",
                         mark, objc_thread_self());
#if SUPPORT_AUTORELEASEPOOL_DEDUP_PTRS
            if (sumOfExtraReleases > 0) {
                _objc_inform("POOL HIGHWATER: extra sequential autoreleases of objects: %u",
                             sumOfExtraReleases);
            }
#endif

            void *stack[128];
            int count = backtrace(stack, sizeof(stack)/sizeof(stack[0]));
            char **sym = backtrace_symbols(stack, count);
            for (int i = 0; i < count; i++) {
                _objc_inform("POOL HIGHWATER:     %s", sym[i]);
            }
            free(sym);
        }
    }

#undef POOL_BOUNDARY
};

/***********************************************************************
* Slow paths for inline control
**********************************************************************/

#if SUPPORT_NONPOINTER_ISA

NEVER_INLINE id 
objc_object::rootRetain_overflow(bool tryRetain)
{
    return rootRetain(tryRetain, RRVariant::Full);
}


NEVER_INLINE uintptr_t
objc_object::rootRelease_underflow(bool performDealloc)
{
    return rootRelease(performDealloc, RRVariant::Full);
}


// Slow path of clearDeallocating() 
// for objects with nonpointer isa
// that were ever weakly referenced 
// or whose retain count ever overflowed to the side table.
NEVER_INLINE void
objc_object::clearDeallocating_slow()
{
    ASSERT(isa.nonpointer  &&  (isa.weakly_referenced || isa.has_sidetable_rc));

    SideTable& table = SideTables()[this];
    table.lock();
    if (isa.weakly_referenced) {
        weak_clear_no_lock(&table.weak_table, (id)this);
    }
    if (isa.has_sidetable_rc) {
        table.refcnts.erase(this);
    }
    table.unlock();
}

#endif

__attribute__((noinline,used))
id 
objc_object::rootAutorelease2()
{
    ASSERT(!isTaggedPointer());
    return AutoreleasePoolPage::autorelease((id)this);
}


BREAKPOINT_FUNCTION(
    void objc_overrelease_during_dealloc_error(void)
);


NEVER_INLINE uintptr_t
objc_object::overrelease_error()
{
    _objc_inform_now_and_on_crash("%s object %p overreleased while already deallocating; break on objc_overrelease_during_dealloc_error to debug", object_getClassName((id)this), this);
    objc_overrelease_during_dealloc_error();
    return 0; // allow rootRelease() to tail-call this
}


/***********************************************************************
* Retain count operations for side table.
**********************************************************************/


#if DEBUG
// Used to assert that an object is not present in the side table.
bool
objc_object::sidetable_present()
{
    bool result = false;
    SideTable& table = SideTables()[this];

    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) result = true;

    if (weak_is_registered_no_lock(&table.weak_table, (id)this)) result = true;

    table.unlock();

    return result;
}
#endif

#if SUPPORT_NONPOINTER_ISA

void 
objc_object::sidetable_lock()
{
    SideTable& table = SideTables()[this];
    table.lock();
}

void 
objc_object::sidetable_unlock()
{
    SideTable& table = SideTables()[this];
    table.unlock();
}


// Move the entire retain count to the side table, 
// as well as isDeallocating and weaklyReferenced.
void 
objc_object::sidetable_moveExtraRC_nolock(size_t extra_rc, 
                                          bool isDeallocating, 
                                          bool weaklyReferenced)
{
    ASSERT(!isa.nonpointer);        // should already be changed to raw pointer
    SideTable& table = SideTables()[this];

    size_t& refcntStorage = table.refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // not deallocating - that was in the isa
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);  
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);  

    uintptr_t carry;
    size_t refcnt = addc(oldRefcnt, (extra_rc - 1) << SIDE_TABLE_RC_SHIFT, 0, &carry);
    if (carry) refcnt = SIDE_TABLE_RC_PINNED;
    if (isDeallocating) refcnt |= SIDE_TABLE_DEALLOCATING;
    if (weaklyReferenced) refcnt |= SIDE_TABLE_WEAKLY_REFERENCED;

    refcntStorage = refcnt;
}


// Move some retain counts to the side table from the isa field.
// Returns true if the object is now pinned.
bool 
objc_object::sidetable_addExtraRC_nolock(size_t delta_rc)
{
    ASSERT(isa.nonpointer);
    SideTable& table = SideTables()[this];

    size_t& refcntStorage = table.refcnts[this];
    size_t oldRefcnt = refcntStorage;
    // isa-side bits should not be set here
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    if (oldRefcnt & SIDE_TABLE_RC_PINNED) return true;

    uintptr_t carry;
    size_t newRefcnt = 
        addc(oldRefcnt, delta_rc << SIDE_TABLE_RC_SHIFT, 0, &carry);
    if (carry) {
        refcntStorage =
            SIDE_TABLE_RC_PINNED | (oldRefcnt & SIDE_TABLE_FLAG_MASK);
        return true;
    }
    else {
        refcntStorage = newRefcnt;
        return false;
    }
}


// Move some retain counts from the side table to the isa field.
// Returns the actual count subtracted, which may be less than the request.
objc_object::SidetableBorrow
objc_object::sidetable_subExtraRC_nolock(size_t delta_rc)
{
    ASSERT(isa.nonpointer);
    SideTable& table = SideTables()[this];

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()  ||  it->second == 0) {
        // Side table retain count is zero. Can't borrow.
        return { 0, 0 };
    }
    size_t oldRefcnt = it->second;

    // isa-side bits should not be set here
    ASSERT((oldRefcnt & SIDE_TABLE_DEALLOCATING) == 0);
    ASSERT((oldRefcnt & SIDE_TABLE_WEAKLY_REFERENCED) == 0);

    size_t newRefcnt = oldRefcnt - (delta_rc << SIDE_TABLE_RC_SHIFT);
    ASSERT(oldRefcnt > newRefcnt);  // shouldn't underflow
    it->second = newRefcnt;
    return { delta_rc, newRefcnt >> SIDE_TABLE_RC_SHIFT };
}


size_t 
objc_object::sidetable_getExtraRC_nolock()
{
    ASSERT(isa.nonpointer);
    SideTable& table = SideTables()[this];
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it == table.refcnts.end()) return 0;
    else return it->second >> SIDE_TABLE_RC_SHIFT;
}


void
objc_object::sidetable_clearExtraRC_nolock()
{
    ASSERT(isa.nonpointer);
    SideTable& table = SideTables()[this];
    RefcountMap::iterator it = table.refcnts.find(this);
    table.refcnts.erase(it);
}


// SUPPORT_NONPOINTER_ISA
#endif


id
objc_object::sidetable_retain(bool locked)
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa.nonpointer);
#endif
    SideTable& table = SideTables()[this];
    
    if (!locked) table.lock();
    size_t& refcntStorage = table.refcnts[this];
    if (! (refcntStorage & SIDE_TABLE_RC_PINNED)) {
        refcntStorage += SIDE_TABLE_RC_ONE;
    }
    table.unlock();

    return (id)this;
}


bool
objc_object::sidetable_tryRetain()
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa.nonpointer);
#endif
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootTryRetain() is called exclusively by _objc_loadWeak(), 
    // which already acquired the lock on our behalf.

    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_tryRetain.");
    // }

    bool result = true;
    auto it = table.refcnts.try_emplace(this, SIDE_TABLE_RC_ONE);
    auto &refcnt = it.first->second;
    if (it.second) {
        // there was no entry
    } else if (refcnt & SIDE_TABLE_DEALLOCATING) {
        result = false;
    } else if (! (refcnt & SIDE_TABLE_RC_PINNED)) {
        refcnt += SIDE_TABLE_RC_ONE;
    }
    
    return result;
}


uintptr_t
objc_object::sidetable_retainCount()
{
    SideTable& table = SideTables()[this];

    size_t refcnt_result = 1;
    
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        // this is valid for SIDE_TABLE_RC_PINNED too
        refcnt_result += it->second >> SIDE_TABLE_RC_SHIFT;
    }
    table.unlock();
    return refcnt_result;
}


bool 
objc_object::sidetable_isDeallocating()
{
    SideTable& table = SideTables()[this];

    // NO SPINLOCK HERE
    // _objc_rootIsDeallocating() is called exclusively by _objc_storeWeak(), 
    // which already acquired the lock on our behalf.


    // fixme can't do this efficiently with os_lock_handoff_s
    // if (table.slock == 0) {
    //     _objc_fatal("Do not call -_isDeallocating.");
    // }

    RefcountMap::iterator it = table.refcnts.find(this);
    return (it != table.refcnts.end()) && (it->second & SIDE_TABLE_DEALLOCATING);
}


bool 
objc_object::sidetable_isWeaklyReferenced()
{
    bool result = false;

    SideTable& table = SideTables()[this];
    table.lock();

    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        result = it->second & SIDE_TABLE_WEAKLY_REFERENCED;
    }

    table.unlock();

    return result;
}

#if OBJC_WEAK_FORMATION_CALLOUT_DEFINED
//Clients can dlsym() for this symbol to see if an ObjC supporting
//-_setWeaklyReferenced is present
OBJC_EXPORT const uintptr_t _objc_has_weak_formation_callout = 0;
static_assert(SUPPORT_NONPOINTER_ISA, "Weak formation callout must only be defined when nonpointer isa is supported.");
#else
static_assert(!SUPPORT_NONPOINTER_ISA, "If weak callout is not present then we must not support nonpointer isas.");
#endif

void 
objc_object::sidetable_setWeaklyReferenced_nolock()
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa.nonpointer);
#endif
  
    SideTable& table = SideTables()[this];
  
    table.refcnts[this] |= SIDE_TABLE_WEAKLY_REFERENCED;
}


// rdar://20206767
// return uintptr_t instead of bool so that the various raw-isa 
// -release paths all return zero in eax
uintptr_t
objc_object::sidetable_release(bool locked, bool performDealloc)
{
#if SUPPORT_NONPOINTER_ISA
    ASSERT(!isa.nonpointer);
#endif
    SideTable& table = SideTables()[this];

    bool do_dealloc = false;

    if (!locked) table.lock();
    auto it = table.refcnts.try_emplace(this, SIDE_TABLE_DEALLOCATING);
    auto &refcnt = it.first->second;
    if (it.second) {
        do_dealloc = true;
    } else if (refcnt < SIDE_TABLE_DEALLOCATING) {
        // SIDE_TABLE_WEAKLY_REFERENCED may be set. Don't change it.
        do_dealloc = true;
        refcnt |= SIDE_TABLE_DEALLOCATING;
    } else if (! (refcnt & SIDE_TABLE_RC_PINNED)) {
        refcnt -= SIDE_TABLE_RC_ONE;
    }
    table.unlock();
    if (do_dealloc  &&  performDealloc) {
        ((void(*)(objc_object *, SEL))objc_msgSend)(this, @selector(dealloc));
    }
    return do_dealloc;
}


void 
objc_object::sidetable_clearDeallocating()
{
    SideTable& table = SideTables()[this];

    // clear any weak table items
    // clear extra retain count and deallocating bit
    // (fixme warn or abort if extra retain count == 0 ?)
    table.lock();
    RefcountMap::iterator it = table.refcnts.find(this);
    if (it != table.refcnts.end()) {
        if (it->second & SIDE_TABLE_WEAKLY_REFERENCED) {
            weak_clear_no_lock(&table.weak_table, (id)this);
        }
        table.refcnts.erase(it);
    }
    table.unlock();
}


/***********************************************************************
* Optimized retain/release/autorelease entrypoints
**********************************************************************/


#if __OBJC2__

__attribute__((aligned(16), flatten, noinline))
id 
objc_retain(id obj)
{
    if (obj->isTaggedPointerOrNil()) return obj;
    return obj->retain();
}


__attribute__((aligned(16), flatten, noinline))
void 
objc_release(id obj)
{
    if (obj->isTaggedPointerOrNil()) return;
    return obj->release();
}


__attribute__((aligned(16), flatten, noinline))
id
objc_autorelease(id obj)
{
    if (obj->isTaggedPointerOrNil()) return obj;
    return obj->autorelease();
}


// OBJC2
#else
// not OBJC2


id objc_retain(id obj) { return [obj retain]; }
void objc_release(id obj) { [obj release]; }
id objc_autorelease(id obj) { return [obj autorelease]; }


#endif


/***********************************************************************
* Basic operations for root class implementations a.k.a. _objc_root*()
**********************************************************************/

bool
_objc_rootTryRetain(id obj) 
{
    ASSERT(obj);

    return obj->rootTryRetain();
}

bool
_objc_rootIsDeallocating(id obj) 
{
    ASSERT(obj);

    return obj->rootIsDeallocating();
}


void 
objc_clear_deallocating(id obj) 
{
    ASSERT(obj);

    if (obj->isTaggedPointer()) return;
    obj->clearDeallocating();
}


bool
_objc_rootReleaseWasZero(id obj)
{
    ASSERT(obj);

    return obj->rootReleaseShouldDealloc();
}


NEVER_INLINE id
_objc_rootAutorelease(id obj)
{
    ASSERT(obj);
    return obj->rootAutorelease();
}

uintptr_t
_objc_rootRetainCount(id obj)
{
    ASSERT(obj);

    return obj->rootRetainCount();
}


NEVER_INLINE id
_objc_rootRetain(id obj)
{
    ASSERT(obj);

    return obj->rootRetain();
}

NEVER_INLINE void
_objc_rootRelease(id obj)
{
    ASSERT(obj);

    obj->rootRelease();
}

// Call [cls alloc] or [cls allocWithZone:nil], with appropriate
// shortcutting optimizations.
static ALWAYS_INLINE id
callAlloc(Class cls, bool checkNil, bool allocWithZone=false)
{
#if __OBJC2__
    if (slowpath(checkNil && !cls)) return nil;
    if (fastpath(!cls->ISA()->hasCustomAWZ())) {
        return _objc_rootAllocWithZone(cls, nil);
    }
#endif

    // No shortcuts available.
    if (allocWithZone) {
        return ((id(*)(id, SEL, struct _NSZone *))objc_msgSend)(cls, @selector(allocWithZone:), nil);
    }
    return ((id(*)(id, SEL))objc_msgSend)(cls, @selector(alloc));
}


// Base class implementation of +alloc. cls is not nil.
// Calls [cls allocWithZone:nil].
id
_objc_rootAlloc(Class cls)
{
    return callAlloc(cls, false/*checkNil*/, true/*allocWithZone*/);
}

// Calls [cls alloc].
id
objc_alloc(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/);
}

// Calls [cls allocWithZone:nil].
id
objc_allocWithZone(Class cls)
{
    return callAlloc(cls, true/*checkNil*/, true/*allocWithZone*/);
}

// Calls [[cls alloc] init].
id
objc_alloc_init(Class cls)
{
    return [callAlloc(cls, true/*checkNil*/, false/*allocWithZone*/) init];
}

// Calls [cls new]
id
objc_opt_new(Class cls)
{
#if __OBJC2__
    if (fastpath(cls && !cls->ISA()->hasCustomCore())) {
        return [callAlloc(cls, false/*checkNil*/) init];
    }
#endif
    return ((id(*)(id, SEL))objc_msgSend)(cls, @selector(new));
}

// Calls [obj self]
id
objc_opt_self(id obj)
{
#if __OBJC2__
    if (fastpath(obj->isTaggedPointerOrNil() || !obj->ISA()->hasCustomCore())) {
        return obj;
    }
#endif
    return ((id(*)(id, SEL))objc_msgSend)(obj, @selector(self));
}

// Calls [obj class]
Class
objc_opt_class(id obj)
{
#if __OBJC2__
    if (slowpath(!obj)) return nil;
    Class cls = obj->getIsa();
    if (fastpath(!cls->hasCustomCore())) {
        return cls->isMetaClass() ? obj : cls;
    }
#endif
    return ((Class(*)(id, SEL))objc_msgSend)(obj, @selector(class));
}

// Calls [obj isKindOfClass]
BOOL
objc_opt_isKindOfClass(id obj, Class otherClass)
{
#if __OBJC2__
    if (slowpath(!obj)) return NO;
    Class cls = obj->getIsa();
    if (fastpath(!cls->hasCustomCore())) {
        for (Class tcls = cls; tcls; tcls = tcls->getSuperclass()) {
            if (tcls == otherClass) return YES;
        }
        return NO;
    }
#endif
    return ((BOOL(*)(id, SEL, Class))objc_msgSend)(obj, @selector(isKindOfClass:), otherClass);
}

// Calls [obj respondsToSelector]
BOOL
objc_opt_respondsToSelector(id obj, SEL sel)
{
#if __OBJC2__
    if (slowpath(!obj)) return NO;
    Class cls = obj->getIsa();
    if (fastpath(!cls->hasCustomCore())) {
        return class_respondsToSelector_inst(obj, sel, cls);
    }
#endif
    return ((BOOL(*)(id, SEL, SEL))objc_msgSend)(obj, @selector(respondsToSelector:), sel);
}

void
_objc_rootDealloc(id obj)
{
    ASSERT(obj);

    obj->rootDealloc();
}

void
_objc_rootFinalize(id obj __unused)
{
    ASSERT(obj);
    _objc_fatal("_objc_rootFinalize called with garbage collection off");
}


id
_objc_rootInit(id obj)
{
    // In practice, it will be hard to rely on this function.
    // Many classes do not properly chain -init calls.
    return obj;
}


malloc_zone_t *
_objc_rootZone(id obj)
{
    (void)obj;
#if __OBJC2__
    // allocWithZone under __OBJC2__ ignores the zone parameter
    return malloc_default_zone();
#else
    malloc_zone_t *rval = malloc_zone_from_ptr(obj);
    return rval ? rval : malloc_default_zone();
#endif
}

uintptr_t
_objc_rootHash(id obj)
{
    return (uintptr_t)obj;
}

void *
objc_autoreleasePoolPush(void)
{
    return AutoreleasePoolPage::push();
}

NEVER_INLINE
void
objc_autoreleasePoolPop(void *ctxt)
{
    AutoreleasePoolPage::pop(ctxt);
}


void *
_objc_autoreleasePoolPush(void)
{
    return objc_autoreleasePoolPush();
}

void
_objc_autoreleasePoolPop(void *ctxt)
{
    objc_autoreleasePoolPop(ctxt);
}

void 
_objc_autoreleasePoolPrint(void)
{
    AutoreleasePoolPage::printAll();
}


// Same as objc_release but suitable for tail-calling 
// if you need the value back and don't want to push a frame before this point.
__attribute__((noinline))
static id 
objc_releaseAndReturn(id obj)
{
    objc_release(obj);
    return obj;
}

// Same as objc_retainAutorelease but suitable for tail-calling 
// if you don't want to push a frame before this point.
__attribute__((noinline))
static id 
objc_retainAutoreleaseAndReturn(id obj)
{
    return objc_retainAutorelease(obj);
}


// Prepare a value at +1 for return through a +0 autoreleasing convention.
id 
objc_autoreleaseReturnValue(id obj)
{
    if (prepareOptimizedReturn(ReturnAtPlus1)) return obj;

    return objc_autorelease(obj);
}

// Prepare a value at +0 for return through a +0 autoreleasing convention.
id 
objc_retainAutoreleaseReturnValue(id obj)
{
    if (prepareOptimizedReturn(ReturnAtPlus0)) return obj;

    // not objc_autoreleaseReturnValue(objc_retain(obj)) 
    // because we don't need another optimization attempt
    return objc_retainAutoreleaseAndReturn(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +1.
id
objc_retainAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn() == ReturnAtPlus1) return obj;

    return objc_retain(obj);
}

// Accept a value returned through a +0 autoreleasing convention for use at +0.
id
objc_unsafeClaimAutoreleasedReturnValue(id obj)
{
    if (acceptOptimizedReturn() == ReturnAtPlus0) return obj;

    return objc_releaseAndReturn(obj);
}

id
objc_retainAutorelease(id obj)
{
    return objc_autorelease(objc_retain(obj));
}

void
_objc_deallocOnMainThreadHelper(void *context)
{
    id obj = (id)context;
    [obj dealloc];
}

// convert objc_objectptr_t to id, callee must take ownership.
id objc_retainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert objc_objectptr_t to id, without ownership transfer.
id objc_unretainedObject(objc_objectptr_t pointer) { return (id)pointer; }

// convert id to objc_objectptr_t, no ownership transfer.
objc_objectptr_t objc_unretainedPointer(id object) { return object; }


void arr_init(void) 
{
    AutoreleasePoolPage::init();
    SideTablesMap.init();
    _objc_associations_init();
}


#if SUPPORT_TAGGED_POINTERS

// Placeholder for old debuggers. When they inspect an 
// extended tagged pointer object they will see this isa.

@interface __NSUnrecognizedTaggedPointer : NSObject
@end

__attribute__((objc_nonlazy_class))
@implementation __NSUnrecognizedTaggedPointer
-(id) retain { return self; }
-(oneway void) release { }
-(id) autorelease { return self; }
@end

#endif

__attribute__((objc_nonlazy_class))
@implementation NSObject

+ (void)initialize {
}

+ (id)self {
    return (id)self;
}

- (id)self {
    return self;
}

+ (Class)class {
    return self;
}

- (Class)class {
    return object_getClass(self);
}

+ (Class)superclass {
    return self->getSuperclass();
}

- (Class)superclass {
    return [self class]->getSuperclass();
}

+ (BOOL)isMemberOfClass:(Class)cls {
    return self->ISA() == cls;
}

- (BOOL)isMemberOfClass:(Class)cls {
    return [self class] == cls;
}

+ (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = self->ISA(); tcls; tcls = tcls->getSuperclass()) {
        if (tcls == cls) return YES;
    }
    return NO;
}

- (BOOL)isKindOfClass:(Class)cls {
    for (Class tcls = [self class]; tcls; tcls = tcls->getSuperclass()) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isSubclassOfClass:(Class)cls {
    for (Class tcls = self; tcls; tcls = tcls->getSuperclass()) {
        if (tcls == cls) return YES;
    }
    return NO;
}

+ (BOOL)isAncestorOfObject:(NSObject *)obj {
    for (Class tcls = [obj class]; tcls; tcls = tcls->getSuperclass()) {
        if (tcls == self) return YES;
    }
    return NO;
}

+ (BOOL)instancesRespondToSelector:(SEL)sel {
    return class_respondsToSelector_inst(nil, sel, self);
}

+ (BOOL)respondsToSelector:(SEL)sel {
    return class_respondsToSelector_inst(self, sel, self->ISA());
}

- (BOOL)respondsToSelector:(SEL)sel {
    return class_respondsToSelector_inst(self, sel, [self class]);
}

+ (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = self; tcls; tcls = tcls->getSuperclass()) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (!protocol) return NO;
    for (Class tcls = [self class]; tcls; tcls = tcls->getSuperclass()) {
        if (class_conformsToProtocol(tcls, protocol)) return YES;
    }
    return NO;
}

+ (NSUInteger)hash {
    return _objc_rootHash(self);
}

- (NSUInteger)hash {
    return _objc_rootHash(self);
}

+ (BOOL)isEqual:(id)obj {
    return obj == (id)self;
}

- (BOOL)isEqual:(id)obj {
    return obj == self;
}


+ (BOOL)isFault {
    return NO;
}

- (BOOL)isFault {
    return NO;
}

+ (BOOL)isProxy {
    return NO;
}

- (BOOL)isProxy {
    return NO;
}


+ (IMP)instanceMethodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return class_getMethodImplementation(self, sel);
}

+ (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation((id)self, sel);
}

- (IMP)methodForSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return object_getMethodImplementation(self, sel);
}

+ (BOOL)resolveClassMethod:(SEL)sel {
    return NO;
}

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    return NO;
}

// Replaced by CF (throws an NSException)
+ (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("+[%s %s]: unrecognized selector sent to instance %p", 
                class_getName(self), sel_getName(sel), self);
}

// Replaced by CF (throws an NSException)
- (void)doesNotRecognizeSelector:(SEL)sel {
    _objc_fatal("-[%s %s]: unrecognized selector sent to instance %p", 
                object_getClassName(self), sel_getName(sel), self);
}


+ (id)performSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL))objc_msgSend)((id)self, sel);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)((id)self, sel, obj);
}

+ (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)((id)self, sel, obj1, obj2);
}

- (id)performSelector:(SEL)sel {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL))objc_msgSend)(self, sel);
}

- (id)performSelector:(SEL)sel withObject:(id)obj {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id))objc_msgSend)(self, sel, obj);
}

- (id)performSelector:(SEL)sel withObject:(id)obj1 withObject:(id)obj2 {
    if (!sel) [self doesNotRecognizeSelector:sel];
    return ((id(*)(id, SEL, id, id))objc_msgSend)(self, sel, obj1, obj2);
}


// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)instanceMethodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject instanceMethodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("+[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

// Replaced by CF (returns an NSMethodSignature)
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    _objc_fatal("-[NSObject methodSignatureForSelector:] "
                "not available without CoreFoundation");
}

+ (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [self doesNotRecognizeSelector:(invocation ? [invocation selector] : 0)];
}

+ (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return nil;
}


// Replaced by CF (returns an NSString)
+ (NSString *)description {
    return nil;
}

// Replaced by CF (returns an NSString)
- (NSString *)description {
    return nil;
}

+ (NSString *)debugDescription {
    return [self description];
}

- (NSString *)debugDescription {
    return [self description];
}


+ (id)new {
    return [callAlloc(self, false/*checkNil*/) init];
}

+ (id)retain {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)retain {
    return _objc_rootRetain(self);
}


+ (BOOL)_tryRetain {
    return YES;
}

// Replaced by ObjectAlloc
- (BOOL)_tryRetain {
    return _objc_rootTryRetain(self);
}

+ (BOOL)_isDeallocating {
    return NO;
}

- (BOOL)_isDeallocating {
    return _objc_rootIsDeallocating(self);
}

+ (BOOL)allowsWeakReference { 
    return YES; 
}

+ (BOOL)retainWeakReference {
    return YES; 
}

- (BOOL)allowsWeakReference { 
    return ! [self _isDeallocating]; 
}

- (BOOL)retainWeakReference { 
    return [self _tryRetain]; 
}

+ (oneway void)release {
}

// Replaced by ObjectAlloc
- (oneway void)release {
    _objc_rootRelease(self);
}

+ (id)autorelease {
    return (id)self;
}

// Replaced by ObjectAlloc
- (id)autorelease {
    return _objc_rootAutorelease(self);
}

+ (NSUInteger)retainCount {
    return ULONG_MAX;
}

- (NSUInteger)retainCount {
    return _objc_rootRetainCount(self);
}

+ (id)alloc {
    return _objc_rootAlloc(self);
}

// Replaced by ObjectAlloc
+ (id)allocWithZone:(struct _NSZone *)zone {
    return _objc_rootAllocWithZone(self, (malloc_zone_t *)zone);
}

// Replaced by CF (throws an NSException)
+ (id)init {
    return (id)self;
}

- (id)init {
    return _objc_rootInit(self);
}

// Replaced by CF (throws an NSException)
+ (void)dealloc {
}


// Replaced by NSZombies
- (void)dealloc {
    _objc_rootDealloc(self);
}

// Previously used by GC. Now a placeholder for binary compatibility.
- (void) finalize {
}

+ (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

- (struct _NSZone *)zone {
    return (struct _NSZone *)_objc_rootZone(self);
}

+ (id)copy {
    return (id)self;
}

+ (id)copyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)copy {
    return [(id)self copyWithZone:nil];
}

+ (id)mutableCopy {
    return (id)self;
}

+ (id)mutableCopyWithZone:(struct _NSZone *)zone {
    return (id)self;
}

- (id)mutableCopy {
    return [(id)self mutableCopyWithZone:nil];
}

@end


