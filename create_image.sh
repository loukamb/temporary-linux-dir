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
        "dracut"
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
RUNIT_VERSION="2.1.2"
DRACUT_VERSION="059"
BASH_VERSION="5.2.21"
LUA_VERSION="5.4.7"
GNU_BINUTILS_VERSION="2.41"
GNU_GCC_VERSION="13.2.0"
GNU_GLIBC_VERSION="2.39"
GNU_COREUTILS_VERSION="9.4"

# Create directory structure
mkdir -p "$WORKDIR" "$OUTPUT_DIR" "$SOURCES_DIR" "$SYSROOT"
mkdir -p "$SYSROOT"/{bin,sbin,lib,lib64,usr,etc,var,boot,proc,sys,dev,run,tmp}
mkdir -p "$SYSROOT/etc/runit/sv"
mkdir -p "$SYSROOT/service"
download_sources() {
    mkdir -p "$SOURCES_CACHE"
    cd "$SOURCES_CACHE"

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

    # Download runit
    download_if_missing "http://smarden.org/runit/runit-$RUNIT_VERSION.tar.gz"

    # Download initramfs
    download_if_missing "https://github.com/dracutdevs/dracut/archive/refs/tags/${DRACUT_VERSION}.tar.gz"

    # Download GNU components
    download_if_missing "https://ftp.gnu.org/gnu/binutils/binutils-$GNU_BINUTILS_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/gcc/gcc-$GNU_GCC_VERSION/gcc-$GNU_GCC_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/glibc/glibc-$GNU_GLIBC_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/coreutils/coreutils-$GNU_COREUTILS_VERSION.tar.xz"
    download_if_missing "https://ftp.gnu.org/gnu/bash/bash-$BASH_VERSION.tar.gz"

    # Download Lua
    download_if_missing "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"

    mkdir -p "$SOURCES_DIR"
    cp -u *.tar.* "$SOURCES_DIR/"
}

extract_sources() {
    cd "$SOURCES_DIR"

    # Extract archives only if their directory doesn't exist
    for archive in *.tar.*; do
        # Get directory name by removing extension(s)
        dir_name=$(echo "$archive" | sed -E 's/\.tar\.(gz|xz|bz2)$//')

        if [ ! -d "$dir_name" ]; then
            echo "Extracting $archive..."
            tar xf "$archive"
        else
            echo "Skipping extraction of $archive - directory $dir_name already exists"
        fi
    done
}

build_kernel() {
    cd "$SOURCES_DIR/linux-$KERNEL_VERSION"
    cp "$WORKDIR/../.config" .
    make -s V=0 -j$(nproc) 2>&1 | grep -E "error|Error|ERROR|warning|Warning|WARNING"
    make INSTALL_MOD_PATH="$SYSROOT" modules_install
    cp arch/x86_64/boot/bzImage "$SYSROOT/boot/vmlinuz"
}

