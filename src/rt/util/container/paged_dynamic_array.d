/**
 * Array container with paged allocation for internal usage.
 *
 * Copyright: Copyright Per Nordlöw 2018.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Per Nordlöw
 */
module rt.util.container.paged_dynamic_array;

static import common = rt.util.container.common;
import core.stdc.stdio: printf;

version = PRINTF;

struct PagedDynamicArray(T)
{
    import gc.os : os_mem_map, os_mem_unmap;
    import core.exception : onOutOfMemoryErrorNoGC;

    @safe nothrow @nogc:

    @disable this(this);

    enum PAGESIZE = 4096;       // Linux $(shell getconf PAGESIZE)

    ~this()
    {
        reset();
    }

    void reset()
    {
        length = 0;
    }

    @property size_t length() const
    {
        return _length;
    }

    @property size_t capacityInBytes() const
    {
        pragma(inline, true);
        return _capacityInPages*PAGESIZE;
    }

    @property void length(size_t newLength) @trusted
    {
        import core.checkedint : mulu;

        if (newLength*T.sizeof > capacityInBytes) // common case first
        {
            bool overflow = false;
            const size_t reqsize = mulu(T.sizeof, newLength, overflow);
            const size_t newCapacityInPages = reqsize/PAGESIZE + (reqsize%PAGESIZE ? 1 : 0);
            version(PRINTF) printf("### %s() newCapacityInPages:%lu\n", __FUNCTION__.ptr, newCapacityInPages);
            if (overflow)
            {
                onOutOfMemoryErrorNoGC();
            }

            import core.internal.traits : hasElaborateDestructor;
            static if (hasElaborateDestructor!T)
            {
                static assert("destroy T");
                //
                // if (newLength < _length)
                // {
                //     foreach (ref val; _ptr[newLength .. _length])
                //     {
                //         common.destroy(val);
                //     }
                // }
            }

            const newCapacityInBytes = newCapacityInPages*PAGESIZE;

            T* newPtr;
            version(linux)
            {
                if (_ptr !is null)  // if should do remap
                {
                    _ptr = cast(T*)mremap(_ptr, capacityInBytes, newCapacityInBytes, MREMAP_MAYMOVE);
                    goto done;
                }
            }

            newPtr = cast(T*)os_mem_map(newCapacityInBytes);
            import core.stdc.string : memcpy;
            if (_ptr !is null)
            {
                memcpy(newPtr, _ptr, capacityInBytes); // TODO can we copy pages faster than this?
                os_mem_unmap(_ptr, capacityInBytes);
            }
            _ptr = newPtr;

        done:
            _capacityInPages = newCapacityInPages;

            // rely on mmap zeroing for us
            // if (newLength > _length)
            // {
            //     foreach (ref val; _ptr[_length .. newLength])
            //     {
            //         common.initialize(val);
            //     }
            // }
        }
        else if (newLength == 0)
        {
            version(PRINTF) printf("### %s() zeroed\n", __FUNCTION__.ptr);
            if (_ptr != null)
            {
                os_mem_unmap(_ptr, capacityInBytes);
                _ptr = null;
            }
            _capacityInPages = 0;
        }

        _length = newLength;
    }

    @property bool empty() const
    {
        return !length;
    }

    @property ref inout(T) front() inout
    in { assert(!empty); }
    do
    {
        return _ptr[0];
    }

    @property ref inout(T) back() inout @trusted
    in { assert(!empty); }
    do
    {
        return _ptr[_length - 1];
    }

    ref inout(T) opIndex(size_t idx) inout @trusted
    in { assert(idx < length); }
    do
    {
        return _ptr[idx];
    }

    inout(T)[] opSlice() inout @trusted
    {
        return _ptr[0 .. _length];
    }

    inout(T)[] opSlice(size_t a, size_t b) inout @trusted
    in { assert(a < b && b <= length); }
    do
    {
        return _ptr[a .. b];
    }

