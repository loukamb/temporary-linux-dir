#!/bin/bash
set -e

check_python_dependencies() {
    local missing_modules=()
    local required_modules=(
        "jinja2"
        "yaml"
        "lxml"
        "docutils"
        "pygments"
    )

    # First check if python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is not installed"
        return 1
    fi

    # Check for each required Python module
    for module in "${required_modules[@]}"; do
        if ! python3 -c "import $module" 2>/dev/null; then
            missing_modules+=("python-$module")
        fi
    done

    if [ ${#missing_modules[@]} -ne 0 ]; then
        echo "Error: Missing required Python modules: ${missing_modules[*]}"
        return 1
    fi

    return 0
}

# Check for required tools
check_requirements() {
    local missing_tools=()
    local required_tools=(
        "wget"
        "tar"
        "gcc"
        "make"
        "bc"
        "git"
        "meson"
        "ninja"
        "grub-mkrescue"
        "gperf"
        "xorriso"
        "flex" 
        "bison"
        "m4"
        "perl"
        "pkg-config"
        "gettext"
        "mtools"
    )

    # Arch package names for development libraries
    local required_packages=(
        "libcap"
        "acl"
        "lz4"
        "pam"
        "libseccomp"
        "pcre2"
        "libgcrypt"
        "libgpg-error"
        "apparmor"
        "audit"
        "dbus"
        "cryptsetup"
        "kmod"
        "libmicrohttpd"
        "gnu-efi"
        "python"
        "asciidoctor"
        "docbook-xsl"
    )

    # Check for tools using command -v
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    # Check for packages using pacman
    for package in "${required_packages[@]}"; do
        if ! pacman -Q "$package" >/dev/null 2>&1; then
            missing_tools+=("$package")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo "Error: Missing required tools/packages: ${missing_tools[*]}"
        echo "You can install them using:"
        echo "sudo pacman -S ${missing_tools[*]}"
        exit 1
    fi

    # Check Python dependencies
    if ! check_python_dependencies; then
        exit 1
    fi
}

# Configuration
WORKDIR="$(pwd)/build"
OUTPUT_DIR="$(pwd)/output"
SOURCES_DIR="$WORKDIR/sources"
SOURCES_CACHE="$(pwd)/sources-cache"
SYSROOT="$WORKDIR/sysroot"

# Component versions
KERNEL_VERSION="6.6.72"
SYSTEMD_VERSION="257.2"
BASH_VERSION="5.2.21"
LUA_VERSION="5.4.7"
GNU_BINUTILS_VERSION="2.41"
GNU_GCC_VERSION="13.2.0"
GNU_GLIBC_VERSION="2.39"
GNU_COREUTILS_VERSION="9.4"

# Create directory structure
mkdir -p "$WORKDIR" "$OUTPUT_DIR" "$SOURCES_DIR" "$SYSROOT"
mkdir -p "$SYSROOT"/{bin,sbin,lib,lib64,usr,etc,var,boot,proc,sys,dev,run,tmp}

download_sources() {
    # Create cache directory if it doesn't exist
    mkdir -p "$SOURCES_CACHE"
    
    cd "$SOURCES_CACHE"
    
    # Function to download only if not in cache
    download_if_missing() {
        local url="$1"
        local filename=$(basename "$url")
        if [ ! -f "$filename" ]; then
            echo "Downloading $filename..."
            wget "$url"
        else
            echo "Using cached $filename"
        fi
    }
    
    # Download kernel
    download_if_missing "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
    
    # Download systemd
    download_if_missing "https://github.com/systemd/systemd/archive/v$SYSTEMD_VERSION.tar.gz"
    
    # Download GNU components
    download_if_missing "https://ftp.gnu.org/gnu/binutils/binutils-$GNU_BINUTILS_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/gcc/gcc-$GNU_GCC_VERSION/gcc-$GNU_GCC_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/glibc/glibc-$GNU_GLIBC_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/coreutils/coreutils-$GNU_COREUTILS_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/bash/bash-$BASH_VERSION.tar.gz"
    
    # Download Lua
    download_if_missing "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"
    
    # Copy cached files to sources directory
    mkdir -p "$SOURCES_DIR"
    cp -u *.tar.* "$SOURCES_DIR/"
}

extract_sources() {
    cd "$SOURCES_DIR"
    
    # Extract all sources
    for archive in *.tar.*; do
        tar xf "$archive"
    done
}

build_kernel() {
    cd "$SOURCES_DIR/linux-$KERNEL_VERSION"
    
    # Copy the provided .config
    cp "$WORKDIR/../.config" .

    # Build kernel
    make -s V=0 -j$(nproc) 2>&1 | grep -E "error|Error|ERROR|warning|Warning|WARNING"
    
    # Install kernel and modules
    make INSTALL_MOD_PATH="$SYSROOT" modules_install
    cp arch/x86_64/boot/bzImage "$SYSROOT/boot/vmlinuz"
}

build_systemd() {
    cd "$SOURCES_DIR/systemd-$SYSTEMD_VERSION"
    
    mkdir build && cd build
    meson setup \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        -Drootprefix="" \
        -Dsplit-usr=false \
        -Defi=true \
        -Dbootloader=enabled \
        ..
    
    ninja
    DESTDIR="$SYSROOT" ninja install
}

build_bootloader() {
    # Install systemd-boot
    mkdir -p "$SYSROOT/boot/efi/EFI/BOOT"
    cp "$SYSROOT/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
        "$SYSROOT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    
    # Create basic loader configuration
    mkdir -p "$SYSROOT/boot/loader/entries"
    cat > "$SYSROOT/boot/loader/loader.conf" << EOF
default arch
timeout 3
editor 0
EOF

    cat > "$SYSROOT/boot/loader/entries/arch.conf" << EOF
title Linux
linux /vmlinuz
initrd /initramfs.img
options root=/dev/ram0 rw
EOF
}

build_initramfs() {
    # Install mkinitcpio
    cd "$SOURCES_DIR"
    if [ ! -d "mkinitcpio" ]; then
        git clone https://github.com/archlinux/mkinitcpio.git
    fi
    cd mkinitcpio
    
    # Build and install with meson
    meson setup build \
        --prefix=/usr \
        --sysconfdir=/etc
    meson compile -C build
    DESTDIR="$SYSROOT" meson install -C build
    
    # Configure mkinitcpio
    cat > "$SYSROOT/etc/mkinitcpio.conf" << EOF
MODULES=(ext4)
BINARIES=()
FILES=()
HOOKS=(base udev memdisk autodetect modconf block filesystems keyboard)
EOF

    # The kernel modules should be in $SYSROOT/lib/modules/$KERNEL_VERSION
    # Let's verify the directory exists and has the correct permissions
    if [ ! -d "$SYSROOT/lib/modules/$KERNEL_VERSION" ]; then
        echo "Error: Kernel modules directory not found!"
        echo "Expected: $SYSROOT/lib/modules/$KERNEL_VERSION"
        ls -la "$SYSROOT/lib/modules"
        exit 1
    fi

        # Generate initramfs with correct paths
    KERNEL_MODULES_DIR="$SYSROOT/lib/modules/$KERNEL_VERSION" \
    mkinitcpio \
        -k "$KERNEL_VERSION" \
        -g "$SYSROOT/boot/initramfs.img" \
        -r "$SYSROOT" \
        -c "$SYSROOT/etc/mkinitcpio.conf"
}

build_gnu_userland() {
    # Build and install GNU components
    cd "$SOURCES_DIR"
    
    # Build binutils first
    cd "binutils-$GNU_BINUTILS_VERSION"
    ./configure --prefix=/usr
    make -j$(nproc)
    make DESTDIR="$SYSROOT" install
    cd ..
    
    # Build GCC
    # TODO: Re-enable this when I don't wanna recompile EVERYTHING
    : "
    cd "gcc-$GNU_GCC_VERSION"
    ./configure --prefix=/usr \
        --enable-languages=c,c++ \
        --disable-multilib
    make -j$(nproc)
    make DESTDIR="$SYSROOT" install
    cd ..
    "
    
    # Build glibc
    cd "glibc-$GNU_GLIBC_VERSION"
    mkdir build && cd build
    ../configure --prefix=/usr
    make -j$(nproc)
    make DESTDIR="$SYSROOT" install
    cd ../..
    
    # Build coreutils
    cd "coreutils-$GNU_COREUTILS_VERSION"
    ./configure --prefix=/usr
    make -j$(nproc)
    make DESTDIR="$SYSROOT" install
    cd ..
}

build_bash() {
    cd "$SOURCES_DIR/bash-$BASH_VERSION"
    ./configure --prefix=/usr
    make -j$(nproc)
    make DESTDIR="$SYSROOT" install
    
    # Set bash as default shell
    ln -sf bash "$SYSROOT/bin/sh"
}

build_lua() {
    cd "$SOURCES_DIR/lua-$LUA_VERSION"
    # Adjust Makefile for proper installation paths
    sed -i 's/INSTALL_TOP= \/local/INSTALL_TOP= \/usr/' Makefile
    sed -i "s/INSTALL_MAN= ${INSTALL_TOP}\/man\/man1/INSTALL_MAN= ${INSTALL_TOP}\/share\/man\/man1/" Makefile
    make linux -j$(nproc)
    make INSTALL_TOP="$SYSROOT/usr" install
}

create_iso() {
    # Create ISO directory structure
    mkdir -p "$WORKDIR/iso/boot/grub"
    cp -r "$SYSROOT"/* "$WORKDIR/iso/"
    
    # Generate GRUB configuration
    cat > "$WORKDIR/iso/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0

menuentry "Seed Linux" {
    linux /boot/vmlinuz init=/sbin/init root=/dev/ram0 rw initrd=/boot/initramfs.img
    initrd /boot/initramfs.img
}
EOF
    
    # Create ISO
    grub-mkrescue -o "$OUTPUT_DIR/seedlinux.iso" "$WORKDIR/iso"
}

main() {
    check_requirements
    
    # Clean up sysroot
    echo "Cleaning up sysroot..."
    rm -rf "$SYSROOT"
    mkdir -p "$SYSROOT"/{bin,sbin,lib,lib64,usr,etc,var,boot,proc,sys,dev,run,tmp}
    chmod 1777 "$SYSROOT/tmp"
    
    # Clean up sources directory but keep cache
    echo "Cleaning up sources directory..."
    rm -rf "$SOURCES_DIR"
    mkdir -p "$SOURCES_DIR"
    download_sources
    extract_sources
    build_kernel
    build_systemd
    build_bootloader
    build_initramfs
    build_gnu_userland
    build_bash
    build_lua
    create_iso
    
    echo "Build completed successfully!"
    echo "ISO image is available at: $OUTPUT_DIR/seedlinux.iso"
}

main "$@"