/** This module contains a new attempt a conservative GC inspired by Dmitry
 * Olshanky's post "Inside D's GC".
 *
 * See_Also: https://olshansky.me/gc/runtime/dlang/2017/06/14/inside-d-gc.html
 *
 * This module contains a minimal garbage collector implementation according to
 * published requirements.  This library is mostly intended to serve as an
 * example, but it is usable in applications which do not rely on a garbage
 * collector to clean up memory (ie. when dynamic array resizing is not used,
 * and all memory allocated with 'new' is freed deterministically with
 * 'delete').
 *
 * Please note that block attribute data must be tracked, or at a minimum, the
 * FINALIZE bit must be tracked for any allocated memory block because calling
 * rt_finalize on a non-object block can result in an access violation.  In the
 * allocator below, this tracking is done via a leading uint bitmask.  A real
 * allocator may do better to store this data separately, similar to the basic
 * GC.
 *
 * Copyright: Copyright Sean Kelly 2005 - 2016.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Sean Kelly
 */

/*          Copyright Sean Kelly 2005 - 2016.
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

class DmitryGC : GC
{
    __gshared Array!Root roots;
    __gshared Array!Range ranges;

    static void initialize(ref GC gc)
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);

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
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        if (config.gc != "dmitry")
            return;

        auto instance = cast(DmitryGC) gc;
        instance.Dtor();
        cstdlib.free(cast(void*) instance);
    }

    this()
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    void Dtor()
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    void enable()
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    void disable()
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    void collect() nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    void collectNoStack() nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    void minimize() nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    uint getAttr(void* p) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("ENTERING: %s: size=%lu bits=%u\n", __FUNCTION__.ptr, size, bits);
        void* p = cstdlib.malloc(size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    BlkInfo qalloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        BlkInfo retval;
        retval.base = malloc(size, bits, ti);
        retval.size = size;
        retval.attr = bits;
        return retval;
    }

    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        void* p = cstdlib.calloc(1, size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        p = cstdlib.realloc(p, size);

        if (size && p is null)
            onOutOfMemoryError();
        return p;
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    size_t reserve(size_t size) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    void free(void* p) nothrow @nogc
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        cstdlib.free(p);
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    void* addrOf(void* p) nothrow @nogc
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return null;
    }

    /**
     * Determine the allocated size of pointer p.  If p is an interior pointer
     * or not a gc allocated pointer, return 0.
     */
    size_t sizeOf(void* p) nothrow @nogc
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return 0;
    }

    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    BlkInfo query(void* p) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return BlkInfo.init;
    }

    core.memory.GC.Stats stats() nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return typeof(return).init;
    }

    void addRoot(void* p) nothrow @nogc
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        roots.insertBack(Root(p));
    }

    void removeRoot(void* p) nothrow @nogc
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
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
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return &rootsApply;
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        foreach (ref r; roots)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        printf("ENTERING: %s: p=%p, sz=%lu\n", __FUNCTION__.ptr, p, sz);
        ranges.insertBack(Range(p, p + sz, cast() ti));
    }

    void removeRange(void* p) nothrow @nogc
    {
        printf("ENTERING: %s: p=%p\n", __FUNCTION__.ptr, p);
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
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        return &rangesApply;
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
        foreach (ref r; ranges)
        {
            if (auto result = dg(r))
                return result;
        }
        return 0;
    }

    void runFinalizers(in void[] segment) nothrow
    {
        printf("ENTERING: %s: \n", __FUNCTION__.ptr);
    }

    bool inFinalizer() nothrow
    {
        return false;
    }
}
