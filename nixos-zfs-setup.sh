#!/usr/bin/env bash
set -ex

DISK=(/dev/sda)
#DISK=(/dev/sda /dev/sdb)

# Do you want swap?
SWAP=0
# How much swap per disk?
SWAPSIZE=2G

# The type of virtual device for boot and root. If kept empty, the disks will
# be joined (two 1T disks will give you ~2TB of data). Other valid options are
# mirror, raidz types and draid types. You will have to manually add other
# devices like spares, intent log devices, cache and so on. Here we're just
# setting this up for installation after all.
#ZFS_BOOT_VDEV="mirror"
#ZFS_ROOT_VDEV="mirror"

# Generate a root password with mkpasswd -m SHA-512
# defaults to 'nixos'
ROOTPW='$6$dJtyokYwIq0JXlg1$sYnhPL5SQW4.V4KXslVbFQkY2TfkQJq2/7Ov48CGgMgV/C8rmdVpPoV9FHsi5PGgo9aViGjyEmWGB9Wt58aUT0'

# Do you want impermanence?
IMPERMANENCE=1

set +x

MAINCFG="/mnt/etc/nixos/configuration.nix"
HWCFG="/mnt/etc/nixos/hardware-configuration.nix"
ZFSCFG="/mnt/etc/nixos/zfs.nix"

