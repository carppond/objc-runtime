/*
 * Copyright (c) 2007 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-os.m
* OS portability layer.
**********************************************************************/

#include "objc-private.h"
#include "objc-loadmethod.h"
//#include "objc-bp-assist.h"

#if TARGET_OS_WIN32

#include "objc-runtime-old.h"
#include "objcrt.h"

const fork_unsafe_lock_t fork_unsafe_lock;

int monitor_init(monitor_t *c) 
{
    // fixme error checking
    HANDLE mutex = CreateMutex(NULL, TRUE, NULL);
    while (!c->mutex) {
        // fixme memory barrier here?
        if (0 == InterlockedCompareExchangePointer(&c->mutex, mutex, 0)) {
            // we win - finish construction
            c->waiters = CreateSemaphore(NULL, 0, 0x7fffffff, NULL);
            c->waitersDone = CreateEvent(NULL, FALSE, FALSE, NULL);
            InitializeCriticalSection(&c->waitCountLock);
            c->waitCount = 0;
            c->didBroadcast = 0;
            ReleaseMutex(c->mutex);    
            return 0;
        }
    }

    // someone else allocated the mutex and constructed the monitor
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return 0;
}

void mutex_init(mutex_t *m)
{
    while (!m->lock) {
        CRITICAL_SECTION *newlock = malloc(sizeof(CRITICAL_SECTION));
        InitializeCriticalSection(newlock);
        // fixme memory barrier here?
        if (0 == InterlockedCompareExchangePointer(&m->lock, newlock, 0)) {
            return;
        }
        // someone else installed their lock first
        DeleteCriticalSection(newlock);
        free(newlock);
    }
}


void recursive_mutex_init(recursive_mutex_t *m)
{
    // fixme error checking
    HANDLE newmutex = CreateMutex(NULL, FALSE, NULL);
    while (!m->mutex) {
        // fixme memory barrier here?
        if (0 == InterlockedCompareExchangePointer(&m->mutex, newmutex, 0)) {
            // we win
            return;
        }
    }
    
    // someone else installed their lock first
    CloseHandle(newmutex);
}


WINBOOL APIENTRY DllMain( HMODULE hModule,
                       DWORD  ul_reason_for_call,
                       LPVOID lpReserved
					 )
{
    switch (ul_reason_for_call) {
    case DLL_PROCESS_ATTACH:
        environ_init();
        tls_init();
        runtime_init();
        sel_init(3500);  // old selector heuristic
        exception_init();
        break;

    case DLL_THREAD_ATTACH:
        break;

    case DLL_THREAD_DETACH:
    case DLL_PROCESS_DETACH:
        break;
    }
    return TRUE;
}

OBJC_EXPORT void *_objc_init_image(HMODULE image, const objc_sections *sects)
{
    header_info *hi = malloc(sizeof(header_info));
    size_t count, i;

    hi->mhdr = (const headerType *)image;
    hi->info = sects->iiStart;
    hi->allClassesRealized = NO;
    hi->modules = sects->modStart ? (Module *)((void **)sects->modStart+1) : 0;
    hi->moduleCount = (Module *)sects->modEnd - hi->modules;
    hi->protocols = sects->protoStart ? (struct old_protocol **)((void **)sects->protoStart+1) : 0;
    hi->protocolCount = (struct old_protocol **)sects->protoEnd - hi->protocols;
    hi->imageinfo = NULL;
    hi->imageinfoBytes = 0;
    // hi->imageinfo = sects->iiStart ? (uint8_t *)((void **)sects->iiStart+1) : 0;;
//     hi->imageinfoBytes = (uint8_t *)sects->iiEnd - hi->imageinfo;
    hi->selrefs = sects->selrefsStart ? (SEL *)((void **)sects->selrefsStart+1) : 0;
    hi->selrefCount = (SEL *)sects->selrefsEnd - hi->selrefs;
    hi->clsrefs = sects->clsrefsStart ? (Class *)((void **)sects->clsrefsStart+1) : 0;
    hi->clsrefCount = (Class *)sects->clsrefsEnd - hi->clsrefs;

    count = 0;
    for (i = 0; i < hi->moduleCount; i++) {
        if (hi->modules[i]) count++;
    }
    hi->mod_count = 0;
    hi->mod_ptr = 0;
    if (count > 0) {
        hi->mod_ptr = malloc(count * sizeof(struct objc_module));
        for (i = 0; i < hi->moduleCount; i++) {
            if (hi->modules[i]) memcpy(&hi->mod_ptr[hi->mod_count++], hi->modules[i], sizeof(struct objc_module));
        }
    }
    
    hi->moduleName = malloc(MAX_PATH * sizeof(TCHAR));
    GetModuleFileName((HMODULE)(hi->mhdr), hi->moduleName, MAX_PATH * sizeof(TCHAR));

    appendHeader(hi);

    if (PrintImages) {
        _objc_inform("IMAGES: loading image for %s%s%s%s\n", 
                     hi->fname, 
                     headerIsBundle(hi) ? " (bundle)" : "", 
                     hi->info->isReplacement() ? " (replacement)":"", 
                     hi->info->hasCategoryClassProperties() ? " (has class properties)":"");
    }

    // Count classes. Size various table based on the total.
    int total = 0;
    int unoptimizedTotal = 0;
    {
      if (_getObjc2ClassList(hi, &count)) {
        total += (int)count;
        if (!hi->getInSharedCache()) unoptimizedTotal += count;
      }
    }

    _read_images(&hi, 1, total, unoptimizedTotal);

    return hi;
}

