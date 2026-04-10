#!/usr/bin/env bash
# build-webos.sh — Cross-compile chiaki-webos for webOS TV
# Usage: ./build-webos.sh [/path/to/chiaki-ng]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIAKI_NG_DIR="$(realpath "${1:-$SCRIPT_DIR/../chiaki-ng}")"
BUILD_DIR="$SCRIPT_DIR/build-webos"
OUR_STAGING="/tmp/webos-staging"

# ── Validate toolchain ────────────────────────────────────────────────────────
if [[ -z "${TOOLCHAIN_DIR:-}" ]]; then
    echo "ERROR: Set TOOLCHAIN_DIR to your extracted webOS SDK root."
    echo "  export TOOLCHAIN_DIR=~/webos-sdk/arm-webos-linux-gnueabi_sdk-buildroot"
    exit 1
fi

TOOLCHAIN_FILE="$TOOLCHAIN_DIR/share/buildroot/toolchainfile.cmake"
if [[ ! -f "$TOOLCHAIN_FILE" ]]; then
    echo "ERROR: toolchainfile.cmake not found at $TOOLCHAIN_FILE"
    exit 1
fi

SYSROOT="$TOOLCHAIN_DIR/arm-webos-linux-gnueabi/sysroot"

# ── Source buildroot environment ──────────────────────────────────────────────
source "$TOOLCHAIN_DIR/environment-setup"
export STAGING_DIR="$OUR_STAGING"

# The webOS SDK prepends its own ARM-targeted Python to PATH.
# nanopb_generator.py must run on the HOST, so prepend /usr/bin to
# ensure the system python3 wins over the SDK cross-python.
export PATH="/usr/bin:/usr/local/bin:$PATH"   # restore ours after environment-setup overwrites it

[[ -z "${CC:-}" ]]  && export CC="arm-webos-linux-gnueabi-gcc"
[[ -z "${CXX:-}" ]] && export CXX="arm-webos-linux-gnueabi-g++"

CROSS_PREFIX="${CC%-gcc}-"
export AR="${CROSS_PREFIX}ar"
export STRIP="${CROSS_PREFIX}strip"
export RANLIB="${CROSS_PREFIX}ranlib"

SYSROOT_PKGCONFIG="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_PATH="$OUR_STAGING/lib/pkgconfig:$SYSROOT_PKGCONFIG"
export PKG_CONFIG_LIBDIR="$OUR_STAGING/lib/pkgconfig:$SYSROOT_PKGCONFIG"
# Set sysroot for system libs (SDL2 etc), but we'll strip it from staging paths via wrapper
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
REAL_PKG_CONFIG=$(which "${CROSS_PREFIX}pkg-config" 2>/dev/null || which pkg-config)

# Create a pkg-config wrapper that strips the sysroot prefix from any path
# that points into our staging dir. cmake's FindPkgConfig prepends CMAKE_SYSROOT
# to pkg-config output regardless of PKG_CONFIG_SYSROOT_DIR, so even absolute
# paths like /tmp/webos-staging/include become /sysroot/tmp/webos-staging/include.
# The wrapper removes the sysroot prefix from any token containing our staging path.
PKG_CONFIG_WRAPPER="$OUR_STAGING/bin/pkg-config-wrapper"
mkdir -p "$OUR_STAGING/bin"
# Write wrapper with sysroot path baked in at script eval time.
# Only strip $SYSROOT prefix when it precedes /tmp/webos-staging (our staging dir).
# SDL2 and other sysroot library paths like $SYSROOT/usr/include must be left intact
# so the cross-compiler can see them as sysroot-relative rather than host paths.
SYSROOT_STAGING_PREFIX="$SYSROOT/tmp/webos-staging"
cat > "$PKG_CONFIG_WRAPPER" << WRAPPER_EOF
#!/usr/bin/env bash
"$REAL_PKG_CONFIG" "\$@" | sed "s|${SYSROOT_STAGING_PREFIX}|/tmp/webos-staging|g"
WRAPPER_EOF
chmod +x "$PKG_CONFIG_WRAPPER"
export PKG_CONFIG="$PKG_CONFIG_WRAPPER"

echo "-- Toolchain: CC=$CC  PREFIX=$CROSS_PREFIX"
echo "-- Staging:   $OUR_STAGING"
echo "-- Sysroot:   $SYSROOT"
echo ""

mkdir -p "$OUR_STAGING"
mkdir -p "$BUILD_DIR"
NJOBS=$(nproc)

