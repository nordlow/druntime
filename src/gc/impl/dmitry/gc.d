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
 * - Use jemalloc `sizeclasses`:
 *   - Add overloads of malloc and qalloc for `sizeclasses`.
 *   - Use static foreach to generated pools for each size class with and without indirections.
 *
 * - Calculate sizeclass at compile-time using next power of 2 of `T.sizeof` for
 *   calls to `new T()` and feed into `N` size-dependent overloads of
 *   `mallocN()`, `callocN()`, `reallocN()` etc.
 *
 * - Use hash-table from basepointer to page index to speed up page-search
 *   ([1]). Use hash-table with open addressing and Fibonacci hashing
 *   (for instance phobos-next open_hashmap_or_hashset.c)
 *
 * - Use `static foreach` when possible to generate, initialize and process
 *   global and thead-local pools of different sizeclasses.
 *
 * - Add run-time information for implicit (by compiler) and explicit (by
 *   developer in library) casting from mutable to `immutable` and, in turn,
 *   `shared` for isolated references.  Typically named: `__cast_immutable`,
 *   `__cast_shared`. To make this convenient the compiler might ahead-of-time
 *   calculate figure out if non-`shared` allocation later must be treated as
 *   `shared` and allocated in the first place on the global GC heap.
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

import gc.config;
import gc.gcinterface;

import rt.util.container.array;

import core.stdc.stdio: printf;
import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
static import core.memory;

extern (C) void onOutOfMemoryError(void* pretend_sideffect = null)
    @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */

enum PAGESIZE = 4096;           // Linux $(shell getconf PAGESIZE)

static immutable sizeclasses = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

debug = PRINTF;

class DmitryGC : GC
{
    __gshared Array!Root roots;
    __gshared Array!Range ranges;

    static void initialize(ref GC gc)
    {
        printf("### %s()\n", __FUNCTION__.ptr);

        import core.stdc.string;

        if (config.gc != "dmitry")
            return;

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
        printf("### %s: \n", __FUNCTION__.ptr);
        if (config.gc != "dmitry")
            return;

        auto instance = cast(DmitryGC) gc;
        instance.Dtor();
        cstdlib.free(cast(void*) instance);
    }

    this()
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    void Dtor()
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    void enable()
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    void disable()
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    void collect() nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    void collectNoStack() nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    void minimize() nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    uint getAttr(void* p) nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        void* p = cstdlib.malloc(size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    BlkInfo qalloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        BlkInfo retval;
        retval.base = malloc(size, bits, ti);
        retval.size = size;
        retval.attr = bits;
        return retval;
    }

    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("### %s(size:%lu, bits:%u)\n", __FUNCTION__.ptr, size, bits);
        void* p = cstdlib.calloc(1, size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("### %s(p:%p, size:%lu, bits:%u)\n", __FUNCTION__.ptr, p, size, bits);
        p = cstdlib.realloc(p, size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        printf("### %s(p:%p, minsize:%lu, maxsize:%lu)\n", __FUNCTION__.ptr, p, minsize, maxsize);
        return 0;
    }

    size_t reserve(size_t size) nothrow
    {
        printf("### %s(size:%lu)\n", __FUNCTION__.ptr, size);
        return 0;
    }

    void free(void* p) nothrow @nogc
    {
        printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        cstdlib.free(p);
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    void* addrOf(void* p) nothrow @nogc
    {
        printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        return null;
    }

    /**
     * Determine the allocated size of pointer p.  If p is an interior pointer
     * or not a gc allocated pointer, return 0.
     */
    size_t sizeOf(void* p) nothrow @nogc
    {
        printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        return 0;
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    BlkInfo query(void* p) nothrow
    {
        printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        return BlkInfo.init;
    }

    core.memory.GC.Stats stats() nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        return typeof(return).init;
    }

    void addRoot(void* p) nothrow @nogc
    {
        printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        roots.insertBack(Root(p));
    }

    void removeRoot(void* p) nothrow @nogc
    {
        printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        foreach (ref r; roots)
        {
            if (r is p)
            {
                r = roots.back;
                roots.popBack();
                return;
            }
        }
        assert(false);
    }

    @property RootIterator rootIter() return @nogc
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        return &rootsApply;
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        foreach (ref r; roots)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        printf("### %s(p:%p, sz:%lu)\n", __FUNCTION__.ptr, p, sz);
        ranges.insertBack(Range(p, p + sz, cast() ti));
    }

    void removeRange(void* p) nothrow @nogc
    {
        printf("### %s(p:%p)\n", __FUNCTION__.ptr, p);
        foreach (ref r; ranges)
        {
            if (r.pbot is p)
            {
                r = ranges.back;
                ranges.popBack();
                return;
            }
        }
        assert(false);
    }

    @property RangeIterator rangeIter() return @nogc
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        return &rangesApply;
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        printf("### %s: \n", __FUNCTION__.ptr);
        foreach (ref r; ranges)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    void runFinalizers(in void[] segment) nothrow
    {
        printf("### %s: \n", __FUNCTION__.ptr);
    }

    bool inFinalizer() nothrow
    {
        return false;
    }
}
