/** A new GC inspired by references [0] and [1].
 *
 * Spec:
 *
 * - Make it conservative for now and later merge Rainer's precise add-ons.
 *
 * - Pools types are segregated on both
 *   - size class
 *   - scanningness: (whether they may contain pointers or not)
 *   - finalizers (for class or struct)
 *   leading `number_of_size_classes * 2 * 2` different pool kinds.
 *
 *   Use `static foreach` plus `mixin` to construct and use instances of these
 *   different pool types without code duplication.
 *
 *   This makes the GC sweep-free (as in [0]) because only one continuous bitmap
 *   `slotUsages` needs to be kept during the normal allocation phase. During
 *   mark-phase an equally sized bitmap, `slotMarks`, is zero-constructed using
 *   mmap and filled in as pointers to slots are discovered. When mark-phase is
 *   complete this new bitmap `slotMarks` replaces `slotUsages`. This may or may
 *   not work for pools of objects that have finalizers (TODO find out).
 *
 *   When the allocator has grown too large it will be neccessary to indeed do
 *   sweeps to free pages. But such sweeps can be triggered by low memory and
 *   doesn't have to do a complete sweep if low latency is needed.
 *
 * - Use jemalloc `size classes`:
 *   - For size classes in between powers of two we can allocate pages in 3*n chunks
 *
 * - Calculate size class at compile-time using next power of 2 of `T.sizeof`
 * for calls to `new T()` and feed into `N` size-dependent overloads of
 *   `mallocN()`, `callocN()`, `reallocN()` etc.
 *
 * - Use hash-table from basepointer to page index to speed up page-search
 *   ([1]). Use hash-table with open addressing and Fibonacci hashing
 *   (for instance phobos-next open_hashmap_or_hashset.c)
 *
 * - Add run-time information for implicit (by compiler) and explicit (by
 *   developer in library) casting from mutable to `immutable` and, in turn,
 *   `shared` for isolated references.  Typically named: `__cast_immutable`,
 *   `__cast_shared`. To make this convenient the compiler might ahead-of-time
 *   calculate figure out if non-`shared` allocation later must be treated as
 *   `shared` and allocated in the first place on the global GC heap.
 *
 * - Mark-phase:
 *   - For each potential pointer `p` in stack
 *     - Check if `p` lies within address bounds of all pools.
 *     - If so, find page storing that pointer (using a hashmap from base
 * pointers to pages)
 *     - If that slot lies in a pool and
 *          and that slot belongs to a pool whols element types may contain
 * pointers that slot hasn't yet been marked scan that slot
 *     - Finally mark slot
 *
 * - Find first free slot (0) in pageSlotOccupancies bitarray of length using
 * core.bitop. Use my own bitarray.
 *
 * - Key-Question:
 *   - Should slot occupancy status
 *     1. be explicitly stored in a bitarray and allocated in conjunction with
 * pages somehow (more performant for dense representations) This requires this
 * bitarray to be dynamically expanded and deleted in-place when pages are
 * removed
 *     2. automatically deduced during sweep into a hashset of pointers (more
 * performant for sparse data) and keep some extra
 *
 * - Note: Please note that block attribute data must be tracked, or at a
 *   minimum, the FINALIZE bit must be tracked for any allocated memory block
 *   because calling rt_finalize on a non-object block can result in an access
 *   violation.  In the allocator below, this tracking is done via a leading
 *   uint bitmask.  A real allocator may do better to store this data
 *   separately, similar to the basic GC.
 *
 * TODO
 * - TODO check why finalizers are being called for classes and structs without
 * destructors
 * - check ti to check if we should use value or ref pool
 * - TODO use `slotUsages` during allocation
 * - TODO use `slotMarks` during sweep
 * - TODO figure out if we need medium and large sized slots as outline in [1].
 *
 * References:
 * 0. Proposal: Dense mark bits and sweep-free allocation
 *    https://github.com/golang/proposal/blob/master/design/12800-sweep-free-alloc.md
 * and in turn https://github.com/golang/go/issues/12800
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
 * 9. What are the advantages and disadvantages of having mark bits together and
 * separate for Garbage Collection
 *    https://stackoverflow.com/questions/23057531/what-are-the-advantages-and-disadvantages-of-having-mark-bits-together-and-separ
 *
 * Copyright: Copyright Per Nordlöw 2018 - .
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Per Nordlöw
 */