# ── OpenSSL ───────────────────────────────────────────────────────────────────
build_openssl() {
    local ver="3.2.1"
    local src="/tmp/openssl-$ver"
    [[ -f "$OUR_STAGING/lib/libssl.a" ]] && { echo "-- OpenSSL: skip"; return; }
    echo "-- Building OpenSSL $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/openssl-$ver.tar.gz" \
            "https://github.com/openssl/openssl/releases/download/openssl-$ver/openssl-$ver.tar.gz"
        tar xf "/tmp/openssl-$ver.tar.gz" -C /tmp
    fi
    rm -f "$src/Makefile"
    pushd "$src"
    unset CC CXX AR LD RANLIB NM STRIP
    ./Configure linux-armv4 --prefix="$OUR_STAGING" \
        no-shared no-tests no-docs \
        --cross-compile-prefix="$CROSS_PREFIX"
    make -j"$NJOBS" build_sw
    make install_sw
    export CC="${CROSS_PREFIX}gcc" CXX="${CROSS_PREFIX}g++"
    export AR="${CROSS_PREFIX}ar"  LD="${CROSS_PREFIX}ld"
    export RANLIB="${CROSS_PREFIX}ranlib" NM="${CROSS_PREFIX}nm"
    export STRIP="${CROSS_PREFIX}strip"
    popd
}

# ── Opus ──────────────────────────────────────────────────────────────────────
build_opus() {
    local ver="1.4"
    local src="/tmp/opus-$ver"
    [[ -f "$OUR_STAGING/lib/libopus.a" ]] && { echo "-- Opus: skip"; return; }
    echo "-- Building Opus $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/opus-$ver.tar.gz" \
            "https://downloads.xiph.org/releases/opus/opus-$ver.tar.gz"
        tar xf "/tmp/opus-$ver.tar.gz" -C /tmp
    fi
    pushd "$src"
    ./configure --host=arm-webos-linux-gnueabi --prefix="$OUR_STAGING" \
        --enable-static --disable-shared --with-pic --disable-doc --disable-extra-programs
    make -j"$NJOBS" && make install
    popd
}

# ── FFmpeg ────────────────────────────────────────────────────────────────────
build_ffmpeg() {
    local ver="6.1.1"
    local src="/tmp/ffmpeg-$ver"
    [[ -f "$OUR_STAGING/lib/libavcodec.a" ]] && { echo "-- FFmpeg: skip"; return; }
    echo "-- Building FFmpeg $ver"
    rm -f "$src/config.mak" "$src/config.h"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/ffmpeg-$ver.tar.gz" "https://ffmpeg.org/releases/ffmpeg-$ver.tar.gz"
        tar xf "/tmp/ffmpeg-$ver.tar.gz" -C /tmp
    fi
    pushd "$src"
    ./configure \
        --prefix="$OUR_STAGING" \
        --enable-cross-compile --cross-prefix="$CROSS_PREFIX" \
        --arch=arm --cpu=cortex-a15 --target-os=linux \
        --enable-static --disable-shared \
        --disable-programs --disable-doc --disable-network --disable-avdevice \
        --disable-avformat --disable-swresample \
        --enable-avcodec --enable-avutil --enable-swscale \
        --enable-decoder=h264,hevc \
        --disable-decoder=mlp,truehd \
        --enable-parser=h264,hevc --disable-parser=mlp \
        --enable-demuxer=h264,hevc \
        --extra-cflags="-I$OUR_STAGING/include" \
        --extra-ldflags="-L$OUR_STAGING/lib"
    make -j"$NJOBS" && make install
    popd
}

# ── json-c ────────────────────────────────────────────────────────────────────
build_jsonc() {
    local ver="0.17"
    local src="/tmp/json-c-$ver"
    [[ -f "$OUR_STAGING/lib/libjson-c.a" ]] && { echo "-- json-c: skip"; return; }
    echo "-- Building json-c $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/json-c-$ver.tar.gz" \
            "https://github.com/json-c/json-c/archive/json-c-$ver-20230812.tar.gz"
        tar xf "/tmp/json-c-$ver.tar.gz" -C /tmp
        mv "/tmp/json-c-json-c-$ver-20230812" "$src"
    fi
    local bdir="$src/build"; mkdir -p "$bdir"
    cmake -B "$bdir" -S "$src" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF
    cmake --build "$bdir" -j"$NJOBS"
    cmake --install "$bdir"
}

# ── miniupnpc ─────────────────────────────────────────────────────────────────
build_miniupnpc() {
    local ver="2.2.7"
    local src="/tmp/miniupnpc-$ver"
    [[ -f "$OUR_STAGING/lib/libminiupnpc.a" ]] && { echo "-- miniupnpc: skip"; return; }
    echo "-- Building miniupnpc $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/miniupnpc-$ver.tar.gz" \
            "https://miniupnp.tuxfamily.org/files/miniupnpc-$ver.tar.gz"
        tar xf "/tmp/miniupnpc-$ver.tar.gz" -C /tmp
    fi
    local bdir="$src/build"; mkdir -p "$bdir"
    cmake -B "$bdir" -S "$src" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" \
        -DBUILD_SHARED_LIBS=OFF \
        -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_SHARED=OFF \
        -DUPNPC_BUILD_TESTS=OFF -DUPNPC_BUILD_SAMPLE=OFF
    cmake --build "$bdir" -j"$NJOBS"
    cmake --install "$bdir"
}

