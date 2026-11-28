#!/bin/sh
# usage: scripts/test-musl.sh
# Runs the tests on musl, in the build modes below: the core and `pdf_openssl`,
# inside an Alpine container against Alpine's OpenSSL. Needs docker and a Zig
# installation whose directory can be mounted. The container gets the repository
# read-only and works on a copy; it needs the network for Alpine's packages.
# Exit status: 0 all passed.
set -eu

IMAGE=${PDFZIG_MUSL_IMAGE:-alpine:3.22} # its OpenSSL is of the 3.5 LTS series
# Compiles at once: a release compile takes up to about 800 MB of the 4 GB.
JOBS=${PDFZIG_MUSL_JOBS:-3}
repo=$(cd "$(dirname "$0")/.." && pwd)
zig=$(dirname "$(readlink -f "$(command -v zig)")")

exec docker run --rm --memory=4g --memory-swap=4g -e JOBS="$JOBS" \
    -v "$repo:/src:ro" -v "$zig:/zig:ro" "$IMAGE" sh -eu -c '
    apk add --no-cache openssl-dev >/dev/null
    echo "musl: $(apk list -I 2>/dev/null | grep -E "^musl-[0-9]" | cut -d" " -f1)"
    echo "openssl: $(apk list -I 2>/dev/null | grep -E "^openssl-dev-[0-9]" | cut -d" " -f1)"
    mkdir /work
    cd /src
    cp -R build.zig build.zig.zon src examples test /work/
    cd /work
    for mode in Debug ReleaseSafe ReleaseFast ReleaseSmall; do
        for openssl in false true; do
            echo "== $mode openssl=$openssl"
            /zig/zig build test -j"$JOBS" -Dopenssl=$openssl -Doptimize=$mode --summary all >log 2>&1 || { cat log; exit 1; }
            grep -E "Build Summary|run test [0-9]" log
        done
    done
    # That the tests ran against musl and the system libcrypto.
    /zig/zig build -j"$JOBS" -Dopenssl=true -Doptimize=ReleaseSafe
    ldd zig-out/bin/pdfsigs
    zig-out/bin/pdfsigs test/backend/ber.pdf
    echo "musl tests passed"
'