OBJC_EXPORT void _objc_load_image(HMODULE image, header_info *hinfo)
{
    prepare_load_methods(hinfo);
    call_load_methods();
}

OBJC_EXPORT void _objc_unload_image(HMODULE image, header_info *hinfo)
{
    _objc_fatal("image unload not supported");
}


// TARGET_OS_WIN32
#elif TARGET_OS_MAC

#include "objc-file-old.h"
#include "objc-file.h"


/***********************************************************************
* libobjc must never run static destructors. 
* Cover libc's __cxa_atexit with our own definition that runs nothing.
* rdar://21734598  ER: Compiler option to suppress C++ static destructors
**********************************************************************/
extern "C" int __cxa_atexit();
extern "C" int __cxa_atexit() { return 0; }


/***********************************************************************
* bad_magic.
* Return YES if the header has invalid Mach-o magic.
* 如果 mach-o header 有无效的 magic,则返回 YES
**********************************************************************/
bool bad_magic(const headerType *mhdr)
{
    return (mhdr->magic != MH_MAGIC  &&  mhdr->magic != MH_MAGIC_64  &&  
            mhdr->magic != MH_CIGAM  &&  mhdr->magic != MH_CIGAM_64);
}

/*!
 *  addHeader
 *
 *  @param mhdr mach-o header
 *  @param path mach-o path
 *  @param totalClasses 类的数量
 *  @param unoptimizedTotalClasses 未优化的类的数量
 *
 *  @return header_info * 组装的 mach-o 信息
 */
static header_info * addHeader(const headerType *mhdr, const char *path, int &totalClasses, int &unoptimizedTotalClasses)
{
    // 临时变量
    header_info *hi;
    
    // 如果 mach-o header 有无效的 magic, 返回 NULL
    if (bad_magic(mhdr)) return NULL;
    // 临时变量
    bool inSharedCache = false;

    // Look for hinfo from the dyld shared cache.
    // 从 dyld 的共享缓存中查找 hinfo
    hi = preoptimizedHinfoForHeader(mhdr);
    if (hi) {
        // Found an hinfo in the dyld shared cache.
        // 根据 mhdr 从 dyld 共享缓存中,找到一个 hinfo
        // Weed out duplicates.
        // 清楚重复项
        // 如果当前 hinfo 已经加载过直接返回 NULL
        if (hi->isLoaded()) {
            return NULL;
        }
        // 当前 mhdr 在共享缓存中
        inSharedCache = true;

        // Initialize fields not set by the shared cache
        // hi->next is set by appendHeader
        // 初始化共享缓存未设置的字段hi->next由appendHeader设置
        
        // 设置当前 hinfo 已经加载,防止重复加载
        hi->setLoaded(true);
        
        // 打印当前加载的 hinfo 信息
        if (PrintPreopt) {
            _objc_inform("PREOPTIMIZATION: honoring preoptimized header info at %p for %s", hi, hi->fname());
        }

#if !__OBJC2__
        _objc_fatal("shouldn't be here");
#endif
#if DEBUG
        // Verify image_info
        size_t info_size = 0;
        const objc_image_info *image_info = _getObjcImageInfo(mhdr,&info_size);
        ASSERT(image_info == hi->info());
#endif
    }
    else 
    {
        // Didn't find an hinfo in the dyld shared cache.
        // 在 dyld 共享缓存中找不到 hinfo。
        
        // Locate the __OBJC segment
        // 找到 __OBJC 段
        size_t info_size = 0;
        // 段大小
        unsigned long seg_size;
        // 根据 mhdr 从 __DATA _objc_imageinfo 中获取对应的信息
        const objc_image_info *image_info = _getObjcImageInfo(mhdr,&info_size);
        // __OBJC 好像是 objc2.0 之前的东西,在新的 mhdr 中是不存在的
        const uint8_t *objc_segment = getsegmentdata(mhdr,SEG_OBJC,&seg_size);
        // 如果没有获取到,就返回 NULL
        if (!objc_segment  &&  !image_info) return NULL;

        // Allocate a header_info entry.
        // 加载一个 header_info
        // Note we also allocate space for a single header_info_rw in the
        // rw_data[] inside header_info.
        // 注意，我们还在 header_info 中的 rw_data[] 中为单个 header_info_rw 分配空间。
        // 创建一个 hinfo,并申请 sizeof(header_info) + sizeof(header_info_rw)的空间
        hi = (header_info *)calloc(sizeof(header_info) + sizeof(header_info_rw), 1);

        // Set up the new header_info entry.
        // 设置新的 header_info
        // 设置 mhdr
        hi->setmhdr(mhdr);
#if !__OBJC2__
        // mhdr must already be set
        hi->mod_count = 0;
        hi->mod_ptr = _getObjcModules(hi, &hi->mod_count);
#endif
        // Install a placeholder image_info if absent to simplify code elsewhere
        // 如果不存在则安装占位符 image_info 以简化其他地方的代码
        static const objc_image_info emptyInfo = {0, 0};
        hi->setinfo(image_info ?: &emptyInfo);
        // 设置已加载
        hi->setLoaded(true);
        // 设置类的实现为 NO
        hi->setAllClassesRealized(NO);
    }

#if __OBJC2__
    {
        size_t count = 0;
        // 从_DATA, _objc_classlist 中获取要加载类的数量
        if (_getObjc2ClassList(hi, &count)) {
            // 设置所有类的数量
            totalClasses += (int)count;
            // 如果当前 hi 是创建的,并非从 dyld 共享缓存中获取,则设置未优化类的数量为所有类的数量
            if (!inSharedCache) unoptimizedTotalClasses += count;
        }
    }
#endif
    // 添加 hinfo 到 LastHeader 中
    // 添加 hi 对应的 mach-o 的data/text 信息到静态的dataSegmentsRanges中
    appendHeader(hi);
    
    return hi;
}