# ── cURL ──────────────────────────────────────────────────────────────────────
build_curl() {
    local ver="8.7.1"
    local src="/tmp/curl-$ver"
    # WebSocket support (required by holepunch.c curl_ws_* calls) needs --enable-websockets.
	# Rebuild if flag wasn't used in a prior build.
	if [[ -f "$OUR_STAGING/lib/libcurl.a" ]] && \
		grep -q "CURLOPT_WS_OPTIONS" "$OUR_STAGING/include/curl/curl.h" 2>/dev/null; then
		echo "-- cURL: skip (WebSocket enabled)"; return
	fi
	[[ -f "$OUR_STAGING/lib/libcurl.a" ]] && echo "-- cURL: rebuilding to add --enable-websockets"
    echo "-- Building cURL $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/curl-$ver.tar.gz" "https://curl.se/download/curl-$ver.tar.gz"
        tar xf "/tmp/curl-$ver.tar.gz" -C /tmp
    fi
    pushd "$src"
    CPPFLAGS="-I$OUR_STAGING/include" LDFLAGS="-L$OUR_STAGING/lib" \
    ./configure \
        --host=arm-webos-linux-gnueabi --prefix="$OUR_STAGING" \
        --enable-static --disable-shared \
        --with-openssl="$OUR_STAGING" \
		--enable-websockets \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
        --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
        --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
        --disable-manual --disable-docs \
        --without-libidn2 --without-librtmp --without-brotli --without-zstd
    make -j"$NJOBS" && make install
    popd
}

