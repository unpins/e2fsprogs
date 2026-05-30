# e2fsprogs

Standalone build of [e2fsprogs](https://e2fsprogs.sourceforge.net/), shipped as a single multicall binary that dispatches to `mke2fs`, `tune2fs`, `dumpe2fs`, `e2fsck`, and their argv[0] aliases (`mkfs.ext{2,3,4}`, `fsck.ext{2,3,4}`, `e2label`, `e2mmpstatus`, `findfs`).

[![CI](https://github.com/unpins/e2fsprogs/actions/workflows/e2fsprogs.yml/badge.svg)](https://github.com/unpins/e2fsprogs/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

Linux-only: e2fsprogs talks to Linux block-device ioctls and uses kernel ext2/3/4 headers; macOS and Windows are not on the upstream support matrix for the boot-critical tools we package here.

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

- **Linux-only:** the boot-critical tools we ship talk to Linux block-device ioctls and kernel ext2/3/4 headers; macOS and Windows are not on the upstream support matrix.
- **Multicall:** the per-tool upstream is post-linked into one ELF (`mke2fs`, `tune2fs`, `dumpe2fs`, `e2fsck` + their argv[0] aliases). See [`multicall.nix`](multicall.nix) for the link mechanics (source-level `main` → `<tool>_main` rename, libgcc closure on i686, …).
- **Man pages:** embedded in the binary (`.unpin_man`) — real section-8 pages for the canonical tools plus `.so` redirect stubs for the `mkfs.ext*`/`fsck.ext*` aliases, mirroring the argv[0] dispatch. Read with `unpin man e2fsprogs`.
- **Tests:** no native suite runs. Upstream's `make check` first rebuilds the standalone per-tool binaries, but our multicall renamed every tool's `main` to `<tool>_main`, so that relink fails with *undefined reference to `main`* (verified). The real test suite also needs writable block devices CI can't provide.
