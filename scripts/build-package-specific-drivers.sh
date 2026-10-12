#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
UPSTREAM="$ROOT/upstream"
APP="$UPSTREAM/app/app"
ROOTFS_PATH="/data/data/com.winlator.optimal/files/rootfs/lib"
WORK="${RUNNER_TEMP:-/tmp}/winlator-optimal-driver-build"

fail() { echo "ERROR: $*" >&2; exit 1; }

replace_exactly_once() {
  local file="$1" old="$2" new="$3"
  python3 - "$file" "$old" "$new" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
old, new = sys.argv[2], sys.argv[3]
data = p.read_text()
count = data.count(old)
if count != 1:
    raise SystemExit(f"{p}: expected one occurrence of {old!r}, found {count}")
p.write_text(data.replace(old, new, 1))
print(f"Patched {p}")
PY
}

# Patch the Android-side clients to use this fork's private application directory.
replace_exactly_once "$APP/src/main/java/com/winlator/core/AppUtils.java" \
  '/data/data/com.winlator/storage' \
  '/data/data/com.winlator.optimal/storage'
replace_exactly_once "$APP/src/main/cpp/winlator/include/winlator.h" \
  '/data/data/com.winlator/cache' \
  '/data/data/com.winlator.optimal/cache'
replace_exactly_once "$APP/src/main/cpp/vortekrenderer/include/vortek.h" \
  '/data/data/com.winlator/files/rootfs/tmp/.vortek/V0' \
  '/data/data/com.winlator.optimal/files/rootfs/tmp/.vortek/V0'
replace_exactly_once "$APP/src/main/cpp/gladiorenderer/include/gladio.h" \
  '/data/data/com.winlator/files/rootfs/tmp/.X11-unix/X0' \
  '/data/data/com.winlator.optimal/files/rootfs/tmp/.X11-unix/X0'

# The Linux guest drivers shipped in upstream assets also contain package-specific
# socket/cache paths. Rebuild them so the client and server use the same locations.
replace_exactly_once "$UPSTREAM/vortek/include/vortek.h" \
  '/data/data/com.winlator/files/rootfs/tmp/.vortek/V0' \
  '/data/data/com.winlator.optimal/files/rootfs/tmp/.vortek/V0'
replace_exactly_once "$UPSTREAM/vortek/include/winlator.h" \
  '/data/data/com.winlator/cache' \
  '/data/data/com.winlator.optimal/cache'
replace_exactly_once "$UPSTREAM/gladio/include/gladio.h" \
  '/data/data/com.winlator/files/rootfs/tmp/.X11-unix/X0' \
  '/data/data/com.winlator.optimal/files/rootfs/tmp/.X11-unix/X0'
replace_exactly_once "$UPSTREAM/gladio/include/winlator.h" \
  '/data/data/com.winlator/cache' \
  '/data/data/com.winlator.optimal/cache'

command -v aarch64-linux-gnu-gcc >/dev/null || fail 'aarch64-linux-gnu-gcc is missing'
command -v zstd >/dev/null || fail 'zstd is missing'
command -v cmake >/dev/null || fail 'cmake is missing'
command -v git >/dev/null || fail 'git is missing'

rm -rf "$WORK"
mkdir -p "$WORK"

# Use the Vulkan headers revision needed by the generated serializer. Ubuntu's
# packaged headers can lag behind the Vulkan API symbols used by this pinned source.
VULKAN_HEADERS="$WORK/Vulkan-Headers"
git clone --filter=blob:none --no-checkout https://github.com/KhronosGroup/Vulkan-Headers.git "$VULKAN_HEADERS"
git -C "$VULKAN_HEADERS" checkout --detach c46850864f4661461b0f6cb9922c058ffea4915e
test -f "$VULKAN_HEADERS/include/vulkan/vulkan.h" || fail 'Pinned Vulkan headers are missing'
VULKAN_INCLUDE="-I$VULKAN_HEADERS/include"

echo 'Building Vortek guest Vulkan driver for Linux ARM64...'
cmake -S "$UPSTREAM/vortek" -B "$WORK/vortek-build" \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_C_FLAGS=$VULKAN_INCLUDE \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-rpath,$ROOTFS_PATH"
cmake --build "$WORK/vortek-build" --parallel 2
VORTEK_SO="$WORK/vortek-build/libvulkan_vortek.so"
test -f "$VORTEK_SO" || fail "Vortek build output not found: $VORTEK_SO"

