# e2fsprogs

Standalone build of [e2fsprogs](https://e2fsprogs.sourceforge.net/), shipped as a single multicall binary that dispatches to `mke2fs`, `tune2fs`, `dumpe2fs`, `e2fsck`, and their argv[0] aliases (`mkfs.ext{2,3,4}`, `fsck.ext{2,3,4}`, `e2label`, `e2mmpstatus`, `findfs`).

[![CI](https://github.com/unpins/e2fsprogs/actions/workflows/e2fsprogs.yml/badge.svg)](https://github.com/unpins/e2fsprogs/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

Linux and macOS: the tools create and check ext2/3/4 filesystems in regular files (images) on both. On Linux they also operate on block devices (`/dev/sd*`); macOS has no kernel ext driver, so there it is image-only — useful for building and verifying ext images that boot elsewhere. Windows is not built yet (a Cosmopolitan port is feasible but non-trivial — see Build notes).

## Usage

The package ships one executable, `e2fsprogs`. `unpin install` materializes per-applet shims (`mkfs.ext4`, `fsck.ext4`, `tune2fs`, ...) next to the multicall using argv[0] dispatch. To run a command directly without installing, invoke as `e2fsprogs <applet>`:

```bash
e2fsprogs mkfs.ext4 -F disk.img
e2fsprogs fsck.ext4 -p disk.img
e2fsprogs tune2fs -l disk.img
```

Or create symlinks named after the commands you want to use as bare names:

```bash
ln -s "$(command -v e2fsprogs)" ~/bin/mkfs.ext4
mkfs.ext4 -F disk.img
```

Built-in applets: `mke2fs`, `mkfs.ext2`, `mkfs.ext3`, `mkfs.ext4`, `tune2fs`, `e2label`, `e2mmpstatus`, `findfs`, `dumpe2fs`, `e2fsck`, `fsck.ext2`, `fsck.ext3`, `fsck.ext4`.

libarchive is linked in statically so `mke2fs -d <tarball>` (populate the filesystem from a tar/cpio source) works out of the box.

## Installation

Install with [unpin](https://github.com/unpins/unpin):

```bash
unpin e2fsprogs
```

Or run without installing:

```bash
unpin run e2fsprogs
```

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

- **Platforms:** Linux and macOS are built and shipped. macOS lacks a kernel ext driver, so the tools work on image files (`mke2fs -F disk.img`, `fsck`, `dumpe2fs`) but not on live block devices. Windows (Cosmopolitan) is feasible but not yet built — it's a multi-package port: cosmo fragments for `zstd` (static-only, `-DZSTD_DISABLE_ASM`) and `libarchive`, native-build-host overrides so helper-script tools (`zstd`'s `gnugrep`) aren't cross-compiled, internal `--enable-libuuid`/`--enable-libblkid` (the non-Linux configure branch already selects these, dropping the util-linux dep), a handful of cosmo-libc symbol-collision renames in e2fsprogs' generated tables (e.g. `link`), and the multicall recipe re-validated against cosmocc's apelink. libarchive stays, so `mke2fs -d <tarball>` is preserved.
- **Multicall:** the per-tool upstream is post-linked into one ELF/Mach-O (`mke2fs`, `tune2fs`, `dumpe2fs`, `e2fsck` + their argv[0] aliases). See [`multicall.nix`](multicall.nix) for the link mechanics (source-level `main` → `<tool>_main` rename, ELF objcopy `--redefine-sym` vs Mach-O `ld -r -exported_symbols_list`, libgcc closure on i686, …).
- **Man pages:** embedded in the binary (`.unpin_man`) — real section-8 pages for the canonical tools plus `.so` redirect stubs for the `mkfs.ext*`/`fsck.ext*` aliases, mirroring the argv[0] dispatch. Read with `unpin man e2fsprogs`.
- **Tests:** no native suite runs. Upstream's `make check` first rebuilds the standalone per-tool binaries, but our multicall renamed every tool's `main` to `<tool>_main`, so that relink fails with *undefined reference to `main`* (verified). The real test suite also needs writable block devices CI can't provide.