/*          Copyright Per Nordlöw 2018 - .
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module gc.impl.fastalloc.gc;

import gc.os : os_mem_map, os_mem_unmap;
import gc.config;
import gc.gcinterface;

import rt.util.container.paged_dynamic_array : Array = PagedDynamicArray;
import rt.util.container.static_bitarray : StaticBitArray;

import core.stdc.stdio: printf;
import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
static import core.memory;

// debug = PRINTF;

extern (C) void onOutOfMemoryError(void* pretend_sideffect = null)
    @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */

private
{
    extern (C)
    {
        // to allow compilation of this module without access to the rt package,
        //  make these functions available from rt.lifetime
        void rt_finalizeFromGC(void* p, size_t size, uint attr) nothrow;
        int rt_hasFinalizerInSegment(void* p, size_t size, uint attr, in void[] segment) nothrow;

        // Declared as an extern instead of importing core.exception
        // to avoid inlining - see issue 13725.
        void onInvalidMemoryOperationError() @nogc nothrow;
        void onOutOfMemoryErrorNoGC() @nogc nothrow;
    }
}

enum PAGESIZE = 4096;           // Linux $(shell getconf PAGESIZE)

/// Small slot sizes classes (in bytes).
static immutable smallSizeClasses = [8,
                                     16, // TODO 16 + 8,
                                     32, // TODO 32 + 16,
                                     64, // TODO 64 + 32,
                                     128, // TODO 128 +64,
                                     256, // TODO 256 + 128,
                                     512, // TODO 512 + 256,
                                     1024, // TODO 1024 + 512,
                                     2048, // TODO 2048 + 1024,
    ];

/// Medium slot sizes classes (in bytes).
static immutable mediumSizeClasses = [1 << 12, // 4096
                                      1 << 13, // 8192
                                      1 << 14, // 16384
                                      1 << 15, // 32768
                                      1 << 16, // 65536
    ];

/// Ceiling to closest to size class of `sz`.
size_t ceilPow2(size_t sz) @safe pure nothrow @nogc
{
    return nextPow2(sz - 1);
}

