/** This module contains a new attempt at a conservative (and later a precise)
 * GC inspired by Dmitry Olshanky's post "Inside D's GC".
 *
 * Please note that block attribute data must be tracked, or at a minimum, the
 * FINALIZE bit must be tracked for any allocated memory block because calling
 * rt_finalize on a non-object block can result in an access violation.  In the
 * allocator below, this tracking is done via a leading uint bitmask.  A real
 * allocator may do better to store this data separately, similar to the basic
 * GC.
 *
 * Spec:
 *
 * - Support lock-free thread local allocation in separate pools (static foreach generated)
 *   - First as explicit calls to tlmalloc(), tlcalloc(), tlqalloc(), tlrealloc()
 *   - And later automatically inferred by the compiler.
 *
 * - Use jemalloc `size classes`:
 *   - Add overloads of malloc and qalloc for `sizeClasses`.
 *   - Use static foreach to generated pools for each size class with and without indirections.
 *
 * - Calculate size class at compile-time using next power of 2 of `T.sizeof` for
 *   calls to `new T()` and feed into `N` size-dependent overloads of
 *   `mallocN()`, `callocN()`, `reallocN()` etc.
 *
 * - Use hash-table from basepointer to page index to speed up page-search
 *   ([1]). Use hash-table with open addressing and Fibonacci hashing
 *   (for instance phobos-next open_hashmap_or_hashset.c)
 *
 * - Use `static foreach` when possible to generate, initialize and process
 *   global and thead-local pools of different size classes.
 *
 * - Add run-time information for implicit (by compiler) and explicit (by
 *   developer in library) casting from mutable to `immutable` and, in turn,
 *   `shared` for isolated references.  Typically named: `__cast_immutable`,
 *   `__cast_shared`. To make this convenient the compiler might ahead-of-time
 *   calculate figure out if non-`shared` allocation later must be treated as
 *   `shared` and allocated in the first place on the global GC heap.
 *
 * - Mark-phase:
 *   - For each reachable pointer `p`:
 *     - Check if `p` is reachable
 *
 * - Use sizeClass = nextPow2(size-1) given size => 0
 * - Use `os_mem_map` and `os_mem_unmap`
 *
 * - Find first free slot (0) in pageSlotOccupancies bitarray of length using core.bitop. Use my own bitarray.
 *
 * - Key-Question:
 *   - Should slot occupancy status
 *     1. be explicitly stored in a bitarray and allocated in conjunction with pages somehow (more performant for dense representations)
 *        This requires this bitarray to be dynamically expanded and deleted in-place when pages are removed
 *     2. automatically deduced during sweep into a hashset of pointers (more performant for sparse data) and keep some extra
 *
 * References:
 * 1. Inside D's GC:
 *    https://olshansky.me/gc/runtime/dlang/2017/06/14/inside-d-gc.html
 * 2. DIP 46: Region Based Memory Allocation
 *    https://wiki.dlang.org/DIP46
 * 3. Thread-local GC:
 *    https://forum.dlang.org/thread/xiaxgllobsiiuttavivb@forum.dlang.org
 * 4. Thread GC non "stop-the-world"
 *    https://forum.dlang.org/post/dnxgbumzenupviqymhrg@forum.dlang.org
 * 5. Conservative GC: Is It Really That Bad?
 *    https://www.excelsiorjet.com/blog/articles/conservative-gc-is-it-really-that-bad/
 *    https://forum.dlang.org/thread/qperkcrrngfsbpbumydc@forum.dlang.org
 * 6. GC page and block metadata storage
 *    https://forum.dlang.org/thread/fvmiudfposhggpjgtluf@forum.dlang.org
 * 7. Scalable memory allocation using jemalloc
 *    https://www.facebook.com/notes/facebook-engineering/scalable-memory-allocation-using-jemalloc/480222803919/
 * 8. How does jemalloc work? What are the benefits?
 *    https://stackoverflow.com/questions/1624726/how-does-jemalloc-work-what-are-the-benefits
 * 9. What are the advantages and disadvantages of having mark bits together and separate for Garbage Collection
 *    https://stackoverflow.com/questions/23057531/what-are-the-advantages-and-disadvantages-of-having-mark-bits-together-and-separ
 *
 * Copyright: Copyright Per Nordlöw 2018 - .
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Sean Kelly
 */

/*          Copyright Per Nordlöw 2018 - .
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module gc.impl.dmitry.gc;

import gc.os : os_mem_map, os_mem_unmap;
import gc.config;
import gc.gcinterface;

import rt.util.container.array : Array;
import rt.util.container.static_bitarray : StaticBitArray;

import core.stdc.stdio: printf;
import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
static import core.memory;

// debug = PRINTF;

extern (C) void onOutOfMemoryError(void* pretend_sideffect = null)
    @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */

