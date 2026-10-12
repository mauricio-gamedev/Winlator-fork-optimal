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


# Bump the graphics cache fingerprint so an installed broken build cannot keep using
# its already-extracted assets after this APK is upgraded.
replace_exactly_once "$APP/src/main/java/com/winlator/XServerDisplayActivity.java" \
  'cacheId += "-"+graphicsDriver[1]+"-"+DefaultVersion.valueOf(graphicsDriver[1]);' \
  'cacheId += "-"+graphicsDriver[1]+"-"+DefaultVersion.valueOf(graphicsDriver[1])+"-optimal-assets-r2";'

# Keep launch diagnostics for the first 180 seconds and replace the endless preloader
# with a useful error report if Wine never maps a renderable X11 window.
python3 - "$APP/src/main/java/com/winlator/XServerDisplayActivity.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()

def replace_once(old, new, label):
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one occurrence, found {count}")
    source = source.replace(old, new, 1)

replace_once(
    "    private SharedPreferences preferences;\n",
    """    private SharedPreferences preferences;
    private android.os.Handler startupHandler;
    private Runnable startupTimeoutRunnable;
    private Callback<String> startupLogCallback;
    private ContentDialog startupTimeoutDialog;
    private final StringBuilder startupLogBuffer = new StringBuilder();
    private final Object startupLogLock = new Object();
    private boolean startupWindowVisible = false;
""",
    "startup fields"
)

replace_once(
    "        preloaderDialog.show(R.string.starting_up);\n",
    """        preloaderDialog.show(R.string.starting_up);
        startupWindowVisible = false;
        startupLogBuffer.setLength(0);
        startupLogCallback = (line) -> {
            synchronized (startupLogLock) {
                startupLogBuffer.append(line).append('\\n');
                if (startupLogBuffer.length() > 12000) {
                    startupLogBuffer.delete(0, startupLogBuffer.length() - 12000);
                }
            }
        };
        ProcessHelper.addDebugCallback(startupLogCallback);
        startupHandler = new android.os.Handler(android.os.Looper.getMainLooper());
        startupTimeoutRunnable = () -> {
            if (startupWindowVisible || isFinishing() || isGenerateWineprefix()) {
                ProcessHelper.removeDebugCallback(startupLogCallback);
                return;
            }

            preloaderDialog.close();
            String logSnapshot;
            synchronized (startupLogLock) {
                logSnapshot = startupLogBuffer.toString();
            }
            if (logSnapshot.length() > 2200) {
                logSnapshot = logSnapshot.substring(logSnapshot.length() - 2200);
            }

            String message = "Nenhuma janela do Wine apareceu após 180 segundos. "
                + "A inicialização será encerrada para evitar o carregamento infinito. "
                + "As últimas mensagens do processo estão abaixo; envie-as para localizar "
                + "a causa caso a correção gráfica não resolva o problema.\\n\\n"
                + (logSnapshot.isEmpty() ? "(O processo não produziu mensagens de diagnóstico.)" : logSnapshot);

            startupTimeoutDialog = new ContentDialog(this);
            startupTimeoutDialog.setTitle("Inicialização não concluída");
            startupTimeoutDialog.setMessage(message);
            startupTimeoutDialog.findViewById(R.id.BTCancel).setVisibility(View.GONE);
            startupTimeoutDialog.setOnConfirmCallback(this::finish);
            startupTimeoutDialog.setCancelable(false);
            startupTimeoutDialog.show();
        };
        if (!isGenerateWineprefix()) startupHandler.postDelayed(startupTimeoutRunnable, 180000L);
""",
    "startup watchdog"
)

replace_once(
    "                    preloaderDialog.closeOnUiThread();\n                    flags[0] = true;\n",
    """                    startupWindowVisible = true;
                    if (startupHandler != null) startupHandler.removeCallbacks(startupTimeoutRunnable);
                    if (startupLogCallback != null) ProcessHelper.removeDebugCallback(startupLogCallback);
                    if (startupTimeoutDialog != null && startupTimeoutDialog.isShowing()) startupTimeoutDialog.dismiss();
                    preloaderDialog.closeOnUiThread();
                    flags[0] = true;
""",
    "startup success cleanup"
)

replace_once(
    "        winHandler.stop();\n        if (environment != null) environment.stopEnvironmentComponents();\n        ForegroundService.stopSession(this);\n",
    """        winHandler.stop();
        if (startupHandler != null && startupTimeoutRunnable != null) startupHandler.removeCallbacks(startupTimeoutRunnable);
        if (startupLogCallback != null) ProcessHelper.removeDebugCallback(startupLogCallback);
        if (startupTimeoutDialog != null && startupTimeoutDialog.isShowing()) startupTimeoutDialog.dismiss();
        if (environment != null) environment.stopEnvironmentComponents();
        ForegroundService.stopSession(this);
""",
    "startup destroy cleanup"
)

path.write_text(source)
print("Patched XServerDisplayActivity with asset cache invalidation and startup diagnostics.")
PY

command -v aarch64-linux-gnu-gcc >/dev/null || fail 'aarch64-linux-gnu-gcc is missing'
command -v zstd >/dev/null || fail 'zstd is missing'
command -v cmake >/dev/null || fail 'cmake is missing'
command -v git >/dev/null || fail 'git is missing'

rm -rf "$WORK"
mkdir -p "$WORK"