# ── GF-Complete ───────────────────────────────────────────────────────────────
# Jerasure requires GF-Complete for Galois Field arithmetic.
build_gf_complete() {
    local src="/tmp/gf-complete-src"
    if [[ -f "$OUR_STAGING/lib/libgf_complete.a" ]]; then
        echo "-- GF-Complete: skip"; return
    fi
    echo "-- Building GF-Complete (manual compile)"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/gf-complete.tar.gz"             "https://github.com/ceph/gf-complete/archive/refs/heads/master.tar.gz"
        mkdir -p "$src"
        tar xf "/tmp/gf-complete.tar.gz" -C "$src" --strip-components=1
    fi

    local inc="$OUR_STAGING/include"
    local lib="$OUR_STAGING/lib"
    mkdir -p "$inc" "$lib"
    cp "$src"/include/*.h "$inc/" 2>/dev/null || true

    local obj_dir="/tmp/gf-complete-obj"
    mkdir -p "$obj_dir"
    local objects=()
    for f in "$src"/src/*.c; do
        [[ -f "$f" ]] || continue
        local obj="$obj_dir/$(basename "${f%.c}").o"
        echo "   CC $(basename $f)"
        "${CROSS_PREFIX}gcc" -O2 -fPIC             -I"$src/include"             -c "$f" -o "$obj"
        objects+=("$obj")
    done
    "${CROSS_PREFIX}ar" rcs "$lib/libgf_complete.a" "${objects[@]}"
    echo "-- GF-Complete built: ${#objects[@]} objects"
}

# ── Jerasure ─────────────────────────────────────────────────────────────────
build_jerasure() {
    local src="/tmp/jerasure-src"
    if [[ -f "$OUR_STAGING/lib/libJerasure.a" ]]; then
        echo "-- Jerasure: skip"; return
    fi
    echo "-- Building Jerasure 2.0 (manual compile)"
    if [[ ! -d "$src" ]]; then
        # Try multiple sources — the v2.0 tag may not exist on all mirrors
        local dl_ok=0
        for url in \
            "https://github.com/ceph/jerasure/archive/refs/heads/master.tar.gz" \
            "https://github.com/tsuraan/Jerasure/archive/refs/heads/master.tar.gz" \
            "https://github.com/tsuraan/Jerasure/archive/refs/tags/v2.0.tar.gz"
        do
            echo "-- Trying Jerasure: $url"
            wget -qO "/tmp/jerasure.tar.gz" "$url" && dl_ok=1 && break || true
        done
        if [[ $dl_ok -eq 0 ]]; then
            echo "ERROR: All Jerasure download URLs failed"
            exit 1
        fi
        mkdir -p "$src"
        tar xf "/tmp/jerasure.tar.gz" -C "$src" --strip-components=1
    fi

    echo "-- Jerasure source layout:"
    find "$src" -name "*.c" -o -name "*.h" | sort | sed 's|^|   |'

    local inc="$OUR_STAGING/include"
    local lib="$OUR_STAGING/lib"

    # Copy headers — try include/, Headers/, or root
    for hdir in "$src/include" "$src/Headers" "$src"; do
        if ls "$hdir"/*.h &>/dev/null; then
            cp "$hdir"/*.h "$inc/"
            echo "-- Copied headers from $hdir"
            break
        fi
    done

    local obj_dir="/tmp/jerasure-obj"
    mkdir -p "$obj_dir"
    local objects=()

    # Find .c files — try src/, Examples/, or root (exclude test/example files)
    local search_dirs=("$src/src" "$src/Examples" "$src")
    for d in "${search_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for f in "$d"/*.c; do
            [[ -f "$f" ]] || continue
            # Skip example/test files
            local base; base="$(basename "$f")"
            [[ "$base" == example* ]] && continue
            [[ "$base" == test* ]]    && continue
            [[ "$base" == decoder* ]] && continue
            [[ "$base" == encoder* ]] && continue
            local obj="$obj_dir/${base%.c}.o"
            echo "   CC $base"
            "${CROSS_PREFIX}gcc" -O2 -fPIC                 -I"$inc"                 -c "$f" -o "$obj"
            objects+=("$obj")
        done
        [[ ${#objects[@]} -gt 0 ]] && break
    done

    if [[ ${#objects[@]} -eq 0 ]]; then
        echo "ERROR: No compilable Jerasure source files found"
        exit 1
    fi

    "${CROSS_PREFIX}ar" rcs "$lib/libJerasure.a" "${objects[@]}"
    echo "-- Jerasure built: ${#objects[@]} objects"
}

# ── libevent ──────────────────────────────────────────────────────────────────
build_libevent() {
    local ver="2.1.12"
    local src="/tmp/libevent-$ver-stable"
    [[ -f "$OUR_STAGING/lib/libevent.a" ]] && { echo "-- libevent: skip"; return; }
    echo "-- Building libevent $ver"
    if [[ ! -d "$src" ]]; then
        wget -qO "/tmp/libevent-$ver.tar.gz" \
            "https://github.com/libevent/libevent/releases/download/release-$ver-stable/libevent-$ver-stable.tar.gz"
        tar xf "/tmp/libevent-$ver.tar.gz" -C /tmp
    fi
    local bdir="$src/build"; mkdir -p "$bdir"
    cmake -B "$bdir" -S "$src" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_INSTALL_PREFIX="$OUR_STAGING" \
        -DBUILD_SHARED_LIBS=OFF \
        -DEVENT__DISABLE_TESTS=ON \
        -DEVENT__DISABLE_SAMPLES=ON \
        -DEVENT__DISABLE_BENCHMARK=ON \
        -DEVENT__LIBRARY_TYPE=STATIC \
        -DOPENSSL_ROOT_DIR="$OUR_STAGING" \
        -DOPENSSL_INCLUDE_DIR="$OUR_STAGING/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$OUR_STAGING/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$OUR_STAGING/lib/libssl.a" \
        -DCMAKE_FIND_ROOT_PATH="$OUR_STAGING;$SYSROOT" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build "$bdir" -j"$NJOBS"
    cmake --install "$bdir"
}

build_openssl
build_opus
build_jsonc
build_miniupnpc
build_curl
build_gf_complete
build_jerasure
build_libevent

# ── Clone ss4s ────────────────────────────────────────────────────────────────
SS4S_DIR="$SCRIPT_DIR/third-party/ss4s"
if [[ ! -f "$SS4S_DIR/CMakeLists.txt" ]]; then
    echo "-- Cloning ss4s..."
    mkdir -p "$SCRIPT_DIR/third-party"
    git clone --depth=1 https://github.com/mariotaku/ss4s.git "$SS4S_DIR"
else
    echo "-- ss4s: already present ($(git -C "$SS4S_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown'))"
fi

# ── Patch all staging .pc files ───────────────────────────────────────────────
# cmake's FindPkgConfig, when a toolchain sets CMAKE_SYSROOT, prepends the
# sysroot to any path in a PkgConfig:: imported target's INTERFACE_INCLUDE_DIRS.
# Fix: remove all variable-based path lines and hardcode absolute paths so
# there is nothing relative for cmake to prefix.
echo ""
echo "=== Patching staging .pc files to use hardcoded absolute paths ==="
for pc in "$OUR_STAGING"/lib/pkgconfig/*.pc; do
    [[ -f "$pc" ]] || continue
    sed -i "/^prefix=/d"                                              "$pc"
    sed -i "/^exec_prefix=/d"                                         "$pc"
    sed -i "s|^includedir=.*|includedir=$OUR_STAGING/include|"       "$pc"
    sed -i "s|^libdir=.*|libdir=$OUR_STAGING/lib|"                   "$pc"
    sed -i "s|\${prefix}|$OUR_STAGING|g"                             "$pc"
    sed -i "s|\${exec_prefix}|$OUR_STAGING|g"                        "$pc"
done
COUNT=$(ls "$OUR_STAGING/lib/pkgconfig/"*.pc 2>/dev/null | wc -l)
echo "-- Patched $COUNT .pc files"

# Verify the json-c and miniupnpc .pc files look correct
for pkg in json-c miniupnpc; do
    PC="$OUR_STAGING/lib/pkgconfig/$pkg.pc"
    [[ -f "$PC" ]] && echo "-- $pkg.pc includedir: $(grep includedir "$PC")"
done

# ── Write cmake helper module dir ─────────────────────────────────────────────
# Provides a FindNanopb.cmake wrapper that:
#   1. Delegates to nanopb's own find module (in third-party/nanopb/extra/)
#   2. Creates the Nanopb::nanopb alias that chiaki-ng links against
# This must run before cmake configure, and must be on CMAKE_MODULE_PATH so
# cmake finds our wrapper instead of (or in addition to) the upstream one.
CMAKE_MODULES_DIR="$SCRIPT_DIR/cmake"
mkdir -p "$CMAKE_MODULES_DIR"
cat > "$CMAKE_MODULES_DIR/FindNanopb.cmake" << 'FINDNANOPB_EOF'
# Wrapper around nanopb's own FindNanopb.cmake.
# Adds the Nanopb::nanopb alias that chiaki-ng expects.
set(_nanopb_src "@NANOPB_SRC@")
list(APPEND CMAKE_MODULE_PATH "${_nanopb_src}/extra")
include("${_nanopb_src}/extra/FindNanopb.cmake" OPTIONAL RESULT_VARIABLE _found)
if(NOT _found)
    # Fallback: add nanopb as a subdirectory so it builds from source
    if(NOT TARGET nanopb)
        add_subdirectory("${_nanopb_src}" nanopb_build EXCLUDE_FROM_ALL)
    endif()
endif()
if(TARGET nanopb AND NOT TARGET Nanopb::nanopb)
    add_library(Nanopb::nanopb ALIAS nanopb)
endif()
if(TARGET Nanopb::nanopb)
    set(Nanopb_FOUND TRUE)
    set(NANOPB_FOUND TRUE)
endif()
FINDNANOPB_EOF
# Bake the nanopb source path into the find module (can't use cmake vars at write time)
sed -i "s|@NANOPB_SRC@|$CHIAKI_NG_DIR/third-party/nanopb|g" "$CMAKE_MODULES_DIR/FindNanopb.cmake"

# ── Check chiaki-ng submodules ─────────────────────────────────────────────────
echo ""
echo "=== Checking chiaki-ng header API ==="
echo "-- Relevant ChiakiRegisteredHost fields:"
grep -E 'rp_regist_key|rp_key|account_id|psn_' "$CHIAKI_NG_DIR/lib/include/chiaki/regist.h" 2>/dev/null | head -20 || true
echo "-- ChiakiAudioSink fields:"
grep -E 'frame_cb|header_cb|ChiakiAudio' "$CHIAKI_NG_DIR/lib/include/chiaki/audio.h" 2>/dev/null | head -20 || true
echo "-- ChiakiRegistInfo fields:"
grep -E 'ps5|target|account_id|psn_' "$CHIAKI_NG_DIR/lib/include/chiaki/regist.h" 2>/dev/null | grep -v '//' | head -20 || true
echo ""
echo "=== Checking chiaki-ng submodules ==="
# The nanopb submodule CMakeLists.txt must exist for cmake to build protobuf-nanopb-static.
# nanopb_generator.py is needed separately (we run it ourselves to bypass the WSL/Windows
# PATH parentheses bug in cmake's generated custom command).
# Strategy: ensure the submodule CMakeLists exists for cmake, and install nanopb via pip
# for the generator — pip nanopb is more reliable than git submodule on WSL/NTFS.

if [[ ! -f "$CHIAKI_NG_DIR/third-party/nanopb/CMakeLists.txt" ]]; then
    echo "-- nanopb submodule CMakeLists.txt missing, attempting git init..."
    git -C "$CHIAKI_NG_DIR" submodule update --init third-party/nanopb 2>&1 | tail -5 || true
fi

if [[ -f "$CHIAKI_NG_DIR/third-party/nanopb/CMakeLists.txt" ]]; then
    echo "-- nanopb submodule: OK (CMakeLists.txt present)"
else
    echo "-- ERROR: nanopb submodule CMakeLists.txt missing and git init failed."
    echo "   This is required for cmake to build the protobuf library."
    echo "   Fix: cd '$CHIAKI_NG_DIR' && git submodule update --init third-party/nanopb"
    exit 1
fi

# Install nanopb via pip for the generator script (independent of submodule state)
echo "-- Installing/verifying nanopb pip package (for generator)..."
if python3 -c "import nanopb" 2>/dev/null; then
    echo "-- nanopb pip package: already installed"
else
    pip3 install nanopb --break-system-packages -q 2>&1 | tail -3 || \
    pip3 install nanopb -q 2>&1 | tail -3 || true
    python3 -c "import nanopb; print('-- nanopb pip package: OK')" 2>/dev/null \
        || echo "-- nanopb pip package: install failed (will try submodule generator)"
fi

# ── Patch chiaki-ng sources for webOS compatibility ──────────────────────────
echo ""
echo "=== Patching chiaki-ng sources for webOS ==="

# pthread_clockjoin_np was added in glibc 2.30.
# webOS uses an older glibc that only has pthread_timedjoin_np (uses CLOCK_REALTIME).
# The difference: clockjoin lets you pick the clock; timedjoin always uses CLOCK_REALTIME.
# For our purposes (waiting on a thread with a timeout) this is functionally identical.
THREAD_C="$CHIAKI_NG_DIR/lib/src/thread.c"
if grep -q 'pthread_clockjoin_np' "$THREAD_C" 2>/dev/null; then
    # Replace:  pthread_clockjoin_np(thread->thread, retval, CLOCK_MONOTONIC, &timeout)
    # With:     pthread_timedjoin_np(thread->thread, retval, &timeout)
    sed -i 's/pthread_clockjoin_np(\(.*\), CLOCK_MONOTONIC, \(&timeout\))/pthread_timedjoin_np(\1, \2)/' \
        "$THREAD_C"
    if grep -q 'pthread_clockjoin_np' "$THREAD_C"; then
        echo "-- WARNING: pthread_clockjoin_np patch may have failed, checking manually..."
        grep -n 'pthread_clockjoin_np\|pthread_timedjoin_np' "$THREAD_C" | sed 's/^/  /'
    else
        echo "-- thread.c: patched pthread_clockjoin_np → pthread_timedjoin_np"
    fi
else
    echo "-- thread.c: no pthread_clockjoin_np (already patched or different version)"
fi

# aligned_alloc was added in glibc 2.16 but webOS's glibc may not export it.
# Replace with posix_memalign which is universally available.
COMMON_C="$CHIAKI_NG_DIR/lib/src/common.c"
if grep -q 'return aligned_alloc' "$COMMON_C" 2>/dev/null; then
    sed -i '/return aligned_alloc/c\	\tvoid *ptr = NULL; if(posix_memalign(\&ptr, alignment, size) != 0) return NULL; return ptr;' \
        "$COMMON_C"
    if grep -q 'posix_memalign' "$COMMON_C"; then
        echo "-- common.c: patched aligned_alloc → posix_memalign"
    else
        echo "-- WARNING: aligned_alloc patch may have failed"
    fi
else
    echo "-- common.c: no aligned_alloc (already patched or different version)"
fi

# ── Generate cmake toolchain extension ────────────────────────────────────────
# We use CMAKE_PROJECT_INCLUDE to inject fixes early in configuration:
#   1. CURL::libcurl imported target (find_package(CURL) may not create it)
#   2. Nanopb::nanopb imported target + cmake module path
#   3. A cmake_language(DEFER) block that fixes PkgConfig:: target include dirs
#      AFTER chiaki-ng's CMakeLists.txt has created them via pkg_search_module.
#      DEFER runs at the end of the top-level CMakeLists.txt processing.
HINTS_FILE="$BUILD_DIR/chiaki_hints.cmake"
mkdir -p "$BUILD_DIR"

# Write the file using a sentinel that won't expand shell variables,
# then sed in the actual paths afterwards.
cat > "$HINTS_FILE" << 'ENDOFHINTS'
# ── CURL ──────────────────────────────────────────────────────────────────────
if(NOT TARGET CURL::libcurl)
    add_library(CURL::libcurl STATIC IMPORTED GLOBAL)
    set_target_properties(CURL::libcurl PROPERTIES
        IMPORTED_LOCATION             "@@STAGING@@/lib/libcurl.a"
        INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include"
        INTERFACE_LINK_LIBRARIES      "OpenSSL::SSL;OpenSSL::Crypto;z;pthread"
    )
    set(CURL_FOUND        TRUE)
    set(CURL_LIBRARIES    "@@STAGING@@/lib/libcurl.a")
    set(CURL_INCLUDE_DIRS "@@STAGING@@/include")
    set(CURL_VERSION_STRING "8.7.1")
endif()

# ── Force host Python for nanopb generator ────────────────────────────────────
set(PYTHON_EXECUTABLE  "/usr/bin/python3" CACHE FILEPATH "Host Python" FORCE)
set(Python3_EXECUTABLE "/usr/bin/python3" CACHE FILEPATH "Host Python 3" FORCE)
set(Python_EXECUTABLE  "/usr/bin/python3" CACHE FILEPATH "Host Python" FORCE)

# ── GF-Complete ───────────────────────────────────────────────────────────────
if(NOT TARGET GF-Complete::GF-Complete)
    add_library(GF-Complete::GF-Complete STATIC IMPORTED GLOBAL)
    set_target_properties(GF-Complete::GF-Complete PROPERTIES
        IMPORTED_LOCATION             "@@STAGING@@/lib/libgf_complete.a"
        INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include"
    )
endif()

# ── Jerasure ──────────────────────────────────────────────────────────────────
if(NOT TARGET Jerasure::Jerasure)
    add_library(Jerasure::Jerasure STATIC IMPORTED GLOBAL)
    set_target_properties(Jerasure::Jerasure PROPERTIES
        IMPORTED_LOCATION             "@@STAGING@@/lib/libJerasure.a"
        INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include"
        INTERFACE_LINK_LIBRARIES      "GF-Complete::GF-Complete"
    )
endif()

# ── Fix PkgConfig:: target include dirs after pkg_search_module runs ──────────
# cmake_language(DEFER) executes at the end of the directory scope that issued it.
# By the time it runs, all pkg_search_module() calls in chiaki-ng's lib/
# CMakeLists.txt will have created PkgConfig::json-c and PkgConfig::MINIUPNPC,
# and we overwrite their (sysroot-corrupted) INTERFACE_INCLUDE_DIRECTORIES.
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL cmake_language EVAL CODE [[
    # Fix sysroot-corrupted include dirs on PkgConfig imported targets
    foreach(_t PkgConfig::json-c PkgConfig::MINIUPNPC PkgConfig::miniupnpc)
        if(TARGET ${_t})
            set_property(TARGET ${_t} PROPERTY
                INTERFACE_INCLUDE_DIRECTORIES "@@STAGING@@/include")
            message(STATUS "chiaki_hints: fixed include dir on ${_t}")
        endif()
    endforeach()
    # nanopb's CMakeLists creates target 'nanopb' (unnamespaced).
    # chiaki-ng links against 'Nanopb::nanopb' (namespaced alias).
    if(TARGET nanopb AND NOT TARGET Nanopb::nanopb)
        add_library(Nanopb::nanopb ALIAS nanopb)
        message(STATUS "chiaki_hints: created Nanopb::nanopb alias")
    endif()
]])
ENDOFHINTS

sed -i "s|@@STAGING@@|$OUR_STAGING|g"          "$HINTS_FILE"
sed -i "s|@@NANOPB@@|$CHIAKI_NG_DIR/third-party/nanopb|g" "$HINTS_FILE"

echo ""
echo "=== Installing host protobuf Python package (needed by nanopb generator) ==="
if python3 -c "import google.protobuf" 2>/dev/null; then
    python3 -c "import google.protobuf; print('-- protobuf: already installed', google.protobuf.__version__)"
else
    pip3 install protobuf --break-system-packages 2>&1 | tail -3 || \
    python3 -m pip install protobuf --break-system-packages 2>&1 | tail -3 || true
    python3 -c "import google.protobuf; print('-- protobuf: installed', google.protobuf.__version__)" \
        || { echo "-- protobuf STILL MISSING — trying apt"; sudo apt-get install -y python3-protobuf 2>&1 | tail -3 || true; }
fi



echo ""
echo "=== Configuring chiaki-webos ==="
set -x  # trace all commands from here so failures are visible

# Wipe cmake cache to force fresh pkg-config reads and find_package calls.
rm -f "$BUILD_DIR/CMakeCache.txt"
rm -rf "$BUILD_DIR/CMakeFiles"

# PKG_CONFIG_SYSROOT_DIR="" on the cmake command line prevents cmake's own
# pkg-config invocations from prepending the sysroot to our absolute paths.
# SDL2 and other sysroot libs are found via CMAKE_FIND_ROOT_PATH instead.
cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWEBOS_BUILD=ON \
    -DWEBOS_STAGING_DIR="$OUR_STAGING" \
    -DCHIAKI_SOURCE_DIR="$CHIAKI_NG_DIR" \
    -DCMAKE_INSTALL_PREFIX="/app" \
    -DOPENSSL_ROOT_DIR="$OUR_STAGING" \
    -DOPENSSL_INCLUDE_DIR="$OUR_STAGING/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$OUR_STAGING/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$OUR_STAGING/lib/libssl.a" \
    -DCHIAKI_ENABLE_CLI=OFF \
    -DCHIAKI_ENABLE_TESTS=OFF \
    -DCHIAKI_ENABLE_GUI=OFF \
    -DNANOPB_SRC_ROOT_FOLDER="$CHIAKI_NG_DIR/third-party/nanopb" \
    -DCMAKE_MODULE_PATH="$CMAKE_MODULES_DIR;$CHIAKI_NG_DIR/third-party/nanopb/extra" \
    -DCMAKE_PREFIX_PATH="$OUR_STAGING;$SYSROOT/usr" \
    -DCMAKE_FIND_ROOT_PATH="$OUR_STAGING;$SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_EXE_LINKER_FLAGS="-L$OUR_STAGING/lib -L$SYSROOT/usr/lib -Wl,-rpath,\$ORIGIN/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$OUR_STAGING/lib -L$SYSROOT/usr/lib -lm" \
    -DPKG_CONFIG_EXECUTABLE="$PKG_CONFIG" \
    -DCMAKE_PROJECT_INCLUDE="$HINTS_FILE" \
    -DPYTHON_EXECUTABLE="$(which python3 || which python)" \
    -DPython3_EXECUTABLE="$(which python3 || which python)" \
    -DNDL_DIRECTMEDIA_FOUND=ON \
    -DNDL_DIRECTMEDIA_INCLUDE_DIRS="$SYSROOT/usr/include" \
    -DNDL_DIRECTMEDIA_LIBRARIES="NDL_directmedia" \
    -DSS4S_MODULE_LIBRARY_OUTPUT_DIRECTORY="$BUILD_DIR/lib" \
    -DSS4S_ENABLE_TESTS=OFF \
    -DSS4S_ENABLE_SAMPLES=OFF \
    -DSS4S_COMPILE_CHECK_STRICT=OFF \
    -DSS4S_MODULE_DISABLE_NDL_ESPLAYER=ON \
    -DSS4S_MODULE_DISABLE_NDL_WEBOS4=OFF \
    -DSS4S_MODULE_DISABLE_NDL_WEBOS5=OFF

echo ""
echo "=== Pre-generating takion.pb after configure ==="
# The cmake-generated nanopb custom command sets PATH containing Windows paths
# like "Program Files (x86)" with literal parentheses, which crash any shell.
# We generate takion.pb ourselves and stamp the outputs newer than takion.proto
# so make skips the custom command as already up-to-date.
PROTO_OUT="$BUILD_DIR/chiaki_lib/protobuf"
TAKION_PROTO="$CHIAKI_NG_DIR/lib/protobuf/takion.proto"
mkdir -p "$PROTO_OUT"

# Find nanopb_generator.py — prefer pip-installed version, fall back to submodule
NANOPB_GEN=""

# 1. Try pip-installed nanopb package
NANOPB_GEN="$(python3 -c '
import sys
try:
    import nanopb, os
    gen = os.path.join(os.path.dirname(nanopb.__file__), "nanopb_generator.py")
    if os.path.isfile(gen): print(gen)
except: pass
' 2>/dev/null)"

# 2. Try submodule locations
if [[ -z "$NANOPB_GEN" ]]; then
    for candidate in \
        "$CHIAKI_NG_DIR/third-party/nanopb/nanopb_generator.py" \
        "$CHIAKI_NG_DIR/third-party/nanopb/generator/nanopb_generator.py"; do
        if [[ -f "$candidate" ]]; then
            NANOPB_GEN="$candidate"
            break
        fi
    done
fi

if [[ -z "$NANOPB_GEN" ]]; then
    echo "-- ERROR: Cannot find nanopb_generator.py anywhere. Aborting."
    echo "   Fix: cd '$CHIAKI_NG_DIR' && git submodule update --init --recursive"
    exit 1
fi

python3 "$NANOPB_GEN" \
    --output-dir="$PROTO_OUT" \
    --proto-path="$CHIAKI_NG_DIR/lib/protobuf" \
    "$TAKION_PROTO" 2>&1 | sed 's/^/  /'

if [[ -f "$PROTO_OUT/takion.pb.c" && -f "$PROTO_OUT/takion.pb.h" ]]; then
    echo "-- takion.pb.c: $(wc -l < "$PROTO_OUT/takion.pb.c") lines — ready"
else
    echo "-- ERROR: takion.pb generation failed! See output above."
    python3 -c "import google.protobuf; print('  protobuf ok:', google.protobuf.__version__)" \
        2>/dev/null || echo "  protobuf missing — run: pip3 install protobuf --break-system-packages"
    exit 1
fi

# ── Patch generated build.make to neutralise the broken cmake custom command ──
# cmake's chiaki-pb target embeds the full WSL PATH (including Windows entries
# like "Program\ Files\ (x86)") into a recipe line.  Make passes this verbatim
# to /bin/sh -c; the unescaped ( causes "Syntax error: ( unexpected".
# Fix: replace every recipe line containing "-E env" and "PATH=" with @true.
# We've already generated the output files above, so the no-op is correct.
CHIAKI_PB_MAKE="$BUILD_DIR/chiaki_lib/protobuf/CMakeFiles/chiaki-pb.dir/build.make"
if [[ -f "$CHIAKI_PB_MAKE" ]]; then
    python3 << PYEOF
path = "$CHIAKI_PB_MAKE"
with open(path, "r", errors="replace") as f:
    lines = f.readlines()
changed = 0
out = []
for line in lines:
    if line.startswith("\t") and "-E env" in line and "PATH=" in line:
        out.append("\t@true  # recipe disabled: pre-generated by build-webos.sh\n")
        changed += 1
    else:
        out.append(line)
with open(path, "w") as f:
    f.writelines(out)
print(f"-- Patched {changed} recipe line(s) in build.make" if changed
      else "-- WARNING: no matching recipe lines found in build.make")
PYEOF
else
    echo "-- WARNING: $CHIAKI_PB_MAKE not found after configure"
fi

echo ""
echo "=== Building ==="
cmake --build "$BUILD_DIR" -j"$NJOBS"

echo ""
echo "=== Packaging IPK ==="
cmake --build "$BUILD_DIR" --target ipk

echo ""
echo "=== Done! ==="
ls "$BUILD_DIR"/*.ipk 2>/dev/null || echo "(check $BUILD_DIR for output)"