    inout(T)* ptr() inout @system
    {
        return _ptr;
    }

    alias length opDollar;

    void insertBack()(auto ref T val) @trusted
    {
        import core.checkedint : addu;
        bool overflow = false;
        const size_t newlength = addu(length, 1, overflow);
        if (overflow)
        {
            onOutOfMemoryErrorNoGC();
        }
        length = newlength;
        back = val;
    }

    void popBack() @system
    {
        // TODO destroy back element if needed
        length = length - 1;
    }

    void remove(size_t idx) @system
    in { assert(idx < length); }
    do
    {
        foreach (i; idx .. length - 1)
            _ptr[i] = _ptr[i+1];
        popBack();
    }

    void swap(ref PagedDynamicArray other) @trusted
    {
        auto ptr = _ptr;
        _ptr = other._ptr;
        other._ptr = ptr;
        immutable len = _length;
        _length = other._length;
        other._length = len;
    }

    invariant
    {
        assert(!_ptr == !_length);
    }

private:
    T* _ptr;
    size_t _length;
    size_t _capacityInPages;    // of size `PAGESIZE`
}

version(linux)
{
    enum MREMAP_MAYMOVE = 1;
    nothrow @nogc:
    extern(C) void *mremap(void *old_address, size_t old_size,
                           size_t new_size, int flags, ... /* void *new_address */);

}

unittest
{
    PagedDynamicArray!size_t ary;

    assert(ary[] == []);
    ary.insertBack(5);
    assert(ary[] == [5]);
    assert(ary[$-1] == 5);
    ary.popBack();
    assert(ary[] == []);
    ary.insertBack(0);
    ary.insertBack(1);
    assert(ary[] == [0, 1]);
    assert(ary[0 .. 1] == [0]);
    assert(ary[1 .. 2] == [1]);
    assert(ary[$ - 2 .. $] == [0, 1]);
    size_t idx;
    foreach (val; ary) assert(idx++ == val);
    foreach_reverse (val; ary) assert(--idx == val);
    foreach (i, val; ary) assert(i == val);
    foreach_reverse (i, val; ary) assert(i == val);

    ary.insertBack(2);
    ary.remove(1);
    assert(ary[] == [0, 2]);

    assert(!ary.empty);
    ary.reset();
    assert(ary.empty);
    ary.insertBack(0);
    assert(!ary.empty);
    destroy(ary);
    assert(ary.empty);

    // not copyable
    static assert(!__traits(compiles, { PagedDynamicArray!size_t ary2 = ary; }));
    PagedDynamicArray!size_t ary2;
    static assert(!__traits(compiles, ary = ary2));
    static void foo(PagedDynamicArray!size_t copy) {}
    static assert(!__traits(compiles, foo(ary)));

    ary2.insertBack(0);
    assert(ary.empty);
    assert(ary2[] == [0]);
    ary.swap(ary2);
    assert(ary[] == [0]);
    assert(ary2.empty);
}

// unittest
// {
//     alias RC = common.RC;
//     PagedDynamicArray!RC ary;

//     size_t cnt;
//     assert(cnt == 0);
//     ary.insertBack(RC(&cnt));
//     assert(cnt == 1);
//     ary.insertBack(RC(&cnt));
//     assert(cnt == 2);
//     ary.back = ary.front;
//     assert(cnt == 2);
//     ary.popBack();
//     assert(cnt == 1);
//     ary.popBack();
//     assert(cnt == 0);
// }

unittest
{
    import core.exception;
    try
    {
        // Overflow ary.length.
        auto ary = PagedDynamicArray!size_t(cast(size_t*)0xdeadbeef, -1);
        ary.insertBack(0);
    }
    catch (OutOfMemoryError)
    {
    }
    try
    {
        // Overflow requested memory size for common.xrealloc().
        auto ary = PagedDynamicArray!size_t(cast(size_t*)0xdeadbeef, -2);
        ary.insertBack(0);
    }
    catch (OutOfMemoryError)
    {
    }
}
