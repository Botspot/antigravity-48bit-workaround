<a href="https://github.com/Botspot/pi-apps"><img src="https://github.com/Botspot/pi-apps/blob/master/icons/badge.png?raw=true" align="right"/></a>
# antigravity-48bit-workaround
Bash scripts to run the Google Antigravity IDE language server on an ARM kernel with 39 bits of address space

Google's Antigravity IDE has this problem where the ARM64 language server is compiled for enterprise servers and newer ARM CPUs, which use 48 bits of address space, instead of 39 bits which is more common on consumer devices.
If you know where to look, you would see these error messages:
```
third_party/tcmalloc/internal/system_allocator.h:589] MmapAligned() failed - unable to allocate with tag (hint=0x2e6680000000, size=1073741824, alignment=1073741824) - is something limiting address placement?
third_party/tcmalloc/internal/system_allocator.h:596] Note: the allocation may have failed because TCMalloc assumes a 48-bit virtual address space size; you may need to rebuild TCMalloc with TCMALLOC_ADDRESS_BITS defined to your system's virtual address space size
third_party/tcmalloc/arena.cc:60] CHECK in Alloc: FATAL ERROR: Out of memory trying to allocate internal tcmalloc data (bytes=131072, object-size=16384); is something preventing mmap from succeeding (sandbox, VSS limitations)?
```
While Antigravity itself would install and run fine, you can't use any of the AI features, which completely defeats the point.

There are 3 solutions to this:

1. Recompile the host kernel to use 48 bits of address space
2. Use a device and OS which already has a compatible kernel (Raspberry Pi 5 with the 16k page size kernel)
3. Emulate the language server binary under a 48bit kernel, using a QEMU virtual machine, and painstakingly route all communications between the Antigravity IDE and the language server process running inside the VM.

