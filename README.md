# cp-zig

A minimal reimplementation of Unix `cp` in Zig for performence and testing out io.

## Usage

```
cp-zig [-r] [-f] [-v] <source> <dest>
```

## Perf

It is among the fastest copi-ers as a side effect nothing too fancy has been implemented just standard library
and default threaded io implementation.

**NOTE**: I haven't tested it as throughly I just wrote a simple benchmark script just to test out as it was never the
intention to make it the fastest and lacks many feature of cp.

### Laptop
Core Ultra 185H (22C)
```sh
./zig-out/bin/bench-hyperfine \
    --tmp-root /home/sid/bench-disk \
    --size-gib 5 --depth 6 --fanout 8 \
    --runs 5 --backend threaded
```

```sh
Benchmark 1: cp-zig-threaded
  Time (mean ± σ):     273.6 ms ±   6.6 ms    [User: 170.8 ms, System: 3940.4 ms]
  Range (min … max):   264.7 ms … 279.8 ms    5 runs
 
Benchmark 2: cp-zig-single
  Time (mean ± σ):      1.545 s ±  0.142 s    [User: 0.065 s, System: 1.426 s]
  Range (min … max):    1.414 s …  1.784 s    5 runs
 
Benchmark 3: cp
  Time (mean ± σ):      1.582 s ±  0.252 s    [User: 0.024 s, System: 1.443 s]
  Range (min … max):    1.404 s …  2.019 s    5 runs
 
Benchmark 4: cpz
  Time (mean ± σ):     275.4 ms ±  14.8 ms    [User: 35.7 ms, System: 4451.4 ms]
  Range (min … max):   261.1 ms … 299.3 ms    5 runs
 
Benchmark 5: fcp
  Time (mean ± σ):     256.2 ms ±   9.6 ms    [User: 85.4 ms, System: 4165.9 ms]
  Range (min … max):   245.1 ms … 269.7 ms    5 runs
 
Summary
  fcp ran
    1.07 ± 0.05 times faster than cp-zig-threaded
    1.07 ± 0.07 times faster than cpz
    6.03 ± 0.60 times faster than cp-zig-single
    6.17 ± 1.01 times faster than cp
```


### Server

AMD Epyc Zen5c (cgroups to 16 cores)

```sh
./bench-hyperfine --cpzig ./cp-zig --cpz ./cpz --fcp ./fcp --backend threaded --tmp-root ./test-temp
```

```sh
info: workdir: ./test-temp/cpzig-bench-00
info: dataset target: 5120 MiB (5120 files x 1 MiB)
info: depth=6 fanout=8 backend=threaded runs=5 warmup=1
...
info: source stats: bytes=5368709120 files=5120 dirs=14921
info: running hyperfine...
Benchmark 1: cp-zig-threaded
  Time (mean ± σ):     316.7 ms ±   6.6 ms    [User: 27.7 ms, System: 2985.8 ms]
  Range (min … max):   309.7 ms … 325.4 ms    5 runs
 
Benchmark 2: cp-zig-single
  Time (mean ± σ):      1.882 s ±  0.031 s    [User: 0.015 s, System: 1.776 s]
  Range (min … max):    1.852 s …  1.933 s    5 runs
 
Benchmark 3: cp
  Time (mean ± σ):      1.889 s ±  0.024 s    [User: 0.024 s, System: 1.776 s]
  Range (min … max):    1.854 s …  1.912 s    5 runs
 
Benchmark 4: cpz
  Time (mean ± σ):     339.4 ms ±   4.8 ms    [User: 24.8 ms, System: 3566.8 ms]
  Range (min … max):   333.0 ms … 344.1 ms    5 runs
 
Benchmark 5: fcp
  Time (mean ± σ):      1.000 s ±  0.081 s    [User: 0.288 s, System: 16.292 s]
  Range (min … max):    0.864 s …  1.073 s    5 runs
 
Summary
  cp-zig-threaded ran
    1.07 ± 0.03 times faster than cpz
    3.16 ± 0.26 times faster than fcp
    5.94 ± 0.16 times faster than cp-zig-single
    5.96 ± 0.15 times faster than cp
```

> [!NOTE]
> fcp probably doesn't detect cgroups correctly hence the slowdown caused by making too many threads

## Build

```sh
zig build --release=fast
```

The binary is output to `zig-out/bin/cp-zig` by default

## Examples

```sh
# Copy a file
./zig-out/bin/cp-zig file.txt copy.txt

# Recursive directory copy
./zig-out/bin/cp-zig -r -v src/ backup/

# Force overwrite
./zig-out/bin/cp-zig -f config.json /tmp/config.json
```

## License

MIT
