/**
 * Static bit array container for internal usage.
 */
module rt.util.container.static_bitarray;

static import common = rt.util.container.common;

import core.exception : onOutOfMemoryErrorNoGC;

struct StaticBitArray(uint bitCount, Block = size_t)
{
    @safe pure @nogc:

    /** Number of bits. */
    enum length = bitCount;

    pragma(msg, bitCount, " ", this.sizeof);
    import core.bitop : bt, bts, btr;

    /** Number of bits per `Block`. */
    enum bitsPerBlock = 8*Block.sizeof;

    /** Number of `Block`s. */
    enum blockCount = (bitCount + (bitsPerBlock-1)) / bitsPerBlock;

    /** Reset all bits (to zero). */
    void reset()()
    {
        pragma(inline, true);
        _blocks[] = 0;          // TODO is this the fastest way?
    }

    /** Gets the $(D i)'th bit. */
    bool opIndex(size_t i) const @trusted
    in
    {
        assert(i < length);     // TODO nothrow or not?
    }
    body
    {
        pragma(inline, true);
        return cast(bool)bt(_blocks.ptr, i);
    }

    /** Sets the $(D i)'th bit. */
    bool opIndexAssign(bool b, size_t i) @trusted
    {
        pragma(inline, true);
        if (b)
        {
            bts(_blocks.ptr, cast(size_t)i);
        }
        else
        {
            btr(_blocks.ptr, cast(size_t)i);
        }
        return b;
    }

    private Block[blockCount] _blocks;
}

@safe pure @nogc:

///
nothrow unittest
{
    StaticBitArray!2 bs;

    bs[0] = true;
    assert(bs[0]);
    assert(!bs[1]);

    bs[1] = true;
    assert(bs[1]);
}
