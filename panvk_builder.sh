#!/bin/bash -e

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)/panvk_workdir"
magiskdir="$workdir/panvk_module"
ndkver="android-ndk-r28b"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip"

run_all(){
    check_deps
    prepare_workdir
    build_panvk_for_android
    port_panvk_for_magisk
    port_panvk_for_adrenotools
}

check_deps(){
    echo "Checking system for required Dependencies ..."
    for d in $deps; do
        sleep 0.2
        if command -v "$d" >/dev/null 2>&1; then
            echo -e "$green - $d found $nocolor"
        else
            echo -e "$red - $d not found. Install it first. $nocolor"
            exit 1
        fi
    done
    echo "Installing python Mako dependency ..." $'\n'
    pip install mako &> /dev/null
}

prepare_workdir(){
    echo "Preparing work directory ..." $'\n'
    mkdir -p "$workdir" && cd "$workdir"
    echo "Downloading android-ndk ..." $'\n'
    curl -s https://dl.google.com/android/repository/"$ndkver"-linux.zip -o "$ndkver"-linux.zip
    echo "Extracting android-ndk ..." $'\n'
    unzip -q "$ndkver"-linux.zip
    echo "Downloading Mesa source ..." $'\n'
    curl -s "$mesasrc" -o mesa-main.zip
    echo "Extracting Mesa source ..." $'\n'
    unzip -q mesa-main.zip
    cd mesa-main
}

build_panvk_for_android(){
    mkdir -p "$workdir/bin"
    ln -sf "$ndk/clang" "$workdir/bin/cc"
    ln -sf "$ndk/clang++" "$workdir/bin/c++"
    export PATH="$workdir/bin:$ndk:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld"

    echo "Generating build files ..." $'\n'
    cat <<EOF > android-aarch64.txt
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF > native.txt
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    meson setup build-android-aarch64 \
        --cross-file android-aarch64.txt \
        --native-file native.txt \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version="$sdkver" \
        -Dandroid-stub=true \
        -Dgallium-drivers=panfrost \
        -Dvulkan-drivers=panfrost \
        -Dvulkan-beta=true \
        -Dstrip=true \
        -Db_lto=true \
        -Degl=disabled \
        -Dglx=disabled \
        -Dpanvk=true | tee "$workdir/meson_log"

    echo "Compiling build files ..." $'\n'
    ninja -C build-android-aarch64 | tee "$workdir/ninja_log"

    outlib="build-android-aarch64/src/panfrost/vulkan/libvulkan_panfrost.so"
    if ! [ -f "$outlib" ]; then
        echo -e "$red Build failed! $nocolor"
        exit 1
    fi
}

port_panvk_for_magisk(){
    echo "Preparing Magisk module ..." $'\n'
    cp build-android-aarch64/src/panfrost/vulkan/libvulkan_panfrost.so "$workdir"
    cd "$workdir"
    patchelf --set-soname vulkan.mali.so libvulkan_panfrost.so
    mv libvulkan_panfrost.so vulkan.mali.so

    p1="system/vendor/lib64/hw"
    mkdir -p "$magiskdir/$p1"
    meta="$magiskdir/META-INF/com/google/android"
    mkdir -p "$meta"

    cat <<EOF >"$meta/update-binary"
umask 022
ui_print() { echo "\$1"; }
OUTFD=\$2
ZIPFILE=\$3
. /data/adb/magisk/util_functions.sh
install_module
exit 0
EOF

    echo "#MAGISK" > "$meta/updater-script"

    cat <<EOF >"$magiskdir/module.prop"
id=panvk
name=panvk Vulkan
version=$(date +%Y%m%d)
versionCode=1
author=PanVK Build Script
description=PanVK Vulkan driver for Mali (Panfrost)
EOF

    cat <<EOF >"$magiskdir/customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/vulkan.mali.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF

    cp vulkan.mali.so "$magiskdir/$p1"

    echo "Packing Magisk module ..." $'\n'
    cd "$magiskdir"
    zip -r "$workdir/panvk_magisk.zip" ./* > /dev/null

    if ! [ -f "$workdir/panvk_magisk.zip" ]; then
        echo -e "$red-Packing failed!$nocolor"
    else
        echo -e "$green-Magisk module saved at:$nocolor $workdir/panvk_magisk.zip"
    fi
}

port_panvk_for_adrenotools(){
    echo "Preparing Adrenotools zip ..." $'\n'
    cd "$workdir"
    cp build-android-aarch64/src/panfrost/vulkan/libvulkan_panfrost.so vulkan.panfrost.so
    patchelf --set-soname vulkan.panfrost.so vulkan.panfrost.so

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "panvk_mali",
  "description": "PanVK Vulkan driver built from Mesa",
  "author": "MrMiy4mo adapted",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$(date +%Y%m%d)",
  "minApi": $sdkver,
  "libraryName": "vulkan.panfrost.so"
}
EOF

    zip -9 panvk_adrenotools.zip vulkan.panfrost.so meta.json &> /dev/null
    if ! [ -f panvk_adrenotools.zip ]; then
        echo -e "$red-Adrenotools zip failed!$nocolor"
    else
        echo -e "$green-Adrenotools zip saved at:$nocolor $workdir/panvk_adrenotools.zip"
    fi
}

run_all