**This repo accomplishes option 3.**  
An Antigravity update has already [broken](https://github.com/Botspot/pi-apps/issues/2952) the implementation once. This is a partial rewrite, which I'm hoping will continue working for longer. I've moved the code here, and out of [the Pi-apps Antigravity install script](https://github.com/Botspot/pi-apps/blob/master/apps/Antigravity/install-64), to make it easier for others to inspect the code and hopefully help keep this working into the future.

For whatever reason the language server communicates using stdin, stdout, a socket file, and numerous random network ports on localhost, as well as api endpoints on the open internet. On top of that, now it seems that *two* language server processes need to be running at once, and they both need to talk to the IDE simultaneously without any port conflicts. I'm not sure why this has to be so complicated, but it was a total nightmare to get everything talking correctly. In fact the only reason it works at all is because the language server allows disabling port number randomization with command-line flags.

## Troubleshooting
If you get an error in Antigravity saying that the language server crashed, or is not responding, check the logs here in this folder:
```
~/.cache/antigravity-48bit-workaround
```

## Get started

It's recommended to simply install Antigravity from Pi-Apps, which will apply this workaround automatically. [![badge](https://github.com/Botspot/pi-apps/blob/master/icons/badge.png?raw=true)](https://github.com/Botspot/pi-apps)  
If you don't want to do that for some reason, here's instructions for how to use the code here on this repo.

Once you have Antigravity installed, install these dependenciees: `qemu-system-arm ipxe-qemu git bc bison flex libssl-dev make gcc libelf-dev socat`

Then run these commands:
```bash
#setup main folder to host the kernel and wrapper files
sudo mkdir -p /usr/share/antigravity/resources/antigravity-48bit-workaround

#move problematic language server binary
if [ ! -h /usr/share/antigravity/resources/app/extensions/antigravity/bin/language_server_linux_arm ];then
  #only do this if it's the actual binary, not the symbolic link created from a previous install
  sudo mv -f /usr/share/antigravity/resources/app/extensions/antigravity/bin/language_server_linux_arm /usr/share/antigravity/resources/antigravity-48bit-workaround
fi

#copy in wrapper files
cd /tmp
git clone https://github.com/Botspot/antigravity-48bit-workaround
sudo cp /tmp/antigravity-48bit-workaround/language-server-wrapper.sh /usr/share/antigravity/resources/antigravity-48bit-workaround/language-server-wrapper.sh
sudo cp /tmp/antigravity-48bit-workaround/guest-wrapper.sh /usr/share/antigravity/resources/antigravity-48bit-workaround/guest-wrapper.sh
sudo cp /tmp/antigravity-48bit-workaround/linux-kernel-image /usr/share/antigravity/resources/antigravity-48bit-workaround/linux-kernel-image
rm -rf /tmp/antigravity-48bit-workaround

#link to where antigravity expects it
sudo ln -sf /usr/share/antigravity/resources/antigravity-48bit-workaround/language-server-wrapper.sh /usr/share/antigravity/resources/app/extensions/antigravity/bin/language_server_linux_arm

```

NOTE: this repo includes a precompiled 48bit ARM64 kernel to run inside the VM. If you need to recompile the kernel for whatever reason, here's the commands I used to make it:
```bash
#!/bin/bash
error() { #red text and exit 1
  echo -e "\e[91m$1\e[0m" 1>&2
  exit 1
}

status() { #cyan text to indicate what is happening
  #detect if a flag was passed, and if so, pass it on to the echo command
  if [[ "$1" == '-'* ]] && [ ! -z "$2" ];then
    echo -e $1 "\e[96m$2\e[0m" 1>&2
  else
    echo -e "\e[96m$1\e[0m" 1>&2
  fi
}

status_green() { #announce the success of a major action
  echo -e "\e[92m$1\e[0m" 1>&2
}

cd /tmp
status "Cloning Linux kernel source..."
rm -rf ./linux-kvm || sudo rm -rf ./linux-kvm
git clone --depth=1 https://github.com/torvalds/linux.git -b v6.6 linux-kvm || error "failed to clone linux kernel source"
cd linux-kvm

#Generate the standard ARM64 config, then strip it down for a KVM guest
make ARCH=arm64 defconfig || error "command failed: make ARCH=arm64 defconfig"
make ARCH=arm64 kvm_guest.config || error "command failed: make ARCH=arm64 kvm_guest.config"

#Inject our custom hardware and virtualization overrides
# Force 48-bit memory (and explicitly disable 39-bit)
./scripts/config -e CONFIG_ARM64_VA_BITS_48 -d CONFIG_ARM64_VA_BITS_39 || error "command failed: ./scripts/config 1"
./scripts/config -e CONFIG_ARM64_4K_PAGES || error "command failed: ./scripts/config 2"
# Enable 9p Filesystem support (required for the -fsdev host root mount)
./scripts/config -e CONFIG_NET_9P -e CONFIG_NET_9P_VIRTIO -e CONFIG_9P_FS -e CONFIG_9P_FS_POSIX_ACL || error "command failed: ./scripts/config 3"
# Enable Virtio PCI and Network drivers (required for QEMU hostfwd networking)
./scripts/config -e CONFIG_VIRTIO_PCI -e CONFIG_VIRTIO_NET || error "command failed: ./scripts/config 4"
# Apply the changes cleanly and fix any broken dependencies
make ARCH=arm64 olddefconfig || error "command failed: make ARCH=arm64 olddefconfig"

# Compile ONLY the raw uncompressed kernel Image (using all available CPU cores)
status "Compiling kernel... This could take over 20 minutes."
nice make ARCH=arm64 -j$(nproc) Image || error "failed to compile custom linux kernel"
status_green Done

status "Moving compiled kernel to permanent storage..."
sudo rm -rf "/usr/share/antigravity/resources/antigravity-48bit-workaround"
sudo mkdir -p "/usr/share/antigravity/resources/antigravity-48bit-workaround"
sudo mv -f arch/arm64/boot/Image "/usr/share/antigravity/resources/antigravity-48bit-workaround/linux-kernel-image" || error "Failed to move linux kernel to /usr/share/antigravity/resources/antigravity-48bit-workaround"

#clean up
rm -rf ./
cd
```