enum PAGESIZE = 4096;           // Linux $(shell getconf PAGESIZE)

/// Possible sizes classes (in bytes).
static immutable sizeClasses = [8,
                                16, // TODO 16 + 8,
                                32, // TODO 32 + 16,
                                64, // TODO 64 + 32,
                                128, // TODO 128 +64,
                                256, // TODO 256 + 128,
                                512, // TODO 512 + 256,
                                1024, // TODO 1024 + 512,
                                2048, // TODO 2048 + 1024,
                                4096];

/// Ceiling to closest to size class of `sz`.
size_t ceilPow2(size_t sz) @safe pure nothrow @nogc
{
    return nextPow2(sz - 1);
}

@safe pure nothrow @nogc unittest
{
    assert(ceilPow2(1) == 1);
    assert(ceilPow2(2) == 2);
    assert(ceilPow2(3) == 4);
    assert(ceilPow2(4) == 4);
    assert(ceilPow2(5) == 8);
    assert(ceilPow2(6) == 8);
    assert(ceilPow2(7) == 8);
    assert(ceilPow2(8) == 8);
    assert(ceilPow2(9) == 16);
}

/// Small slot foreach slot contains `wordCount` machine words.
struct SmallSlot(uint wordCount)
if (wordCount >= 1)
{
    void[8*wordCount] raw;      // raw slot data (bytes)
}

@safe pure nothrow @nogc unittest
{
    SmallSlot!(1) x;
    SmallSlot!(1) y;
}

/// Small page storing slots of size `sizeClass`.
struct SmallPage(uint sizeClass)
if (sizeClass >= sizeClasses[0] &&
    sizeClass % 8 == 0)
{
    enum wordCount = sizeClass/8;
    enum slotCount = PAGESIZE/sizeClass;
    alias Slot = SmallSlot!(wordCount);

    Slot[slotCount] slots;
    static assert(slots.sizeof == PAGESIZE);
}

@safe pure nothrow @nogc unittest
{
    static foreach (sizeClass; sizeClasses)
    {
        {
            SmallPage!(sizeClass) x;
            SmallPage!(sizeClass) y;
            static assert(!__traits(compiles, { SmallPage!(sizeClass+1) _; }));
        }
    }
}

struct SmallPageTable(uint sizeClass)
{
    alias Page = SmallPage!(sizeClass);
    Page* pagePtr;
    enum slotCount = PAGESIZE/sizeClass;

    // bit i indicates if slot i in `*pagePtr` currently has a defined value
    StaticBitArray!(slotCount) slotUsages;
}

/// Small pool of pages.
struct SmallPool(uint sizeClass, bool pointerFlag)
if (sizeClass >= sizeClasses[0])
{
    alias Page = SmallPage!(sizeClass);

    void* allocateNext() @trusted // pure nothrow @nogc
    {
        debug(PRINTF) printf("### %s()\n", __FUNCTION__.ptr);
        const pageIndex = slotIndex / Page.slotCount;
        const needNewPage = (slotIndex % Page.slotCount == 0);
        if (needNewPage)
        {
            Page* pagePtr = cast(Page*)os_mem_map(PAGESIZE);
            debug(PRINTF) printf("### %s(): pagePtr:%p\n", __FUNCTION__.ptr, pagePtr);
            pageTables.insertBack(SmallPageTable!sizeClass(pagePtr));

            pageTables.ptr[pageIndex].slotUsages[0] = true; // mark slot
            slotIndex = 1;
            return &pagePtr.slots[0]; // first slot
        }
        else
        {
            pageTables.ptr[pageIndex].slotUsages[slotIndex] = true; // mark slot
            return &pageTables.ptr[pageIndex].pagePtr.slots[slotIndex++];
        }
    }

    Array!(SmallPageTable!sizeClass) pageTables;
    size_t slotIndex = 0;       // index to first free slot in pool across multiple page
}

// TODO @safe pure nothrow @nogc
unittest
{
    static foreach (sizeClass; sizeClasses)
    {
        {
            SmallPool!(sizeClass, false) x;
        }
    }
}

/// All small pools.
struct SmallPools
{
    BlkInfo qalloc(size_t size, uint bits) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);

        BlkInfo retval = void;
        retval.attr = bits;

        // TODO optimize this:
        // TODO move this to compile-time and add malloc overloads for each size class
        retval.size = ceilPow2(size);
        if (retval.size < sizeClasses[0])
        {
            retval.size = sizeClasses[0];
        }

    top:
        switch (retval.size)
        {
            static foreach (sizeClass; sizeClasses)
            {
            case sizeClass:
                mixin(`retval.base = valuePool` ~ sizeClass.stringof ~ `.allocateNext();`);
                break top;
            }
        default:
            retval.base = null;
            // assert(0, "Handle other retval.size");
        }

        return retval;
    }
