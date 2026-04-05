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