/***********************************************************************
* linksToLibrary
* Returns true if the image links directly to a dylib whose install name 
* is exactly the given name.
**********************************************************************/
bool
linksToLibrary(const header_info *hi, const char *name)
{
    const struct dylib_command *cmd;
    unsigned long i;
    
    cmd = (const struct dylib_command *) (hi->mhdr() + 1);
    for (i = 0; i < hi->mhdr()->ncmds; i++) {
        if (cmd->cmd == LC_LOAD_DYLIB  ||  cmd->cmd == LC_LOAD_UPWARD_DYLIB  ||
            cmd->cmd == LC_LOAD_WEAK_DYLIB  ||  cmd->cmd == LC_REEXPORT_DYLIB)
        {
            const char *dylib = cmd->dylib.name.offset + (const char *)cmd;
            if (0 == strcmp(dylib, name)) return true;
        }
        cmd = (const struct dylib_command *)((char *)cmd + cmd->cmdsize);
    }

    return false;
}


#if SUPPORT_GC_COMPAT

/***********************************************************************
* shouldRejectGCApp
* Return YES if the executable requires GC.
**********************************************************************/
static bool shouldRejectGCApp(const header_info *hi)
{
    ASSERT(hi->mhdr()->filetype == MH_EXECUTE);

    if (!hi->info()->supportsGC()) {
        // App does not use GC. Don't reject it.
        return NO;
    }
        
    // Exception: Trivial AppleScriptObjC apps can run without GC.
    // 1. executable defines no classes
    // 2. executable references NSBundle only
    // 3. executable links to AppleScriptObjC.framework
    // Note that objc_appRequiresGC() also knows about this.
    size_t classcount = 0;
    size_t refcount = 0;
#if __OBJC2__
    _getObjc2ClassList(hi, &classcount);
    _getObjc2ClassRefs(hi, &refcount);
#else
    if (hi->mod_count == 0  ||  (hi->mod_count == 1 && !hi->mod_ptr[0].symtab)) classcount = 0;
    else classcount = 1;
    _getObjcClassRefs(hi, &refcount);
#endif
    if (classcount == 0  &&  refcount == 1  &&  
        linksToLibrary(hi, "/System/Library/Frameworks"
                       "/AppleScriptObjC.framework/Versions/A"
                       "/AppleScriptObjC"))
    {
        // It's AppleScriptObjC. Don't reject it.
        return NO;
    } 
    else {
        // GC and not trivial AppleScriptObjC. Reject it.
        return YES;
    }
}


/***********************************************************************
* rejectGCImage
* Halt if an image requires GC.
* Testing of the main executable should use rejectGCApp() instead.
**********************************************************************/
static bool shouldRejectGCImage(const headerType *mhdr)
{
    ASSERT(mhdr->filetype != MH_EXECUTE);

    objc_image_info *image_info;
    size_t size;
    
#if !__OBJC2__
    unsigned long seg_size;
    // 32-bit: __OBJC seg but no image_info means no GC support
    if (!getsegmentdata(mhdr, "__OBJC", &seg_size)) {
        // Not objc, therefore not GC. Don't reject it.
        return NO;
    }
    image_info = _getObjcImageInfo(mhdr, &size);
    if (!image_info) {
        // No image_info, therefore not GC. Don't reject it.
        return NO;
    }
#else
    // 64-bit: no image_info means no objc at all
    image_info = _getObjcImageInfo(mhdr, &size);
    if (!image_info) {
        // Not objc, therefore not GC. Don't reject it.
        return NO;
    }
#endif

    return image_info->requiresGC();
}

// SUPPORT_GC_COMPAT
#endif


// Swift currently adds 4 callbacks.
static GlobalSmallVector<objc_func_loadImage, 4> loadImageFuncs;

void objc_addLoadImageFunc(objc_func_loadImage _Nonnull func) {
    // Not supported on the old runtime. Not that the old runtime is supported anyway.
#if __OBJC2__
    mutex_locker_t lock(runtimeLock);
    
    // Call it with all the existing images first.
    for (auto header = FirstHeader; header; header = header->getNext()) {
        func((struct mach_header *)header->mhdr());
    }
    
    // Add it to the vector for future loads.
    loadImageFuncs.append(func);
#endif
}