private:
    static foreach (sizeClass; sizeClasses)
    {
        mixin(`SmallPool!(sizeClass, false) valuePool` ~ sizeClass.stringof ~ `;`);
        mixin(`SmallPool!(sizeClass, true) pointerPool` ~ sizeClass.stringof ~ `;`);
    }
}

struct Store
{
    Array!Root roots;
    Array!Range ranges;
}

class DmitryGC : GC
{
    __gshared Store globalStore;

    // __gshared has no measureable overhead here
    __gshared SmallPools globalSmallPools; // TODO look at gcx in conservative

    static void initialize(ref GC gc)
    {
        debug(PRINTF) printf("### %s()\n", __FUNCTION__.ptr);

        if (config.gc != "dmitry")
            return;

        import core.stdc.string;
        auto p = cstdlib.malloc(__traits(classInstanceSize, DmitryGC));
        if (!p)
            onOutOfMemoryError();

        auto init = typeid(DmitryGC).initializer();
        assert(init.length == __traits(classInstanceSize, DmitryGC));
        auto instance = cast(DmitryGC) memcpy(p, init.ptr, init.length);
        instance.__ctor();

        gc = instance;
    }

    static void finalize(ref GC gc)
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        if (config.gc != "dmitry")
            return;

        auto instance = cast(DmitryGC) gc;
        instance.Dtor();
        cstdlib.free(cast(void*) instance);
    }

    this()
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    void Dtor()
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    void enable()
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    void disable()
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    void collect() nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    void collectNoStack() nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    void minimize() nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    uint getAttr(void* p) nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        void* p = globalSmallPools.qalloc(size, bits).base;
        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    BlkInfo qalloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        return globalSmallPools.qalloc(size, bits);
    }

    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        void* p = cstdlib.calloc(1, size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        debug(PRINTF) printf("### %s(p:%p, size:%lu, bits:%u)\n", __FUNCTION__.ptr, p, size, bits);
        p = cstdlib.realloc(p, size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        debug(PRINTF) printf("### %s(p:%p, minsize:%lu, maxsize:%lu)\n", __FUNCTION__.ptr, p, minsize, maxsize);
        return 0;
    }

    size_t reserve(size_t size) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu)\n", __FUNCTION__.ptr, size);
        return 0;
    }

    void free(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        cstdlib.free(p);
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    void* addrOf(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        return null;
    }

    /**
     * Determine the allocated size of pointer p.  If p is an interior pointer
     * or not a gc allocated pointer, return 0.
     */
    size_t sizeOf(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        return 0;
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    BlkInfo query(void* p) nothrow
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        return BlkInfo.init;
    }

    core.memory.GC.Stats stats() nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        return typeof(return).init;
    }

    void addRoot(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        globalStore.roots.insertBack(Root(p));
    }

    void removeRoot(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        foreach (ref r; globalStore.roots)
        {
            if (r is p)
            {
                r = globalStore.roots.back;
                globalStore.roots.popBack();
                return;
            }
        }
        assert(false);
    }

    @property RootIterator rootIter() return @nogc
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        return &rootsApply;
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        foreach (ref r; globalStore.roots)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p, sz:%lu)\n", __FUNCTION__.ptr, p, sz);
        globalStore.ranges.insertBack(Range(p, p + sz, cast() ti));
    }

    void removeRange(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        foreach (ref r; globalStore.ranges)
        {
            if (r.pbot is p)
            {
                r = globalStore.ranges.back;
                globalStore.ranges.popBack();
                return;
            }
        }
        assert(false);
    }

    @property RangeIterator rangeIter() return @nogc
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        return &rangesApply;
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        foreach (ref r; globalStore.ranges)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    void runFinalizers(in void[] segment) nothrow
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
    }

    bool inFinalizer() nothrow
    {
        return false;
    }
}

private enum PowType
{
    floor,
    ceil
}

private T powIntegralImpl(PowType type, T)(T val)
{
    pragma(inline, true);
    import core.bitop : bsr;
    if (val == 0 || (type == PowType.ceil && (val > T.max / 2 || val == T.min)))
    {
        return 0;
    }
    else
    {
        return (T(1) << bsr(val) + type);
    }
}

private T nextPow2(T)(const T val)
if (is(T == size_t) ||
    is(T == uint))
{
    return powIntegralImpl!(PowType.ceil)(val);
}
