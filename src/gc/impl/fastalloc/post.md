I'm currently experimenting with a very basic GC for D

at

https://github.com/nordlow/druntime/blob/fastalloc-gc/src/gc/impl/fastalloc/gc.d

that, in its first incarnation, solely provides allocation. This allocation
being slightly faster than the `conservative`, hence its name `fastalloc-gc`.

The implementation currently does global allocation together with local
allocation via the extra global functions (yes, not pretty, please give me ideas
on how to improve this) `gc_tlmallocN()` where `N` can be any of the value in
the static constant `smallSizeClasses`. This because I want to experiment with
the performance of thread-local GC allocation for D.

For thread-local (non-spinlocked) GC allocation with specific size class
overloads of gc_tlmallocN` I'm measuring _great_ allocation speeds-up for 16, 32
and 64 bits, in my GC-allocation benchmark at

https://github.com/nordlow/phobos-next/blob/master/snippets/gctester.d

as seen in its output

$ dmd-own gctester.d --DRT-gcopt=gc:fastalloc
 size new-C new-S GC.malloc gc_tlmalloc_N GC.calloc malloc calloc
    8  42.7  40.6    23.4        8.4        24.9     42.3   36.0
   16  35.3  26.2    13.9        4.7        12.6     17.2   15.9
   32  13.6  12.6     7.4        2.8         7.6     11.5   10.7
   64  11.0   9.1     4.3        2.3         4.4      7.0    5.8
  128   8.8   8.7     2.5        1.5         2.5      3.6    4.4
  256  10.8   6.0     1.9        1.4         1.9      3.7    2.9
  512   8.8   4.1     1.5        1.2         1.5      2.2    2.4
 1024   7.6   3.7     1.4        1.2         1.3      2.0    2.2
  ns/w: nanoseconds per word

And yes, the non-locked variants of `gc_tlmallocN` used when `N` is known at
compile-time in `fastalloc-gc` are _so_ much faster that they improve allocation
performance by about 40% for `N` being 16 and 32 compared to a non-locked
version of `gc_malloc` when `N` is _not_ known at compile-time. That's why I'm
benchmarking them in gctester.d. This is motivated by the fact that calls to
`new T()` can be optimized to make use of these overloads for non-shared storage
of `T` because `T.sizeof` is in this case known at compile-time. And yes, I'm
aware of that this optimization only works for instances of `T` that are not
immediately being cast to immutable and shared. Handling this might be solved by
implementing support in the compiler for a lowering to, say, `__to_immutable(x)`
or `__to_shared(x)` that copy these allocations to the global allocator
`gGcx`. These ideas have already been discussed in previous forum posts.

Note that `fastalloc`, opposite to `conservative`, makes use of `static foreach`
when generating distinct pool types for different size classes as outlined at
the end Dmitry's blogpost "Inside D's GC" at

https://news.ycombinator.com/item?id=14592457

This makes it possible to provide specialized page info layouts for each pool
with a specific type class without manual code-duplication. In other words,
"design by introspection to the resque!".

Now: is anybody interested in giving feedback on my progress so far,
specifically if I've made any mistakes in my implementation of the global
allocator (`gGcx`) vs. thread-local allocator (`tlGcx`).