build_runit() {
    cd "$SOURCES_DIR/admin/runit-$RUNIT_VERSION"

    # Compile runit
    ./package/compile

    # Install runit
    mkdir -p "$SYSROOT/sbin"
    cp command/* "$SYSROOT/sbin/"

    # Create basic runit directories and scripts
    mkdir -p "$SYSROOT/etc/runit"/{1,2,3}.d
    mkdir -p "$SYSROOT/etc/sv"

    # Create stage 1 script
    cat >"$SYSROOT/etc/runit/1" <<'EOF'
#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Mount virtual filesystems
mountpoint -q /proc    || mount -t proc proc /proc -o nosuid,noexec,nodev
mountpoint -q /sys     || mount -t sysfs sys /sys -o nosuid,noexec,nodev
mountpoint -q /dev     || mount -t devtmpfs dev /dev -o mode=0755,nosuid
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts -o mode=0620,gid=5,nosuid,noexec

# Start udev
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon
    udevadm trigger --action=add --type=subsystems
    udevadm trigger --action=add --type=devices
    udevadm settle
fi

touch /etc/runit/stopit
chmod 0 /etc/runit/stopit
EOF

    # Create stage 2 script
    cat >"$SYSROOT/etc/runit/2" <<'EOF'
#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin

runsvdir -P /service 'log: ...........................................................................................................................................'
EOF

    # Create stage 3 script
    cat >"$SYSROOT/etc/runit/3" <<'EOF'
#!/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin

echo 'Waiting for services to stop...'
sv -w196 force-stop /service/*
sv exit /service/*

echo 'Stopping runsvdir...'
killall runsvdir

echo 'Unmounting filesystems...'
umount -a -r

# Power off
echo 'Powering off...'
halt -p
EOF

    chmod +x "$SYSROOT/etc/runit/"{1,2,3}

    # Create basic services
    mkdir -p "$SYSROOT/etc/sv/getty-tty1/"{log,supervise}
    cat >"$SYSROOT/etc/sv/getty-tty1/run" <<'EOF'
#!/bin/sh
exec setsid getty 38400 tty1
EOF
    chmod +x "$SYSROOT/etc/sv/getty-tty1/run"

    # Create symlink for default services
    ln -s /etc/sv/getty-tty1 "$SYSROOT/service/"
}

build_bootloader() {
    mkdir -p "$SYSROOT/boot/grub"

    cat >"$SYSROOT/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "Seed Linux" {
    linux /boot/vmlinuz init=/sbin/runit-init root=/dev/ram0 rw
    initrd /boot/initramfs.img
}
EOF
}

check_critical_files() {
    local files=(
        "$SYSROOT/bin/sh"
        "$SYSROOT/sbin/runit"
        "$SYSROOT/sbin/runit-init"
        "$SYSROOT/etc/runit/1"
        "$SYSROOT/etc/runit/2"
        "$SYSROOT/etc/runit/3"
    )

    for file in "${files[@]}"; do
        if [ ! -e "$file" ]; then
            echo "Error: Critical file/directory missing: $file"
            exit 1
        fi
    done
}
build_initramfs() {
    echo "Building and installing dracut..."

    cd "$SOURCES_DIR"
    tar xf "${DRACUT_VERSION}.tar.gz"
    cd "dracut-${DRACUT_VERSION}"

    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --libdir=/usr/lib

    make -j$(nproc)
    make DESTDIR="$SYSROOT" install

    mkdir -p "$SYSROOT"/{etc/dracut.conf.d,var/tmp,run,sys,proc,dev}
    chmod 1777 "$SYSROOT/var/tmp"

    cat >"$SYSROOT/etc/dracut.conf.d/01-basic.conf" <<EOF
# Add base drivers and filesystems
add_drivers+=" ext4 "
add_dracutmodules+=" base kernel-modules fs-lib "
force_drivers+=" brd "

# Include basic system utilities
install_items+=" /bin/sh /bin/bash /bin/mount /bin/umount /sbin/runit /sbin/runit-init "
EOF

    check_critical_files

    "$SYSROOT/usr/bin/dracut" \
        --force \
        --no-compress \
        --kver "$KERNEL_VERSION" \
        --modules "base kernel-modules fs-lib" \
        --drivers "ext4 brd" \
        --sysroot "$SYSROOT" \
        --no-hostonly \
        --add-drivers "ext4 brd" \
        "$SYSROOT/boot/initramfs.img"

    if [ ! -f "$SYSROOT/boot/initramfs.img" ]; then
        echo "Error: Failed to generate initramfs!"
        exit 1
    fi
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
    mkdir -p build && cd build
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
    ln -sf "$SYSROOT/usr/bin/bash" "$SYSROOT/bin/sh"
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
    mkdir -p "$WORKDIR/iso/boot/grub"
    cp -r "$SYSROOT"/* "$WORKDIR/iso/"

    cat >"$WORKDIR/iso/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "Seed Linux" {
    linux /boot/vmlinuz init=/sbin/runit-init root=/dev/ram0 rw
    initrd /boot/initramfs.img
}
EOF

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
    build_gnu_userland
    build_bash
    build_runit
    build_kernel
    build_bootloader
    build_initramfs
    build_lua
    create_iso

    echo "Build completed successfully!"
    echo "ISO image is available at: $OUTPUT_DIR/seedlinux.iso"
}

main "$@"