/***********************************************************************
* map_images_nolock
* Process the given images which are being mapped in by dyld.
* 处理由 dyld 映射的给定 image
*
* All class registration and fixups are performed (or deferred pending
* discovery of missing superclasses etc), and +load methods are called.
* 执行所有类的注册和修复(或延迟等待发现丢失的父类等),并调用 +load 方法
*
* info[] is in bottom-up order i.e. libobjc will be earlier in the 
* array than any library that links to libobjc.
* info[] 是自下而上的顺序，即 libobjc 在数组中将比任何链接到 libobjc 的库更早。
*
* Locking: loadMethodLock(old) or runtimeLock(new) acquired by map_images.
*
* mhCount: mach-o header 个数
* mhPaths: mach-header 的路径数组
* mhdrs: mach-o header 的指针数组
**********************************************************************/
#if __OBJC2__
#include "objc-file.h"
#else
#include "objc-file-old.h"
#endif

void 
map_images_nolock(unsigned mhCount, const char * const mhPaths[],
                  const struct mach_header * const mhdrs[])
{
    // 静态临时变量,第一次加载
    static bool firstTime = YES;
    // mach-o header 的存放数组
    header_info *hList[mhCount];
    // mach-o header 的个数
    uint32_t hCount;
    // 引用计数?
    size_t selrefCount = 0;

    // Perform first-time initialization if necessary.
    // 必要时执行首次初始化
    // This function is called before ordinary library initializers.
    // 此函数在普通库初始化程序之前调用。
    // fixme defer initialization until an objc-using image is found?
    // fixme 推迟初始化直到找到使用 objc 的图像？
    if (firstTime) {
        // 预加载/初始化
        // 设置共享缓存的起始位置和区间在其执行
        preopt_init();
    }

    if (PrintImages) {
        _objc_inform("IMAGES: processing %u newly-mapped images...\n", mhCount);
    }


    // Find all images with Objective-C metadata.
    // 查找所有带有 Objective-C 元数据的images。
    
    // 初始化 mach-o header 的数量为 0
    hCount = 0;

    // Count classes. Size various table based on the total.
    // 类的数量. 根据总数调整各种表的大小
    int totalClasses = 0;
    // 未优化类的数量
    int unoptimizedTotalClasses = 0;
    {
        // i = mach-o header 的数量
        uint32_t i = mhCount;
        // 循环处理每一个 mach-o
        while (i--) {
            // 根据 i 获取对应的 mach-o header type
            const headerType *mhdr = (const headerType *)mhdrs[i];
            // 从dyld 共享缓存中查找/ 创建一个 hi,并把 hi 添加到 LastHeader 中
            auto hi = addHeader(mhdr, mhPaths[i], totalClasses, unoptimizedTotalClasses);
            // 到这里,已经获取到了: hi  totalClass unoptimizedTotalClasses
            if (!hi) {
                // no objc data in this entry
                // 此条目中没有 objc 数据 
                continue;
            }
            // 如果 mhdr 是可执行文件
            if (mhdr->filetype == MH_EXECUTE) {
                // Size some data structures based on main executable's size
                // 根据主要可执行文件的大小调整一些数据结构的大小
#if __OBJC2__
                // If dyld3 optimized the main executable, then there shouldn't
                // be any selrefs needed in the dynamic map so we can just init
                // to a 0 sized map
                // 如果 dyld3 优化了主可执行文件，那么动态映射中不应该有任何 selrefs 需要，所以我们可以初始化为 0 大小的映射
                // 如果没有优化 SEL
                if ( !hi->hasPreoptimizedSelectors() ) {
                  size_t count;
                 // 从 mhdr 的Section(__DATA,__objc_selrefs)中获取 SEL 的信息
                  _getObjc2SelectorRefs(hi, &count);
                 // sel 引用数量
                  selrefCount += count;
                 // 从 mhdr 的Section(__DATA,__objc_msgrefs)中获取 msg 的信息
                  _getObjc2MessageRefs(hi, &count);
                 // 更新 sel 引用数量
                  selrefCount += count;
                }
#else
                _getObjcSelectorRefs(hi, &selrefCount);
#endif
                
#if SUPPORT_GC_COMPAT
                // Halt if this is a GC app.
                if (shouldRejectGCApp(hi)) {
                    _objc_fatal_with_reason
                        (OBJC_EXIT_REASON_GC_NOT_SUPPORTED, 
                         OS_REASON_FLAG_CONSISTENT_FAILURE, 
                         "Objective-C garbage collection " 
                         "is no longer supported.");
                }
#endif
            }
            // hCount 自增,并添加 hi 到 hList 中
            hList[hCount++] = hi;
            
            if (PrintImages) {
                _objc_inform("IMAGES: loading image for %s%s%s%s%s\n", 
                             hi->fname(),
                             mhdr->filetype == MH_BUNDLE ? " (bundle)" : "",
                             hi->info()->isReplacement() ? " (replacement)" : "",
                             hi->info()->hasCategoryClassProperties() ? " (has class properties)" : "",
                             hi->info()->optimizedByDyld()?" (preoptimized)":"");
            }
        }
    }

    // Perform one-time runtime initialization that must be deferred until 
    // the executable itself is found. This needs to be done before 
    // further initialization.
    // 执行一次性运行时初始化, 必须推迟到找到可执行文件本身.这需要在进一步初始化之前完成
    // (The executable may not be present in this infoList if the 
    // executable does not contain Objective-C code but Objective-C 
    // is dynamically loaded later.
    // 如果可执行文件不包含 OC 代码,但是 OC 稍后会动态加载,则此 infoList 中可能不存在可执行文件
    if (firstTime) {
        // 初始化 SEL 表和注册了 C++的析构函数和构造函数
        sel_init(selrefCount);
        // 自动释放池/SideTableMap/关联函数相关的AssociationsManager 初始化
        arr_init();

#if SUPPORT_GC_COMPAT
        // Reject any GC images linked to the main executable.
        // We already rejected the app itself above.
        // Images loaded after launch will be rejected by dyld.

        for (uint32_t i = 0; i < hCount; i++) {
            auto hi = hList[i];
            auto mh = hi->mhdr();
            if (mh->filetype != MH_EXECUTE  &&  shouldRejectGCImage(mh)) {
                _objc_fatal_with_reason
                    (OBJC_EXIT_REASON_GC_NOT_SUPPORTED, 
                     OS_REASON_FLAG_CONSISTENT_FAILURE, 
                     "%s requires Objective-C garbage collection "
                     "which is no longer supported.", hi->fname());
            }
        }
#endif

#if TARGET_OS_OSX
        // Disable +initialize fork safety if the app is too old (< 10.13).
        // Disable +initialize fork safety if the app has a
        //   __DATA,__objc_fork_ok section.

//        if (!dyld_program_sdk_at_least(dyld_platform_version_macOS_10_13)) {
//            DisableInitializeForkSafety = true;
//            if (PrintInitializing) {
//                _objc_inform("INITIALIZE: disabling +initialize fork "
//                             "safety enforcement because the app is "
//                             "too old.)");
//            }
//        }

        for (uint32_t i = 0; i < hCount; i++) {
            auto hi = hList[i];
            auto mh = hi->mhdr();
            if (mh->filetype != MH_EXECUTE) continue;
            unsigned long size;
            if (getsectiondata(hi->mhdr(), "__DATA", "__objc_fork_ok", &size)) {
                DisableInitializeForkSafety = true;
                if (PrintInitializing) {
                    _objc_inform("INITIALIZE: disabling +initialize fork "
                                 "safety enforcement because the app has "
                                 "a __DATA,__objc_fork_ok section");
                }
            }
            break;  // assume only one MH_EXECUTE image
        }
#endif

    }
    // hCount 工程加载 mach-o 的数量
    if (hCount > 0) {
        // 加载 image 的核心函数
        // hList: 存放 header_info 的数组
        // totalClasses: 类的总数量
        // unoptimizedTotalClasses: 未优化的类的数量
        _read_images(hList, hCount, totalClasses, unoptimizedTotalClasses);
    }
    //
    firstTime = NO;
    
    // Call image load funcs after everything is set up.
    // 一切设置好后调用image加载函数。
    // 循环加载函数回调
    for (auto func : loadImageFuncs) {
        // 循环 mhcount
        for (uint32_t i = 0; i < mhCount; i++) {
            // 获取 i 对应的 mhdr,供加载函数调用
            func(mhdrs[i]);
        }
    }
}