if [[ ${#DISK[*]} -eq 1 ]] && [[ -n ${ZFS_BOOT_VDEV} || -n ${ZFS_ROOT_VDEV} ]]
then
	echo "Error: You have only specified one disk. ZFS_BOOT_VDEV and ZFS_ROOT_DEV must be unset or empty." >&2
	false
fi

if [[ -z ${ROOTPW} ]]
then
	echo "Error: Please generate a password hash and put that in this file's ROOTPW variable." >&2
	false
fi

set -x

i=0 SWAPDEVS=()
for d in ${DISK[*]}
do
	sgdisk --zap-all ${d}
	sgdisk -a1 -n1:0:+100K -t1:EF02 -c 1:bootcode${i} ${d}
	sgdisk -n2:1M:+1G -t2:EF00 -c 2:efiboot${i} ${d}
	sgdisk -n3:0:+4G -t3:BE00 -c 3:bpool${i} ${d}
	(( $SWAP )) && sgdisk -n4:0:+${SWAPSIZE} -t4:8200 -c 4:swap${i} ${d} || true
	(( $SWAP )) && SWAPDEVS+=(${d}4) || true
	sgdisk -n5:0:0 -t5:BF00 -c 5:rpool${i} ${d}

	partprobe ${d}
	sleep 2
	(( $SWAP )) && mkswap -L swapfs${i} /dev/disk/by-partlabel/swap${i} || true
	(( $SWAP )) && swapon /dev/disk/by-partlabel/swap${i} || true
	(( i++ )) || true
done
unset i d

# Wait for a bit to let udev catch up and generate /dev/disk/by-partlabel.
sleep 3s

# Create the boot pool
zpool create \
	-o compatibility=grub2 \
	-o ashift=12 \
	-o autotrim=on \
	-O acltype=posixacl \
	-O compression=lz4 \
	-O devices=off \
	-O normalization=formD \
	-O relatime=on \
	-O xattr=sa \
	-O mountpoint=none \
	-O checksum=sha256 \
	-R /mnt \
	bpool ${ZFS_BOOT_VDEV} /dev/disk/by-partlabel/bpool*

# Create the root pool
zpool create \
	-o ashift=12 \
	-o autotrim=on \
	-O acltype=posixacl \
	-O compression=zstd \
	-O dnodesize=auto -O normalization=formD \
	-O relatime=on \
	-O xattr=sa \
	-O mountpoint=none \
	-O checksum=edonr \
	-R /mnt \
	rpool ${ZFS_ROOT_VDEV} /dev/disk/by-partlabel/rpool*

# Create the boot dataset
zfs create bpool

# Create the root dataset
zfs create -o mountpoint=/ rpool/root

# Create datasets (subvolumes) in the root dataset
zfs create rpool/home
(( $IMPERMANENCE )) && zfs create rpool/persist || true
zfs create -o atime=off rpool/nix

# Create datasets (subvolumes) in the boot dataset
# This comes last because boot order matters
zfs create -o mountpoint=/boot bpool/boot

# Make empty snapshots of impermanent volumes
if (( $IMPERMANENCE ))
then
	zfs snapshot rpool/root@blank
fi

# Create, mount and populate the efi partitions
i=0
for d in ${DISK[*]}
do
	mkfs.vfat -n EFI /dev/disk/by-partlabel/efiboot${i}
	mkdir -p /mnt/boot/efis/efiboot${i}
	mount -t vfat /dev/disk/by-partlabel/efiboot${i} /mnt/boot/efis/efiboot${i}
	(( i++ )) || true
done
unset i d

# Mount the first drive's efi partition to /mnt/boot/efi
mkdir /mnt/boot/efi
mount -t vfat /dev/disk/by-partlabel/efiboot0 /mnt/boot/efi

# Make sure we won't trip over zpool.cache later
mkdir -p /mnt/etc/zfs/
rm -f /mnt/etc/zfs/zpool.cache
touch /mnt/etc/zfs/zpool.cache
chmod a-w /mnt/etc/zfs/zpool.cache
chattr +i /mnt/etc/zfs/zpool.cache

# Generate and edit configs
nixos-generate-config --root /mnt

sed -i -e "s|./hardware-configuration.nix|& ./zfs.nix|" ${MAINCFG}

if (( $IMPERMANENCE ))
then
	echo '{ config, lib, pkgs, ... }:'
else
	echo '{ config, pkgs, ... }:'
fi | tee -a ${ZFSCFG}

tee -a ${ZFSCFG} <<EOF

{
  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "$(head -c 8 /etc/machine-id)";
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.zfs.devNodes = "/dev/disk/by-partlabel";
EOF

if (( $IMPERMANENCE ))
then
	tee -a ${ZFSCFG} <<EOF
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r rpool/root@blank
  '';
EOF
fi

# Remove boot.loader stuff, it's to be added to zfs.nix
sed -i '/boot.loader/d' ${MAINCFG}

# Disable xserver. Comment them without a space after the pound sign so we can
# recognize them when we edit the config later
sed -i -e 's;^  \(services.xserver\);  #\1;' ${MAINCFG}

tee -a ${ZFSCFG} <<-'EOF'
  boot.loader.efi.efiSysMountPoint = "/boot/efi";
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.generationsDir.copyKernels = true;
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.loader.grub.enable = true;
  boot.loader.grub.copyKernels = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.zfsSupport = true;

  boot.loader.grub.extraPrepareConfig = ''
    mkdir -p /boot/efis
    for i in  /boot/efis/*; do mount $i ; done

    mkdir -p /boot/efi
    mount /boot/efi
  '';

  boot.loader.grub.extraInstallCommands = ''
    ESP_MIRROR=$(mktemp -d)
    cp -r /boot/efi/EFI $ESP_MIRROR
    for i in /boot/efis/*; do
      cp -r $ESP_MIRROR/EFI $i
    done
    rm -rf $ESP_MIRROR
  '';

  boot.loader.grub.devices = [
EOF

for d in ${DISK[*]}; do
  printf "    \"${d}\"\n" >>${ZFSCFG}
done

tee -a ${ZFSCFG} <<EOF
  ];

EOF

sed -i 's|fsType = "zfs";|fsType = "zfs"; options = [ "zfsutil" "X-mount.mkdir" ];|g' ${HWCFG}

ADDNR=$(awk '/^  fileSystems."\/" =$/ {print NR+3}' ${HWCFG})
sed -i "${ADDNR}i"' \      neededForBoot = true;' ${HWCFG}

ADDNR=$(awk '/^  fileSystems."\/boot" =$/ {print NR+3}' ${HWCFG})
sed -i "${ADDNR}i"' \      neededForBoot = true;' ${HWCFG}

if (( $IMPERMANENCE ))
then
	# Of course we want to persist the config files after the initial
	# reboot. So, create a bind mount from /persist/etc/nixos -> /etc/nixos
	# here, and copy the files and actually mount the bind later
	ADDNR=$(awk '/^  swapDevices =/ {print NR-1}' ${HWCFG})
	TMPFILE=$(mktemp)
	head -n ${ADDNR} ${HWCFG} > ${TMPFILE}

	tee -a ${TMPFILE} <<EOF
  fileSystems."/etc/nixos" =
    { device = "/persist/etc/nixos";
      fsType = "none";
      options = [ "bind" ];
    };

EOF

	ADDNR=$(awk '/^  swapDevices =/ {print NR}' ${HWCFG})
	tail -n +${ADDNR} ${HWCFG} >> ${TMPFILE}
	cat ${TMPFILE} > ${HWCFG}
	rm -f ${TMPFILE}
	unset ADDNR TMPFILE
fi

tee -a ${ZFSCFG} <<EOF
users.users.root.initialHashedPassword = "${ROOTPW}";

}
EOF

if (( $IMPERMANENCE ))
then
	# This is where we copy the config files and mount the bind
	install -d -m 0755 /mnt/persist/etc
	cp -a /mnt/etc/nixos /mnt/persist/etc/
	mount -o bind /mnt/persist/etc/nixos /mnt/etc/nixos
fi

set +x

echo "Now do this (preferably in another shell, this will put out a lot of text):"
echo "nixos-install -v --show-trace --no-root-passwd --root /mnt"
echo "umount -Rl /mnt"
echo "zpool export -a"
echo "swapoff -a"
echo "reboot"
echo "Make note of these instructions because the nixos-install command will output a lot of text."
