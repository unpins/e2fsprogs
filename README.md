# e2fsprogs

[e2fsprogs](https://e2fsprogs.sourceforge.net/) — the ext2/3/4 filesystem programs (`mke2fs`, `e2fsck`, `tune2fs`, `resize2fs`, `debugfs`, `badblocks`, …) as a single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/e2fsprogs/actions/workflows/e2fsprogs.yml/badge.svg)](https://github.com/unpins/e2fsprogs/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install e2fsprogs`.

All three platforms create and check ext2/3/4 filesystems in image files. Linux also operates on block devices (`/dev/sd*`); macOS and Windows have no kernel ext driver, so there it is image-only. Each platform carries the programs nixpkgs installs there, minus the ones that need a mounted ext filesystem (see the table below).

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin e2fsprogs --unpin-program=mkfs.ext4 -F disk.img
unpin e2fsprogs --unpin-program=fsck.ext4 -p disk.img
unpin e2fsprogs --unpin-program=resize2fs disk.img 2G
```

libarchive is built in, so `mke2fs -d <source>` populates the new filesystem from a directory tree or a tar archive, compressed or not.

To install the programs onto your PATH:

```bash
unpin install e2fsprogs
```

`unpin install e2fsprogs` creates the `mke2fs`, `e2fsck`, `tune2fs`, `dumpe2fs`, `resize2fs`, `debugfs`, … commands, plus their `mkfs.ext{2,3,4}` / `fsck.ext{2,3,4}` aliases — 27 on Linux and macOS, 21 on Windows. `unpin info e2fsprogs` lists every command and what it does.

## Programs

| programs | Linux | macOS | Windows |
| :--- | :---: | :---: | :---: |
| `mke2fs` (`mkfs.ext2/3/4`), `e2fsck` (`fsck.ext2/3/4`), `tune2fs` (`e2label`, `findfs`), `dumpe2fs` (`e2mmpstatus`) | ✓ | ✓ | ✓ |
| `resize2fs`, `debugfs`, `badblocks`, `e2image`, `e2undo`, `e2freefrag`, `logsave`, `mklost+found` | ✓ | ✓ | ✓ |
| `chattr`, `lsattr` | ✓ | ✓ | — |
| `fuse2fs`, `filefrag`, `e4crypt`, `e4defrag` | ✓ | — | — |
| `blkid`, `uuidgen`, `uuidd`, `fsck` | — | ✓ | — |

`chattr`/`lsattr` change attributes of files on a mounted filesystem, which
Windows cannot have. `filefrag` reads a file's extents through a Linux ioctl
and only prints an error elsewhere; upstream builds `e4crypt`/`e4defrag` on
Linux only, and `fuse2fs` mounts an image through FUSE. On Linux, `blkid`,
`uuidgen` and `fsck` come from util-linux, so e2fsprogs builds them only on
other systems.

## Build locally

```bash
nix build github:unpins/e2fsprogs
./result/bin/e2fsprogs --unpin-program=mkfs.ext4 -F disk.img
```

Or run directly:

```bash
nix run github:unpins/e2fsprogs -- --unpin-program=mkfs.ext4 -F disk.img
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/e2fsprogs/releases) page has standalone binaries for manual download.

## Build notes

- **Platforms:** Linux, macOS, Windows. macOS and Windows have no kernel ext driver, so the programs work on image files but not live block devices.
- **Windows:** built via [Cosmopolitan](https://github.com/jart/cosmopolitan), not mingw. For `mke2fs -d`, only `.tar`/`.tar.gz` archives work there; bz2/xz/zstd-compressed ones are Linux/macOS-only.
- **`mke2fs -d` reads tar only** (from a directory, or a tar archive with any compression): the cpio, zip and 7z readers are left out so that the encryption layer of the libarchive build shared with `tar` stays out of this binary.
- **Man pages:** embedded in the binary, read with `unpin man e2fsprogs <program>`, e.g. `unpin man e2fsprogs resize2fs`. One page per program the binary actually runs, plus the `mke2fs.conf`/`e2fsck.conf` and `ext2`/`ext3`/`ext4` format pages; upstream's pages for programs this binary does not ship are dropped rather than embedded.
- **Translations:** upstream compiles the build prefix in as `LOCALEDIR`, which would point at a `/nix/store` path that exists on no user's machine. The lookup is repointed at `/usr/share/locale` — upstream's own fallback — so the messages come out translated wherever the distro's e2fsprogs `.mo` files are installed.
- **Tests:** upstream's suite runs during the native Linux and macOS builds (393 tests on Linux x86_64). It does not run for the cross targets or Windows.
- **Not included:** `e2scrub`/`e2scrub_all` (shell scripts) and `e2initrd_helper` (an initrd helper, not a command).