@safe pure nothrow @nogc unittest
{
    // TODO assert(ceilPow2(1) == 1);
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
if (sizeClass >= smallSizeClasses[0] &&
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
    static foreach (sizeClass; smallSizeClasses)
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

    // bit `i` indicates if slot `i` in `*pagePtr` currently contains a initialized value
    StaticBitArray!(slotCount) slotUsages; // TODO benchmark with a byte-array instead for comparison

    // bit `i` indicates if slot `i` in `*pagePtr` has been marked
    StaticBitArray!(slotCount) slotMarks;
}

/// Small pool of pages.
struct SmallPool(uint sizeClass, bool pointerFlag)
if (sizeClass >= smallSizeClasses[0])
{
    alias Page = SmallPage!(sizeClass);

    this(size_t pageTableCapacity)
    {
        pageTables.capacity = pageTableCapacity;
    }

    void* allocateNext() @trusted // pure nothrow @nogc
    {
        version(LDC) pragma(inline, true);

        // TODO scan `slotUsages` at slotIndex using core.bitop.bsf to find
        // first free page if any. Use modification of `indexOfFirstSetBit` that
        // takes startIndex being `slotIndex` If no hit set `slotIndex` to
        // `Page.slotCount`
        // TODO instead of this find next set bit at `slotIndex` in
        // `slotUsages` unless whole current `slotUsages`-word is all zero.

        immutable pageIndex = slotIndex / Page.slotCount;
        immutable needNewPage = (slotIndex % Page.slotCount == 0);

        if (needNewPage)
        {
            Page* pagePtr = cast(Page*)os_mem_map(PAGESIZE);
            debug(PRINTF) printf("### %s(): pagePtr:%p\n", __FUNCTION__.ptr, pagePtr);
            pageTables.insertBack(SmallPageTable!sizeClass(pagePtr));

            pageTables.ptr[pageIndex].slotUsages[0] = true; // mark slot

            debug(PRINTF) printf("### %s(): slotIndex:%lu\n", __FUNCTION__.ptr, 0);

            auto slotPtr = pagePtr.slots.ptr; // first slot
            slotIndex = 1;
            return slotPtr;
        }
        else
        {
            debug(PRINTF) printf("### %s(): slotIndex:%lu\n", __FUNCTION__.ptr, slotIndex);
            pageTables.ptr[pageIndex].slotUsages[slotIndex] = true; // mark slot
            return &pageTables.ptr[pageIndex].pagePtr.slots.ptr[slotIndex++];
        }
    }

    Array!(SmallPageTable!sizeClass) pageTables;
    size_t slotIndex = 0;       // index to first free slot in pool across multiple page
}

// TODO @safe pure nothrow @nogc
unittest
{
    static foreach (sizeClass; smallSizeClasses)
    {
        {
            SmallPool!(sizeClass, false) x;
        }
    }
}

/// All small pools.
struct SmallPools
{
    this(size_t pageTableCapacity)
    {
        static foreach (sizeClass; smallSizeClasses)
        {
            // Quote from https://olshansky.me/gc/runtime/dlang/2017/06/14/inside-d-gc.html
            // "Fine grained locking from the start, I see no problem with per pool locking."
            mixin(`this.unscannedPool` ~ sizeClass.stringof ~ ` = SmallPool!(sizeClass, false)(pageTableCapacity);`);
            mixin(`this.scannedPool`    ~ sizeClass.stringof ~ ` = SmallPool!(sizeClass, true)(pageTableCapacity);`);
        }
    }
    BlkInfo qalloc(size_t size, uint bits) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);

        BlkInfo blkinfo = void;
        blkinfo.attr = bits;

        // TODO optimize this:
        blkinfo.size = ceilPow2(size);
        if (blkinfo.size < smallSizeClasses[0])
        {
            blkinfo.size = smallSizeClasses[0];
        }

    top:
        switch (blkinfo.size)
        {
            static foreach (sizeClass; smallSizeClasses)
            {
            case sizeClass:
                if (bits & BlkAttr.NO_SCAN) // no scanning needed
                {
                    mixin(`blkinfo.base = unscannedPool` ~ sizeClass.stringof ~ `.allocateNext();`);
                }
                else
                {
                    mixin(`blkinfo.base = scannedPool` ~ sizeClass.stringof ~ `.allocateNext();`);
                }
                break top;
            }
        default:
            blkinfo.base = null;
            printf("### %s(size:%lu, bits:%u) Cannot handle blkinfo.size:%lu\n", __FUNCTION__.ptr, size, bits, blkinfo.size);
            onOutOfMemoryError();
            assert(0, "Handle other blkinfo.size");
        }

        return blkinfo;
    }
private:
    static foreach (sizeClass; smallSizeClasses)
    {
        // Quote from https://olshansky.me/gc/runtime/dlang/2017/06/14/inside-d-gc.html
        // "Fine grained locking from the start, I see no problem with per pool locking."
        mixin(`SmallPool!(sizeClass, false) unscannedPool` ~ sizeClass.stringof ~ `;`);
        mixin(`SmallPool!(sizeClass, true) scannedPool` ~ sizeClass.stringof ~ `;`);
    }
}
// pragma(msg, "SmallPools.sizeof: ", SmallPools.sizeof);

enum pageTableCapacityDefault = 256*PAGESIZE; // eight pages

struct Gcx
{
    this(size_t pageTableCapacity) // 1 one megabyte per table
    {
        this.smallPools = SmallPools(pageTableCapacity);
    }
    Array!Root roots;
    Array!Range ranges;
    SmallPools smallPools;
    uint disabled; // turn off collections if >0
}

Gcx tlGcx;                      // thread-local allocator instance
static this()
{
    tlGcx = Gcx(pageTableCapacityDefault);
}

// size class specific overloads only for thread-local GC
extern (C)
{
    static foreach (sizeClass; smallSizeClasses)
    {
        /* TODO use template `mixin` containing, in turn, a `mixin` for generating
         * the symbol names `gc_tlmalloc_32`, `unscannedPool32` and
         * `scannedPool32` for sizeClass `32`.
         *
         * TODO Since https://github.com/dlang/dmd/pull/8813 we can now use:
         * `mixin("gc_tlmalloc_", sizeClass);` for symbol generation
         */
        mixin(`
        void* gc_tlmalloc_` ~ sizeClass.stringof ~ `(uint ba = 0) @trusted nothrow
        {
            if (ba & BlkAttr.NO_SCAN) // no scanning needed
                return tlGcx.smallPools.unscannedPool` ~ sizeClass.stringof ~ `.allocateNext();
            else
                return tlGcx.smallPools.scannedPool` ~ sizeClass.stringof ~ `.allocateNext();
        }
`);
    }
}

