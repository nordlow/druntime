/**
 * Static bit array container for internal usage.
 */
module rt.util.container.static_bitarray;

static import common = rt.util.container.common;

struct StaticBitArray(uint bitCount, Block = size_t)
{
    import core.bitop : bt, bts, btr;

    @safe pure @nogc:

    /** Number of bits. */
    enum length = bitCount;

    /** Number of bits per `Block`. */
    enum bitsPerBlock = 8*Block.sizeof;

    /** Number of `Block`s. */
    enum blockCount = (bitCount + (bitsPerBlock-1)) / bitsPerBlock;

    /** Reset all bits (to zero). */
    void reset() nothrow
    {
        _blocks[] = 0;          // TODO is this the fastest way?
    }

    /** Gets the $(D idx)'th bit. */
    bool opIndex(size_t idx) const @trusted nothrow
    in
    {
        assert(idx < length);     // TODO nothrow or not?
    }
    body
    {
        pragma(inline, true);
        return cast(bool)bt(_blocks.ptr, idx);
    }

    /** Sets the $(D idx)'th bit. */
    bool opIndexAssign(bool b, size_t idx) @trusted nothrow
    {
        pragma(inline, true);
        if (b)
        {
            bts(_blocks.ptr, cast(size_t)idx);
        }
        else
        {
            btr(_blocks.ptr, cast(size_t)idx);
        }
        return b;
    }

    // TODO find index of first zero bit
    size_t indexOfFirst1() const nothrow
    {
        return 0;               // TODO
    }

    private Block[blockCount] _blocks;
}

@safe pure nothrow @nogc:

///
unittest
{
    StaticBitArray!63 x;

    x[0] = true;
    assert(x[0]);
    assert(!x[1]);

    x[1] = true;
    assert(x[1]);

    x[1] = false;
    assert(!x[1]);
}
