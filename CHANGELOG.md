# Changelog

## [Unreleased]

### Added

- Thirteen more programs on Linux: `resize2fs`, `debugfs`, `badblocks`,
  `e2image`, `e2undo`, `e2freefrag`, `filefrag`, `logsave`, `mklost+found`,
  `chattr`, `lsattr`, `e4crypt` and `e4defrag`. The v1.47.3-1 release shipped
  four — make, check, tune and dump — so growing or shrinking a filesystem, or
  looking inside one, meant reaching for another copy of e2fsprogs. macOS and
  Windows keep the four: the rest of the set needs Linux.

### Fixed

- On Windows, `mke2fs -d` now reads a `.tar.gz`. It failed on one
  (`Unknown code ____ 226 while populating file system`) because the build had
  no gzip support at all; a plain `.tar` worked and a compressed one did not.
- `unpin install e2fsprogs` now creates the commands. In the v1.47.3-1 release
  it created only `e2fsprogs` itself: the list of program names never made it
  into the published Linux binary, so `mke2fs`, `e2fsck` and the aliases were
  installed nowhere. (The Windows `.exe` of that release did carry its list.)
- `findfs` was offered but did nothing: `findfs LABEL=x` fell through to
  `tune2fs`' own options instead of looking the label up. It resolves labels
  now, and has its manual page.
- `mke2fs` and `e2fsck` read their configuration from `/etc`. The v1.47.3-1
  release looked for `mke2fs.conf` and `e2fsck.conf` inside the machine that
  built it, found nothing there, and quietly fell back to its compiled-in
  defaults — so the filesystem profiles your distribution installs were
  ignored.
- Messages come out in your language where the system has the translations.
  They were being looked for inside the build machine as well; the lookup now
  uses `/usr/share/locale`, which is where every distribution puts them.
- The binary no longer carries any path into the machine that built it.

### Changed

- One manual page per program the binary actually runs, plus the
  `mke2fs.conf`/`e2fsck.conf` and `ext2`/`ext3`/`ext4` format pages. Pages for
  tools this binary does not ship are no longer embedded, so
  `unpin man e2fsprogs <name>` no longer answers for something you cannot run.
- Built by the same compiler as the rest of the catalog, and much smaller for
  it: 8.57 MB down to 3.85 MB on Linux x86_64, with thirteen more programs
  inside. Checked on Linux x86_64 and arm64 against image files — `mkfs.ext4`,
  `e2fsck`, `resize2fs` (grow and shrink), `dumpe2fs`, `debugfs`, `badblocks`,
  `e2image`, `filefrag`, `chattr`/`lsattr`, `logsave`, `e2freefrag` and
  `e4defrag` all do their work.
