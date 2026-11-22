# e2fsprogs via cosmoStaticCross for Windows-x86_64.
#
# mingw is a non-starter for e2fsprogs (no fs-image / block-device I/O
# layer, and it pulls util-linux libblkid/libuuid which don't cross to
# mingw). cosmocc builds the same upstream source — the non-Linux configure
# branch already selects the internal libuuid/libblkid, so the util-linux
# dep is dropped on this target. The cosmo build was proven functional on
# the Windows VM: `mke2fs -F img`, `dumpe2fs`, and `e2fsck -fn` round-trip a
# valid ext2 filesystem (not just `--version`).
#
# Five portability fixes vs. the Linux/macOS build:
#
#  1. **O_EXCL on a regular file** — mke2fs sets EXT2_FLAG_EXCLUSIVE
#     unconditionally, so `unix_open()` ORs O_EXCL into the image-fd open
#     flags. On a regular file (no O_CREAT) O_EXCL is a Linux no-op but
#     cosmocc's NT open() rejects it with EINVAL ("…while setting up
#     superblock"). O_EXCL only has meaning for block devices, which Windows
#     images aren't, so neutralize it in lib/ext2fs/unix_io.c only (NOT
#     globally — O_CREAT|O_EXCL temp-file atomicity is used elsewhere).
#
#  2. **`link` collision** — lib/et/et_c.awk emits `struct et_list link`
#     into every generated `*_err.c`; cosmocc's libc declares POSIX
#     `link()`. Rename the struct var to `et_link`.
#
#  3. **`__u64` type detection** — config/parse-types.sh probes
#     `<asm/types.h>` (cosmocc lacks it) and falls back to
#     `unsigned long long`, clashing with cosmocc's `<linux/types.h>`
#     `__u64` = `unsigned long`. Point the probe at `<linux/types.h>`; then
#     e2fsprogs' `__le/__be` become identical typedefs (GCC14 allows it).
#
#  4. **`sbrk`** — cosmocc has none; only the optional "memory used"
#     diagnostic calls sbrk(0). `-include` a compat header with a no-op stub.
#
#  5. **`scandir`** — cosmo's returns garbage dirents and its readdir()
#     leaves d_reclen at 0, so `mke2fs -d <directory>` gets a readdir-based
#     scandir that copies whole dirents.
#
# Feature trims via .override:
#   - libuuid = null:  use the in-tree libuuid/libblkid (non-Linux branch).
#   - gettext = null + --disable-nls:  gettext-cosmo hits a gnulib
#     getlocalename porting error; Windows ships no translations.
#   - withFuse = false / shared = false:  no fuse2fs, static only.
#   - libarchive → zlib-only:  dropping bz2/xz/zstd/lzo/openssl avoids
#     porting four more libs to cosmocc and the OpenSSL-3 EVP_MAC static-link
#     gap; `mke2fs -d` still reads .tar and .tar.gz (see the LIBARCHIVE
#     note below -- gzip needs -lz on the final link, not just in
#     libarchive's own configure).
{ unpins-lib, winTable }:
pkgs:
let
  cosmoPkgs = unpins-lib.lib.cosmoStaticCross pkgs;
  lib = cosmoPkgs.lib // unpins-lib.lib;
  nat = cosmoPkgs.buildPackages;

  # Minimal libarchive for cosmo: zlib (gzip) only. cosmocc lacks BSD
  # readpassphrase, so prepend a no-op stub (mke2fs never prompts).
  fixedLibarchive = (cosmoPkgs.libarchive.override {
    acl = null;
    attr = null;
    xarSupport = false;
  }).overrideAttrs (o: {
    buildInputs = [ cosmoPkgs.zlib ];
    configureFlags = (o.configureFlags or [ ]) ++ [
      "--without-bz2lib" "--without-lzma" "--without-lzo2"
      "--without-zstd" "--without-openssl" "--without-libb2"
    ];
    patches = (o.patches or [ ]) ++ [ ./patches/cosmo-libarchive-readpassphrase.patch ];
  });

  basePkg = (cosmoPkgs.e2fsprogs.override {
    libuuid = null;
    withFuse = false;
    shared = false;
    gettext = null;
    bash = nat.bash;
    libarchive = fixedLibarchive;
  }).overrideAttrs (oa: {
    doCheck = false;
    configureFlags = (oa.configureFlags or [ ]) ++ [ "--disable-nls" ];

    # libarchive calls into zlib for gzip, and e2fsprogs links it as a bare
    # `-larchive`: `AC_CHECK_LIB(archive, archive_read_new)` resolves without
    # pulling the objects that need crc32/inflate, so the probe passes and the
    # final link is the one that fails. `SYSLIBS` (where a seeded `LIBS` would
    # land) comes BEFORE `LIBARCHIVE` on those link lines, so the only place
    # that works is `LIBARCHIVE` itself. Not a patch: MCONFIG is written by
    # configure, and the guards fail the build if the line it edits is missing.
    buildInputs = (oa.buildInputs or [ ]) ++ [ cosmoPkgs.zlib ];
    postConfigure = (oa.postConfigure or "") + ''
      grep -q '^LIBARCHIVE = .*-larchive' MCONFIG
      sed -i 's|^\(LIBARCHIVE = .*\)$|\1 -lz|' MCONFIG
      grep -q '^LIBARCHIVE = .*-lz' MCONFIG
    '';

    # sysconfdir as on the native build, then the cosmo portability fixes
    # listed at the top; each patch carries its reason.
    patches = (oa.patches or [ ]) ++ map (n: ./patches/${n}.patch) [
      "sysconfdir-etc"
      "cosmo-et-link"
      "cosmo-parse-types"
      "cosmo-unix-io-no-excl"
      "cosmo-compat-sbrk"
      "cosmo-scandir"
    ];

    preBuild = (oa.preBuild or "") + ''
      export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -include $PWD/cosmo-compat.h"
    '';
  });

in
(import ./multicall.nix { inherit lib winTable; }).mkMulticall {
  aliasPkgs = cosmoPkgs;
  hostTools = nat;
  basePkg = basePkg;
  isCosmo = true;
}
