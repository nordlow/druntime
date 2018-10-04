/**
 * Static bit array container for internal usage.
 */
module rt.util.container.static_bitarray;

static import common = rt.util.container.common;

import core.exception : onOutOfMemoryErrorNoGC;

struct StaticBitArray(uint bitCount, Block = size_t)
{
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
        _blocks[] = 0;          // TODO is this fastest way?
    }

    /** Data stored as `Block`s. */
    private Block[blockCount] _blocks;
}