/***********************************************************************
* unmap_image_nolock
* Process the given image which is about to be unmapped by dyld.
* mh is mach_header instead of headerType because that's what 
*   dyld_priv.h says even for 64-bit.
* 
* Locking: loadMethodLock(both) and runtimeLock(new) acquired by unmap_image.
**********************************************************************/
void 
unmap_image_nolock(const struct mach_header *mh)
{
    if (PrintImages) {
        _objc_inform("IMAGES: processing 1 newly-unmapped image...\n");
    }

    header_info *hi;
    
    // Find the runtime's header_info struct for the image
    for (hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
        if (hi->mhdr() == (const headerType *)mh) {
            break;
        }
    }

    if (!hi) return;

    if (PrintImages) {
        _objc_inform("IMAGES: unloading image for %s%s%s\n", 
                     hi->fname(),
                     hi->mhdr()->filetype == MH_BUNDLE ? " (bundle)" : "",
                     hi->info()->isReplacement() ? " (replacement)" : "");
    }

    _unload_image(hi);

    // Remove header_info from header list
    removeHeader(hi);
    free(hi);
}


/***********************************************************************
* static_init
* Run C++ static constructor functions.
* 运行 C++ 静态构造函数。
* libc calls _objc_init() before dyld would call our static constructors, 
* so we have to do it ourselves.
* libc 在 dyld 调用我们的静态构造函数之前调用 _objc_init()，所以我们必须自己做。
* 系统级别的 C++构造函数,先于自定义的 C++构造函数运行
**********************************************************************/
static void static_init()
{
    // 根据 SECTION_TYPE 不同,读取 mach-o 中的 section
    size_t count;
    // 加载 __objc_init_func ,对应 mach-o 文件中的(_DATA, _mod_init_func)
    auto inits = getLibobjcInitializers(&_mh_dylib_header, &count);
    for (size_t i = 0; i < count; i++) {
        // 内存平移加载
        inits[i]();
    }
    // 加载 __objc_init_offs,对应 mach-o 文件中的(__TEXT, init_offsets)
    auto offsets = getLibobjcInitializerOffsets(&_mh_dylib_header, &count);
    for (size_t i = 0; i < count; i++) {
        // 内存平移去加载
        UnsignedInitializer init(offsets[i]);
        init();
    }
    /*
     全局静态C++的构造函数的调用。在dyld调用doModInitFunctions静态构造函数之前，objc调用自己的构造函数。因为此时objc的初始化，对section进行了替换，所以后续dyld不会调用到这块。
     内部有两个方式（从macho文件读取c++构造函数）：

        - 通过__DATA，__mod_init_func
        - 通过__TEXT，__init_offsets
     */
}