# Record the upstream archive layout before replacing the assets. This is part of the
# regression audit: runtime paths in ICD JSON files must exist after tar extraction.
echo 'Upstream Vortek asset members:'
tar --zstd -tf "$APP/src/main/assets/graphics_driver/vortek-2.1.tzst"
echo 'Upstream Gladio asset members:'
tar --zstd -tf "$APP/src/main/assets/graphics_driver/gladio-1.1.tzst"

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
mkdir -p "$VORTEK_PACKAGE/lib" "$VORTEK_PACKAGE/usr/lib" "$VORTEK_PACKAGE/usr/share/vulkan/icd.d"
mkdir -p "$GLADIO_PACKAGE/usr/lib"

# IMPORTANT: the ICD JSON uses an Android absolute path ending in /rootfs/lib,
# while the normal guest linker also searches /rootfs/usr/lib. Keep the driver in
# both locations so the explicit ICD path and guest library search path agree.
cp "$VORTEK_SO" "$VORTEK_PACKAGE/lib/libvulkan_vortek.so"
cp "$VORTEK_SO" "$VORTEK_PACKAGE/usr/lib/libvulkan_vortek.so"

# Wine/GLX loaders resolve libGL.so or libGL.so.1, not only the versioned file.
cp "$GLADIO_SO" "$GLADIO_PACKAGE/usr/lib/libGL.so.1.7.0"
ln -sfn libGL.so.1.7.0 "$GLADIO_PACKAGE/usr/lib/libGL.so.1"
ln -sfn libGL.so.1 "$GLADIO_PACKAGE/usr/lib/libGL.so"
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

echo 'Verifying packaged asset layout, ABI, and native paths...'

# Check the extracted result, not just the source staging directory.
VORTEK_VERIFY="$WORK/verify-vortek"
GLADIO_VERIFY="$WORK/verify-gladio"
mkdir -p "$VORTEK_VERIFY" "$GLADIO_VERIFY"
tar --zstd -xf "$APP/src/main/assets/graphics_driver/vortek-2.1.tzst" -C "$VORTEK_VERIFY"
tar --zstd -xf "$APP/src/main/assets/graphics_driver/gladio-1.1.tzst" -C "$GLADIO_VERIFY"

test -s "$VORTEK_VERIFY/lib/libvulkan_vortek.so" || fail 'Vortek ICD target missing from rootfs/lib'
test -s "$VORTEK_VERIFY/usr/lib/libvulkan_vortek.so" || fail 'Vortek guest linker target missing from rootfs/usr/lib'
test -L "$GLADIO_VERIFY/usr/lib/libGL.so.1" || fail 'Gladio libGL.so.1 symlink missing'
test -L "$GLADIO_VERIFY/usr/lib/libGL.so" || fail 'Gladio libGL.so symlink missing'
test "$(readlink "$GLADIO_VERIFY/usr/lib/libGL.so.1")" = "libGL.so.1.7.0" || fail 'Gladio soname symlink target mismatch'
test "$(readlink "$GLADIO_VERIFY/usr/lib/libGL.so")" = "libGL.so.1" || fail 'Gladio linker symlink target mismatch'

python3 - "$VORTEK_VERIFY/usr/share/vulkan/icd.d/vortek_icd.aarch64.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text())
expected = "/data/data/com.winlator.optimal/files/rootfs/lib/libvulkan_vortek.so"
actual = data["ICD"]["library_path"]
if actual != expected:
    raise SystemExit(f"Vortek ICD path mismatch: {actual!r} != {expected!r}")
print(f"Vortek ICD points to: {actual}")
PY

aarch64-linux-gnu-readelf -h "$VORTEK_VERIFY/lib/libvulkan_vortek.so" | grep -Eq 'Machine:.*AArch64' || fail 'Vortek library is not Linux ARM64'
aarch64-linux-gnu-readelf -h "$GLADIO_VERIFY/usr/lib/libGL.so.1.7.0" | grep -Eq 'Machine:.*AArch64' || fail 'Gladio library is not Linux ARM64'

strings "$VORTEK_VERIFY/lib/libvulkan_vortek.so" | grep -F '/data/data/com.winlator.optimal/files/rootfs/tmp/.vortek/V0' >/dev/null || fail 'Vortek socket path missing'
strings "$GLADIO_VERIFY/usr/lib/libGL.so.1.7.0" | grep -F '/data/data/com.winlator.optimal/files/rootfs/tmp/.X11-unix/X0' >/dev/null || fail 'Gladio socket path missing'
if strings "$VORTEK_VERIFY/lib/libvulkan_vortek.so" | grep -F '/data/data/com.winlator/files/rootfs/tmp/.vortek/V0' >/dev/null; then
  fail 'Vortek still contains the upstream package socket path'
fi
if strings "$GLADIO_VERIFY/usr/lib/libGL.so.1.7.0" | grep -F '/data/data/com.winlator/files/rootfs/tmp/.X11-unix/X0' >/dev/null; then
  fail 'Gladio still contains the upstream package socket path'
fi

# Verify the ALSA override survives the archive round-trip.
ROOTFS_PATCHES_VERIFY="$WORK/verify-rootfs-patches"
mkdir -p "$ROOTFS_PATCHES_VERIFY"
tar --zstd -xf "$APP/src/main/assets/rootfs_patches.tzst" -C "$ROOTFS_PATCHES_VERIFY"
grep -Fq '/data/data/com.winlator.optimal/files/rootfs/etc/alsa/conf.d/android_aserver.conf' \
  "$ROOTFS_PATCHES_VERIFY/usr/share/alsa/alsa.conf" || fail 'Fork-specific ALSA path is missing'

echo 'Custom Linux ARM64 graphics assets passed layout and ABI validation.'
