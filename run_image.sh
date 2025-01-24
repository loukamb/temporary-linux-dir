qemu-system-x86_64 \
  -m 4G \
  -enable-kvm \
  -cpu host \
  -boot d \
  -cdrom output/seedlinux.iso \
  -display gtk