echo 'Building Gladio guest OpenGL driver for Linux ARM64...'
cmake -S "$UPSTREAM/gladio" -B "$WORK/gladio-build" \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_C_FLAGS=$VULKAN_INCLUDE \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-rpath,$ROOTFS_PATH"
cmake --build "$WORK/gladio-build" --parallel 2
GLADIO_SO="$WORK/gladio-build/libGL.so"
test -f "$GLADIO_SO" || fail "Gladio build output not found: $GLADIO_SO"

echo 'Packaging custom Vortek and Gladio assets...'
VORTEK_PACKAGE="$WORK/vortek-package"
GLADIO_PACKAGE="$WORK/gladio-package"
mkdir -p "$VORTEK_PACKAGE/usr/lib" "$VORTEK_PACKAGE/usr/share/vulkan/icd.d"
mkdir -p "$GLADIO_PACKAGE/usr/lib"

cp "$VORTEK_SO" "$VORTEK_PACKAGE/usr/lib/libvulkan_vortek.so"
cp "$GLADIO_SO" "$GLADIO_PACKAGE/usr/lib/libGL.so.1.7.0"
cat > "$VORTEK_PACKAGE/usr/share/vulkan/icd.d/vortek_icd.aarch64.json" <<'JSON'
{
    "ICD": {
        "api_version": "1.1.128",
        "library_path": "/data/data/com.winlator.optimal/files/rootfs/lib/libvulkan_vortek.so"
    },
    "file_format_version": "1.0.0"
}
JSON

mkdir -p "$APP/src/main/assets/graphics_driver"
tar --zstd -cf "$APP/src/main/assets/graphics_driver/vortek-2.1.tzst" -C "$VORTEK_PACKAGE" .
tar --zstd -cf "$APP/src/main/assets/graphics_driver/gladio-1.1.tzst" -C "$GLADIO_PACKAGE" .

# The base rootfs also contains an ALSA hook with an absolute upstream package path.
# Override only that config through rootfs_patches.tzst, which the app reapplies when
# preparing a container, rather than recompressing the entire 60+ MB rootfs archive.
ROOTFS_PATCHES="$WORK/rootfs-patches-package"
ALSA_CONF="$WORK/alsa.conf"
mkdir -p "$ROOTFS_PATCHES"
tar --zstd -xf "$APP/src/main/assets/rootfs_patches.tzst" -C "$ROOTFS_PATCHES"
tar --zstd -xOf "$APP/src/main/assets/rootfs.tzst" ./usr/share/alsa/alsa.conf > "$ALSA_CONF"
replace_exactly_once "$ALSA_CONF" \
  '/data/data/com.winlator/files/rootfs/etc/alsa/conf.d/android_aserver.conf' \
  '/data/data/com.winlator.optimal/files/rootfs/etc/alsa/conf.d/android_aserver.conf'
mkdir -p "$ROOTFS_PATCHES/usr/share/alsa"
cp "$ALSA_CONF" "$ROOTFS_PATCHES/usr/share/alsa/alsa.conf"
tar --zstd -cf "$APP/src/main/assets/rootfs_patches.tzst" -C "$ROOTFS_PATCHES" .

echo 'Verifying the packaged native paths...'
grep -Fq '/data/data/com.winlator.optimal/files/rootfs/lib/libvulkan_vortek.so' \
  "$VORTEK_PACKAGE/usr/share/vulkan/icd.d/vortek_icd.aarch64.json" || fail 'Vortek ICD path mismatch'
strings "$VORTEK_PACKAGE/usr/lib/libvulkan_vortek.so" | grep -F '/data/data/com.winlator.optimal/files/rootfs/tmp/.vortek/V0' >/dev/null || fail 'Vortek socket path missing'
strings "$GLADIO_PACKAGE/usr/lib/libGL.so.1.7.0" | grep -F '/data/data/com.winlator.optimal/files/rootfs/tmp/.X11-unix/X0' >/dev/null || fail 'Gladio socket path missing'
if strings "$VORTEK_PACKAGE/usr/lib/libvulkan_vortek.so" | grep -F '/data/data/com.winlator/files/rootfs/tmp/.vortek/V0' >/dev/null; then
  fail 'Vortek still contains the upstream package socket path'
fi
if strings "$GLADIO_PACKAGE/usr/lib/libGL.so.1.7.0" | grep -F '/data/data/com.winlator/files/rootfs/tmp/.X11-unix/X0' >/dev/null; then
  fail 'Gladio still contains the upstream package socket path'
fi

echo 'Custom Linux ARM64 graphics assets ready.'