/***********************************************************************
* _objc_atfork_prepare
* _objc_atfork_parent
* _objc_atfork_child
* Allow ObjC to be used between fork() and exec().
* libc requires this because it has fork-safe functions that use os_objects.
*
* _objc_atfork_prepare() acquires all locks.
* _objc_atfork_parent() releases the locks again.
* _objc_atfork_child() forcibly resets the locks.
**********************************************************************/

// Declare lock ordering.
#if LOCKDEBUG
__attribute__((constructor))
static void defineLockOrder()
{
    // Every lock precedes crashlog_lock
    // on the assumption that fatal errors could be anywhere.
    lockdebug_lock_precedes_lock(&loadMethodLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&classInitLock, &crashlog_lock);
#if __OBJC2__
    lockdebug_lock_precedes_lock(&runtimeLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&DemangleCacheLock, &crashlog_lock);
#else
    lockdebug_lock_precedes_lock(&classLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&methodListLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&NXUniqueStringLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&impLock, &crashlog_lock);
#endif
    lockdebug_lock_precedes_lock(&selLock, &crashlog_lock);
#if CONFIG_USE_CACHE_LOCK
    lockdebug_lock_precedes_lock(&cacheUpdateLock, &crashlog_lock);
#endif
    lockdebug_lock_precedes_lock(&objcMsgLogLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&AltHandlerDebugLock, &crashlog_lock);
    lockdebug_lock_precedes_lock(&AssociationsManagerLock, &crashlog_lock);
    SideTableLocksPrecedeLock(&crashlog_lock);
    PropertyLocks.precedeLock(&crashlog_lock);
    StructLocks.precedeLock(&crashlog_lock);
    CppObjectLocks.precedeLock(&crashlog_lock);

    // loadMethodLock precedes everything
    // because it is held while +load methods run
    lockdebug_lock_precedes_lock(&loadMethodLock, &classInitLock);
#if __OBJC2__
    lockdebug_lock_precedes_lock(&loadMethodLock, &runtimeLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &DemangleCacheLock);
#else
    lockdebug_lock_precedes_lock(&loadMethodLock, &methodListLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &classLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &NXUniqueStringLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &impLock);
#endif
    lockdebug_lock_precedes_lock(&loadMethodLock, &selLock);
#if CONFIG_USE_CACHE_LOCK
    lockdebug_lock_precedes_lock(&loadMethodLock, &cacheUpdateLock);
#endif
    lockdebug_lock_precedes_lock(&loadMethodLock, &objcMsgLogLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &AltHandlerDebugLock);
    lockdebug_lock_precedes_lock(&loadMethodLock, &AssociationsManagerLock);
    SideTableLocksSucceedLock(&loadMethodLock);
    PropertyLocks.succeedLock(&loadMethodLock);
    StructLocks.succeedLock(&loadMethodLock);
    CppObjectLocks.succeedLock(&loadMethodLock);

    // PropertyLocks and CppObjectLocks and AssociationManagerLock 
    // precede everything because they are held while objc_retain() 
    // or C++ copy are called.
    // (StructLocks do not precede everything because it calls memmove only.)
    auto PropertyAndCppObjectAndAssocLocksPrecedeLock = [&](const void *lock) {
        PropertyLocks.precedeLock(lock);
        CppObjectLocks.precedeLock(lock);
        lockdebug_lock_precedes_lock(&AssociationsManagerLock, lock);
    };
#if __OBJC2__
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&runtimeLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&DemangleCacheLock);
#else
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&methodListLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&classLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&NXUniqueStringLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&impLock);
#endif
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&classInitLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&selLock);
#if CONFIG_USE_CACHE_LOCK
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&cacheUpdateLock);
#endif
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&objcMsgLogLock);
    PropertyAndCppObjectAndAssocLocksPrecedeLock(&AltHandlerDebugLock);

    SideTableLocksSucceedLocks(PropertyLocks);
    SideTableLocksSucceedLocks(CppObjectLocks);
    SideTableLocksSucceedLock(&AssociationsManagerLock);

    PropertyLocks.precedeLock(&AssociationsManagerLock);
    CppObjectLocks.precedeLock(&AssociationsManagerLock);
    
#if __OBJC2__
    lockdebug_lock_precedes_lock(&classInitLock, &runtimeLock);
#endif

#if __OBJC2__
    // Runtime operations may occur inside SideTable locks
    // (such as storeWeak calling getMethodImplementation)
    SideTableLocksPrecedeLock(&runtimeLock);
    SideTableLocksPrecedeLock(&classInitLock);
    // Some operations may occur inside runtimeLock.
    lockdebug_lock_precedes_lock(&runtimeLock, &selLock);
#if CONFIG_USE_CACHE_LOCK
    lockdebug_lock_precedes_lock(&runtimeLock, &cacheUpdateLock);
