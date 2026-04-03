# cp-zig

A minimal reimplementation of Unix `cp` in Zig for performence and testing out io.

## Usage

```
cp-zig [-r] [-f] [-v] <source> <dest>
```

| Flag | Description |
|------|-------------|
| `-r` | Copy directories recursively |
| `-f` | Force overwrite existing files (unlike cp this checks) |
| `-v` | Verbose output |

## Build

```sh
zig build
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
