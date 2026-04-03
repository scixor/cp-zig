# Build: just build [-r] [-v] [extra flags...]
#   -r  rebuild (clean cache first)
#   -v  verbose reference trace
build *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    args=()
    extra=()
    for flag in {{ FLAGS }}; do
        case "$flag" in
            -r) rm -rf .zig-cache zig-out ;;
            -v) args+=("-freference-trace=12") ;;
            *)  extra+=("$flag") ;;
        esac
    done
    zig build "${args[@]}" "${extra[@]}" && echo "Build successful ✓"
