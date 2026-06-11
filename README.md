# e2fsprogs

[e2fsprogs](https://e2fsprogs.sourceforge.net/) — a single self-contained binary providing `mke2fs`, `tune2fs`, `dumpe2fs`, `e2fsck` and their aliases, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/e2fsprogs/actions/workflows/e2fsprogs.yml/badge.svg)](https://github.com/unpins/e2fsprogs/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install e2fsprogs`.

All three platforms create and check ext2/3/4 filesystems in image files. Linux also operates on block devices (`/dev/sd*`); macOS and Windows have no kernel ext driver, so there it is image-only. The Windows build is a [Cosmopolitan](https://github.com/jart/cosmopolitan) `.exe` (see Build notes).

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin e2fsprogs mkfs.ext4 -F disk.img
unpin e2fsprogs fsck.ext4 -p disk.img
unpin e2fsprogs tune2fs -l disk.img
```

libarchive is linked in statically, so `mke2fs -d <source>` populates the new filesystem from a directory tree or a tar/cpio archive.

To install the programs onto your PATH:

```bash
unpin install e2fsprogs
```

`unpin install e2fsprogs` creates the `mke2fs`, `e2fsck`, `tune2fs`, `dumpe2fs`, … commands, plus their `mkfs.ext{2,3,4}` / `fsck.ext{2,3,4}` aliases. `unpin info e2fsprogs` lists every command and what it does.

## Build locally

```bash
nix build github:unpins/e2fsprogs
./result/bin/e2fsprogs mkfs.ext4 -F disk.img
```

Or run directly:

```bash
nix run github:unpins/e2fsprogs -- mkfs.ext4 -F disk.img
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/e2fsprogs/releases) page has standalone binaries for manual download.

## Build notes

- **Platforms:** Linux, macOS, Windows. macOS and Windows have no kernel ext driver, so the tools work on image files but not live block devices.
- **Windows:** built via [Cosmopolitan](https://github.com/jart/cosmopolitan) (`cosmocc` → APE `.exe`), not mingw — see [`cosmo.nix`](cosmo.nix). Uses the non-Linux configure branch (internal libuuid/libblkid, no util-linux dep) plus five libc-portability fixes: O_EXCL neutralized on the image fd (cosmo's NT `open()` EINVALs on `O_RDWR|O_EXCL` for a regular file), `link`/`et_list` symbol rename, `__u64` detection via `<linux/types.h>`, a no-op `sbrk` stub, and a `readdir`-based `scandir` for `mke2fs -d` (cosmo's `scandir` is broken, `readdir` leaves `d_reclen = 0`). libarchive is zlib-only here — `.tar`/`.tar.gz` work; bz2/xz/zstd archives are Linux/macOS-only. With no `/etc/mtab`, tools print a harmless "Can't check if filesystem is mounted" warning.
- **Multicall:** the per-tool upstream is post-linked into one ELF/Mach-O via a source-level `main` → `<tool>_main` rename. See [`multicall.nix`](multicall.nix) for the link mechanics.
- **Man pages:** embedded in the binary (`.unpin_man`), read with `unpin man e2fsprogs` — real section-8 pages plus `.so` redirect stubs for the aliases.
- **Tests:** no native suite runs. Upstream `make check` first relinks the standalone per-tool binaries, which fails because the multicall renamed every `main` to `<tool>_main` (verified); it also needs writable block devices CI can't provide.
