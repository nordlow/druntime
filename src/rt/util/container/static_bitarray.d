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
        pragma(inline, true);
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

    /** Get number of bits set. */
    version(none)               // TODO activate when needed
    size_t countOnes() const
    {
        typeof(return) n = 0;
        foreach (const block; _blocks)
        {
            import core.bitop : popcnt;
            static if (block.sizeof == 1 ||
                       block.sizeof == 2 ||
                       block.sizeof == 4 ||
                       block.sizeof == 4)
            {
                // TODO do we need to force `uint`-overload of `popcnt`?
                n += cast(uint)block.popcnt;
            }
            else static if (block.sizeof == 8)
            {
                n += (cast(ulong)((cast(uint)(block)).popcnt) +
                      cast(ulong)((cast(uint)(block >> 32)).popcnt));
            }
            else
            {
                assert(0, "Unsupported Block size " ~ Block.sizeof.stringof);
            }
        }
        return typeof(return)(n);
    }

    /** Find index of first non-zero bit or `length` if no bit set. */
    size_t indexOfFirstSetBit() const nothrow
    {
        pragma(inline, true);
        import core.bitop : bsf;
        foreach (const blockIndex, const block; _blocks)
        {
            if (block != 0)
            {
                return blockIndex*bitsPerBlock + bsf(block);
            }
        }
        return length;
    }

    private Block[blockCount] _blocks;
}

@safe pure nothrow @nogc:

///
unittest
{
    alias Block = size_t;
    enum blockCount = 2;
    enum length = blockCount * 8*Block.sizeof - 1;
    StaticBitArray!(length) x;
    static assert(x.blockCount == blockCount);

    assert((x.indexOfFirstSetBit == x.length));
    x[length - 1] = true;
    assert((x.indexOfFirstSetBit == x.length - 1));
    x[length - 2] = true;
    assert((x.indexOfFirstSetBit == x.length - 2));

    x[length/2 + 1] = true;
    assert((x.indexOfFirstSetBit == x.length/2 + 1));
    x[length/2] = true;
    assert((x.indexOfFirstSetBit == x.length/2));
    x[length/2 - 1] = true;
    assert((x.indexOfFirstSetBit == x.length/2 - 1));

    x[0] = true;
    assert((x.indexOfFirstSetBit == 0));
    assert(x[0]);
    assert(!x[1]);

    x[1] = true;
    assert(x[1]);

    x[1] = false;
    assert(!x[1]);
}