#endif
    lockdebug_lock_precedes_lock(&runtimeLock, &DemangleCacheLock);
#else
    // Runtime operations may occur inside SideTable locks
    // (such as storeWeak calling getMethodImplementation)
    SideTableLocksPrecedeLock(&methodListLock);
    SideTableLocksPrecedeLock(&classInitLock);
    // Method lookup and fixup.
    lockdebug_lock_precedes_lock(&methodListLock, &classLock);
    lockdebug_lock_precedes_lock(&methodListLock, &selLock);
#if CONFIG_USE_CACHE_LOCK
    lockdebug_lock_precedes_lock(&methodListLock, &cacheUpdateLock);
#endif
    lockdebug_lock_precedes_lock(&methodListLock, &impLock);
    lockdebug_lock_precedes_lock(&classLock, &selLock);
    lockdebug_lock_precedes_lock(&classLock, &cacheUpdateLock);
#endif

    // Striped locks use address order internally.
    SideTableDefineLockOrder();
    PropertyLocks.defineLockOrder();
    StructLocks.defineLockOrder();
    CppObjectLocks.defineLockOrder();
}
// LOCKDEBUG
#endif

static bool ForkIsMultithreaded;
void _objc_atfork_prepare()
{
    // Save threaded-ness for the child's use.
    ForkIsMultithreaded = pthread_is_threaded_np();

    lockdebug_assert_no_locks_locked();
    lockdebug_setInForkPrepare(true);

    loadMethodLock.lock();
    PropertyLocks.lockAll();
    CppObjectLocks.lockAll();
    AssociationsManagerLock.lock();
    SideTableLockAll();
    classInitLock.enter();
#if __OBJC2__
    runtimeLock.lock();
    DemangleCacheLock.lock();
#else
    methodListLock.lock();
    classLock.lock();
    NXUniqueStringLock.lock();
    impLock.lock();
#endif
    selLock.lock();
#if CONFIG_USE_CACHE_LOCK
    cacheUpdateLock.lock();
#endif
    objcMsgLogLock.lock();
    AltHandlerDebugLock.lock();
    StructLocks.lockAll();
    crashlog_lock.lock();

    lockdebug_assert_all_locks_locked();
    lockdebug_setInForkPrepare(false);
}

void _objc_atfork_parent()
{
    lockdebug_assert_all_locks_locked();

    CppObjectLocks.unlockAll();
    StructLocks.unlockAll();
    PropertyLocks.unlockAll();
    AssociationsManagerLock.unlock();
    AltHandlerDebugLock.unlock();
    objcMsgLogLock.unlock();
    crashlog_lock.unlock();
    loadMethodLock.unlock();
#if CONFIG_USE_CACHE_LOCK
    cacheUpdateLock.unlock();
#endif
    selLock.unlock();
    SideTableUnlockAll();
#if __OBJC2__
    DemangleCacheLock.unlock();
    runtimeLock.unlock();
#else
    impLock.unlock();
    NXUniqueStringLock.unlock();
    methodListLock.unlock();
    classLock.unlock();
#endif
    classInitLock.leave();

    lockdebug_assert_no_locks_locked();
}

void _objc_atfork_child()
{
    // Turn on +initialize fork safety enforcement if applicable.
    if (ForkIsMultithreaded  &&  !DisableInitializeForkSafety) {
        MultithreadedForkChild = true;
    }

    lockdebug_assert_all_locks_locked();

    CppObjectLocks.forceResetAll();
    StructLocks.forceResetAll();
    PropertyLocks.forceResetAll();
    AssociationsManagerLock.forceReset();
    AltHandlerDebugLock.forceReset();
    objcMsgLogLock.forceReset();
    crashlog_lock.forceReset();
    loadMethodLock.forceReset();
#if CONFIG_USE_CACHE_LOCK
    cacheUpdateLock.forceReset();
#endif
    selLock.forceReset();
    SideTableForceResetAll();
#if __OBJC2__
    DemangleCacheLock.forceReset();
    runtimeLock.forceReset();
#else
    impLock.forceReset();
    NXUniqueStringLock.forceReset();
    methodListLock.forceReset();
    classLock.forceReset();
#endif
    classInitLock.forceReset();

    lockdebug_assert_no_locks_locked();
}


/***********************************************************************
* _objc_init
* Bootstrap initialization.
* 引导程序初始化。
*
* Registers our image notifier with dyld.
* 通过 dyld 来注册我们的境像（image）。
* Called by libSystem BEFORE library initialization time
* library 初始化之前由 libSystem 调用。
**********************************************************************/

