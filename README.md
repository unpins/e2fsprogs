# e2fsprogs

[e2fsprogs](https://e2fsprogs.sourceforge.net/) — the ext2/3/4 filesystem tools (`mke2fs`, `e2fsck`, `tune2fs`, `resize2fs`, `debugfs`, `badblocks`, …) as a single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/e2fsprogs/actions/workflows/e2fsprogs.yml/badge.svg)](https://github.com/unpins/e2fsprogs/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install e2fsprogs`.

All three platforms create and check ext2/3/4 filesystems in image files. Linux also operates on block devices (`/dev/sd*`); macOS and Windows have no kernel ext driver, so there it is image-only. Linux carries the whole tool set; macOS and Windows carry the four image-level tools (see the table below). The Windows build is a [Cosmopolitan](https://github.com/jart/cosmopolitan) `.exe` (see Build notes).

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin e2fsprogs --unpin-program=mkfs.ext4 -F disk.img
unpin e2fsprogs --unpin-program=fsck.ext4 -p disk.img
unpin e2fsprogs --unpin-program=resize2fs disk.img 2G
```

libarchive is linked in statically, so `mke2fs -d <source>` populates the new filesystem from a directory tree or a tar/cpio archive.

To install the programs onto your PATH:

```bash
unpin install e2fsprogs
```

`unpin install e2fsprogs` creates the `mke2fs`, `e2fsck`, `tune2fs`, `dumpe2fs`, `resize2fs`, `debugfs`, … commands, plus their `mkfs.ext{2,3,4}` / `fsck.ext{2,3,4}` aliases — 26 on Linux, 13 on macOS and Windows. `unpin info e2fsprogs` lists every command and what it does.

## Programs

| programs | Linux | macOS | Windows |
| :--- | :---: | :---: | :---: |
| `mke2fs` (`mkfs.ext2/3/4`), `e2fsck` (`fsck.ext2/3/4`), `tune2fs` (`e2label`, `e2mmpstatus`, `findfs`), `dumpe2fs` | ✓ | ✓ | ✓ |
| `resize2fs`, `debugfs`, `badblocks`, `e2image`, `e2undo`, `e2freefrag`, `filefrag`, `logsave`, `mklost+found`, `chattr`, `lsattr`, `e4crypt`, `e4defrag` | ✓ | — | — |

The second row is the part of upstream that needs Linux ioctls or has no
Cosmopolitan/macOS recipe; the four in the first row are the ones that work on
an image file anywhere.

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

- **Platforms:** Linux, macOS, Windows. macOS and Windows have no kernel ext driver, so the tools work on image files but not live block devices.
- **Windows:** built via [Cosmopolitan](https://github.com/jart/cosmopolitan), not mingw — see [`cosmo.nix`](cosmo.nix). Uses the non-Linux configure branch (internal libuuid/libblkid, no util-linux dep) plus five libc-portability fixes: O_EXCL neutralized on the image fd (cosmo's NT `open()` EINVALs on `O_RDWR|O_EXCL` for a regular file), `link`/`et_list` symbol rename, `__u64` detection via `<linux/types.h>`, a no-op `sbrk` stub, and a `readdir`-based `scandir` for `mke2fs -d` (cosmo's `scandir` is broken, `readdir` leaves `d_reclen = 0`). libarchive is zlib-only here — `.tar`/`.tar.gz` work; bz2/xz/zstd archives are Linux/macOS-only. With no `/etc/mtab`, tools print a harmless "Can't check if filesystem is mounted" warning.
- **Multicall:** Linux and macOS fold the per-tool upstream through the unpin-llvm engine, which compiles each tool to bitcode and links them into one binary. Windows keeps the older post-link `main` → `<tool>_main` rename, since cosmocc is not the engine — see [`multicall.nix`](multicall.nix) for those link mechanics.
- **Man pages:** embedded in the binary, read with `unpin man e2fsprogs <program>`, e.g. `unpin man e2fsprogs resize2fs`. One page per program the binary actually runs, plus the `mke2fs.conf`/`e2fsck.conf` and `ext2`/`ext3`/`ext4` format pages; upstream's pages for tools this binary does not ship are dropped rather than embedded.
- **Translations:** upstream compiles the build prefix in as `LOCALEDIR`, which would point at a `/nix/store` path that exists on no user's machine. The lookup is repointed at `/usr/share/locale` — upstream's own fallback — so the messages come out translated wherever the distro's e2fsprogs `.mo` files are installed.
- **Tests:** no native suite runs. Upstream `make check` first relinks the standalone per-tool binaries, which fails because the multicall renamed every `main` to `<tool>_main` (verified); it also needs writable block devices CI can't provide.
