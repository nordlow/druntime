I'm currently experimenting with a very basic GC for D

at

https://github.com/nordlow/druntime/blob/fastalloc-gc/src/gc/impl/fastalloc/gc.d

that, in its first incarnation, only provides allocation faster than the
`conservative`, hence its name `fastalloc-gc`.

The implementation currently does global allocation together with local
allocation via `gc_tlmallocN()` where `N` can be any of the value in the static
constant `smallSizeClasses`. This because I want to experiment with the possible
allocation performance of thread-local GC allocation for D.

For thread-local (non-spinlocked) GC allocation with specific size class
overloads of gc_mallocN` and `gc_callocN`, where `N` is either 8, 16, 32, 64,
etc I'm measuring _great_ allocation speeds-up in my GC-allocation benchmark at

https://github.com/nordlow/phobos-next/blob/master/snippets/gctester.d

as seen in its output

[per:~/Work/knet/phobos-next/snippets] 3s $ dmd-own gctester.d --DRT-gcopt=gc:fastalloc
TODO

compared to for the `conservative` one:

[per:~/Work/knet/phobos-next/snippets] 3s $ dmd-own gctester.d --DRT-gcopt=gc:conservative
TODO

And yes, the non-locked variants of `gc_mallocN` used when `N` is known at
compile-time in `fastalloc-gc` are _so_ much faster that they improve allocation
performance by about 40% for `N` being 16 and 32 compared to a non-locked
version of `gc_malloc` when `N` is _not_ known at compile-time. That's why I'm
benchmarking them in gctester.d. This is motivated by the fact that calls to
`new T()` can be optimized to make use of these overloads for non-mutable
storage of `T` because `T.sizeof` is in this case known at compile-time. And
yes, I'm aware of that this optimization only works for instances of `T` that
are not immediately being cast to immutable and shared. Handling this might be
solved by implementing support in the compiler for a lowering to, say,
`__to_immutable(x)` or `__to_shared(x)` that copy these allocations to the
global allocator `gGcx`.

Note that it, opposite to the current conservative implementation, makes use of
`static foreach` when generating distinct pool types for different size classes
as outlined at the end Dmitry's blogpost "Inside D's GC" at

https://news.ycombinator.com/item?id=14592457

This makes it possible to provide specialized page info layouts for each pool
with a specific type class without manual code-duplication.

Now: is anybody interested in giving feedback on my progress so far,
specifically if I've made any mistakes in my implementation of the global
allocator (`gGcx`) vs. thread-local allocator (`tlGcx`).