class FastallocGC : GC
{
    import core.internal.spinlock;
    static gcLock = shared(AlignedSpinLock)(SpinLock.Contention.lengthy);
    static bool _inFinalizer;

    // global allocator (`__gshared`)
    __gshared Gcx gGcx;

    // lock GC, throw InvalidMemoryOperationError on recursive locking during finalization
    static void lockNR() @nogc nothrow
    {
        if (_inFinalizer)
            onInvalidMemoryOperationError();
        gcLock.lock();
    }

    static void initialize(ref GC gc)
    {
        debug(PRINTF) printf("### %s()\n", __FUNCTION__.ptr);

        if (config.gc != "fastalloc")
            return;

        import core.stdc.string;
        auto p = cstdlib.malloc(__traits(classInstanceSize, FastallocGC));
        if (!p)
            onOutOfMemoryError();

        auto init = typeid(FastallocGC).initializer();
        assert(init.length == __traits(classInstanceSize, FastallocGC));
        auto instance = cast(FastallocGC)memcpy(p, init.ptr, init.length);
        instance.__ctor();

        instance.gGcx = Gcx(pageTableCapacityDefault);

        gc = instance;
    }

    static void finalize(ref GC gc)
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        if (config.gc != "fastalloc")
            return;

        auto instance = cast(FastallocGC) gc;
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
        static void go(Gcx* tlGcx) nothrow
        {
            tlGcx.disabled--;
        }
        runLocked!(go)(&tlGcx);
    }

    void disable()
    {
        debug(PRINTF) printf("### %s: \n", __FUNCTION__.ptr);
        static void go(Gcx* tlGcx) nothrow
        {
            tlGcx.disabled++;
        }
        runLocked!(go)(&tlGcx);
    }

    auto runLocked(alias func, Args...)(auto ref Args args)
    {
        debug(PROFILE_API) immutable tm = (config.profile > 1 ? currTime.ticks : 0);
        lockNR();
        scope (failure) gcLock.unlock();
        debug(PROFILE_API) immutable tm2 = (config.profile > 1 ? currTime.ticks : 0);

        static if (is(typeof(func(args)) == void))
            func(args);
        else
            auto res = func(args);

        debug(PROFILE_API) if (config.profile > 1) { lockTime += tm2 - tm; }
        gcLock.unlock();

        static if (!is(typeof(func(args)) == void))
            return res;
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
        lockNR();
        scope (failure) gcLock.unlock();
        void* p = gGcx.smallPools.qalloc(size, bits).base;
        gcLock.unlock();
        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    BlkInfo qalloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        lockNR();
        scope (failure) gcLock.unlock();
        BlkInfo blkinfo = gGcx.smallPools.qalloc(size, bits);
        gcLock.unlock();
        if (size && blkinfo.base is null)
            onOutOfMemoryError();
        return blkinfo;
    }

    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        debug(PRINTF) printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        lockNR();
        scope (failure) gcLock.unlock();
        void* p = gGcx.smallPools.qalloc(size, bits).base;
        gcLock.unlock();
        if (size && p is null)
            onOutOfMemoryError();
        import core.stdc.string : memset;
        memset(p, 0, size);     // zero
        // why is this slower than memset? (cast(size_t*)p)[0 .. size/size_t.sizeof] = 0;
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
        tlGcx.roots.insertBack(Root(p));
    }

    void removeRoot(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        foreach (ref r; tlGcx.roots)
        {
            if (r is p)
            {
                r = tlGcx.roots.back;
                tlGcx.roots.popBack();
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
        foreach (ref r; tlGcx.roots)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p, sz:%lu)\n", __FUNCTION__.ptr, p, sz);
        tlGcx.ranges.insertBack(Range(p, p + sz, cast() ti));
    }

    void removeRange(void* p) nothrow @nogc
    {
        debug(PRINTF) printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        foreach (ref r; tlGcx.ranges)
        {
            if (r.pbot is p)
            {
                r = tlGcx.ranges.back;
                tlGcx.ranges.popBack();
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
        foreach (ref r; tlGcx.ranges)
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