void _objc_init(void)
{
    // 用一个静态变量标记，保证只进行一次初始化
    static bool initialized = false;
    if (initialized) return;
    initialized = true;
    
    // fixme defer initialization until an objc-using image is found?
    // fixme 推迟初始化，直到找到一个 objc-using image？
    
    // 读取会影响 runtime 的环境变量
    // 如果需要，还可以打印一些环境变量
    // 环境变量的初始化
    environ_init();
    // thread local stroage
    // 本地线程初始化
    tls_init();
    // 运行 C++静态构造函数
    // 在 dyld 调用静态构造函数之前,libc 调用 _objc_init(), 因此必须自己做
    static_init();
    // runtime 初始化: 主要是 unattachedCategories 和 allocatedClasses 两张表的创建
    runtime_init();
    // 初始化 libobjc 的异常处理系统,由map_images(调用)
    exception_init();
#if __OBJC2__
    // 缓存初始化
    cache_t::init();
#endif
    // 启动回调机制.通常这不会做什么,因为所有的初始化都是 lazily initialized.
    // 但对于某些进程,会加载 trampolines dylib
    _imp_implementationWithBlock_init();
    // 这里 3 个参数要牢记!!!
    // dyld 注册,这里runtime向 dyld 绑定了 3 个回调:
    // 1. map_images: dyld 通过将 images 加载到内存时,会触发该函数.在函数中会加载类和分类
    // 2. load_images: 关联类和分类,并调用类和分类的 load 方法
    // 3. unmap_image: dyld 将 image 移除时,会调用
    _dyld_objc_notify_register(&map_images, load_images, unmap_image);

#if __OBJC2__
    // 标记 _dyld_objc_notify_register 的调用是否已完成。
    didCallDyldNotifyRegister = true;
#endif
}


/***********************************************************************
* _headerForAddress.
* addr can be a class or a category
**********************************************************************/
static const header_info *_headerForAddress(void *addr)
{
#if __OBJC2__
    const char *segnames[] = { "__DATA", "__DATA_CONST", "__DATA_DIRTY" };
#else
    const char *segnames[] = { "__OBJC" };
#endif
    header_info *hi;

    for (hi = FirstHeader; hi != NULL; hi = hi->getNext()) {
        for (size_t i = 0; i < sizeof(segnames)/sizeof(segnames[0]); i++) {
            unsigned long seg_size;            
            uint8_t *seg = getsegmentdata(hi->mhdr(), segnames[i], &seg_size);
            if (!seg) continue;
            
            // Is the class in this header?
            if ((uint8_t *)addr >= seg  &&  (uint8_t *)addr < seg + seg_size) {
                return hi;
            }
        }
    }

    // Not found
    return 0;
}


/***********************************************************************
* _headerForClass
* Return the image header containing this class, or NULL.
* Returns NULL on runtime-constructed classes, and the NSCF classes.
**********************************************************************/
const header_info *_headerForClass(Class cls)
{
    return _headerForAddress(cls);
}


/**********************************************************************
* secure_open
* Securely open a file from a world-writable directory (like /tmp)
* If the file does not exist, it will be atomically created with mode 0600
* If the file exists, it must be, and remain after opening: 
*   1. a regular file (in particular, not a symlink)
*   2. owned by euid
*   3. permissions 0600
*   4. link count == 1
* Returns a file descriptor or -1. Errno may or may not be set on error.
**********************************************************************/
int secure_open(const char *filename, int flags, uid_t euid)
{
    struct stat fs, ls;
    int fd = -1;
    bool truncate = NO;
    bool create = NO;

    if (flags & O_TRUNC) {
        // Don't truncate the file until after it is open and verified.
        truncate = YES;
        flags &= ~O_TRUNC;
    }
    if (flags & O_CREAT) {
        // Don't create except when we're ready for it
        create = YES;
        flags &= ~O_CREAT;
        flags &= ~O_EXCL;
    }

    if (lstat(filename, &ls) < 0) {
        if (errno == ENOENT  &&  create) {
            // No such file - create it
            fd = open(filename, flags | O_CREAT | O_EXCL, 0600);
            if (fd >= 0) {
                // File was created successfully.
                // New file does not need to be truncated.
                return fd;
            } else {
                // File creation failed.
                return -1;
            }
        } else {
            // lstat failed, or user doesn't want to create the file
            return -1;
        }
    } else {
        // lstat succeeded - verify attributes and open
        if (S_ISREG(ls.st_mode)  &&  // regular file?
            ls.st_nlink == 1  &&     // link count == 1?
            ls.st_uid == euid  &&    // owned by euid?
            (ls.st_mode & ALLPERMS) == (S_IRUSR | S_IWUSR))  // mode 0600?
        {
            // Attributes look ok - open it and check attributes again
            fd = open(filename, flags, 0000);
            if (fd >= 0) {
                // File is open - double-check attributes
                if (0 == fstat(fd, &fs)  &&  
                    fs.st_nlink == ls.st_nlink  &&  // link count == 1?
                    fs.st_uid == ls.st_uid  &&      // owned by euid?
                    fs.st_mode == ls.st_mode  &&    // regular file, 0600?
                    fs.st_ino == ls.st_ino  &&      // same inode as before?
                    fs.st_dev == ls.st_dev)         // same device as before?
                {
                    // File is open and OK
                    if (truncate) ftruncate(fd, 0);
                    return fd;
                } else {
                    // Opened file looks funny - close it
                    close(fd);
                    return -1;
                }
            } else {
                // File didn't open
                return -1;
            }
        } else {
            // Unopened file looks funny - don't open it
            return -1;
        }
    }
}


#if TARGET_OS_IPHONE

const char *__crashreporter_info__ = NULL;

const char *CRSetCrashLogMessage(const char *msg)
{
    __crashreporter_info__ = msg;
    return msg;
}
const char *CRGetCrashLogMessage(void)
{
    return __crashreporter_info__;
}

#endif

// TARGET_OS_MAC
#else


#error unknown OS


#endif
