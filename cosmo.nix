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
# Feature trims via .override:
#   - libuuid = null:  use the in-tree libuuid/libblkid (non-Linux branch).
#   - gettext = null + --disable-nls:  gettext-cosmo hits a gnulib
#     getlocalename porting error; Windows ships no translations.
#   - withFuse = false / shared = false:  no fuse2fs, static only.
#   - libarchive → zlib-only:  dropping bz2/xz/zstd/lzo/openssl avoids
#     porting four more libs to cosmocc and the OpenSSL-3 EVP_MAC static-link
#     gap; `mke2fs -d` still reads .tar and .tar.gz.
{ unpins-lib }:
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
    postPatch = (o.postPatch or "") + ''
      awk 'NR==1{print "#ifndef RPP_ECHO_OFF\n#define RPP_ECHO_OFF 0\n#endif\nstatic char *readpassphrase(const char *p, char *b, unsigned long n, int f){ (void)p;(void)f; if(n)b[0]=0; return b; }"} {print}' \
        libarchive_fe/passphrase.c > t && mv t libarchive_fe/passphrase.c
    '';
  });

  # fix 4 compat header, materialized to the source root in postPatch and
  # force-included into every TU via preBuild's NIX_CFLAGS_COMPILE.
  cosmoCompatH = nat.writeText "e2fs-cosmo-compat.h" ''
    #ifndef E2FS_COSMO_COMPAT_H
    #define E2FS_COSMO_COMPAT_H
    #include <stdint.h>
    static inline void *sbrk(intptr_t n){ (void)n; return (void*)0; }
    #endif
  '';

  # fix 5: a working scandir() for `mke2fs -d <directory>` on cosmo. cosmo's
  # system scandir() returns garbage dirents, and its readdir() leaves
  # d_reclen = 0 (the basename in d_name IS correct, though). Upstream's
  # _WIN32 fallback scandir copies d_reclen bytes, so it's equally unusable
  # here. This local version is built on the working readdir() and copies the
  # whole fixed-size `struct dirent` (cosmo's d_name is a 256-byte buffer)
  # instead of trusting d_reclen. Routed into create_inode.c's call site via
  # `#define scandir/alphasort` after <dirent.h> is already included, so the
  # system declarations aren't redefined — only our calls are rerouted. The
  # `.tar`/`.tar.gz` populate path (__populate_fs_from_tar, libarchive) never
  # uses scandir and already works.
  cosmoScandir = nat.writeText "e2fs-cosmo-scandir.inc" ''
    #ifdef __COSMOPOLITAN__
    static int e2fs_alphasort(const struct dirent **a, const struct dirent **b) {
            return strcoll((*a)->d_name, (*b)->d_name);
    }
    static int e2fs_scandir(const char *dir_name, struct dirent ***name_list,
                            int (*filter)(const struct dirent *),
                            int (*compar)(const struct dirent **,
                                          const struct dirent **)) {
            DIR *dir;
            struct dirent *dent, **list = NULL;
            size_t cap = 0, n = 0;
            dir = opendir(dir_name);
            if (!dir) return -1;
            while ((dent = readdir(dir))) {
                    if (filter && !(*filter)(dent)) continue;
                    if (n == cap) {
                            size_t ncap = cap + 32;
                            struct dirent **nl = realloc(list, ncap * sizeof(*nl));
                            if (!nl) goto err;
                            cap = ncap; list = nl;
                    }
                    list[n] = malloc(sizeof(struct dirent));
                    if (!list[n]) goto err;
                    memcpy(list[n], dent, sizeof(struct dirent));
                    n++;
            }
            closedir(dir);
            if (compar) qsort(list, n, sizeof(*list),
                              (int (*)(const void *, const void *))compar);
            *name_list = list;
            return (int)n;
    err:
            closedir(dir);
            while (n) free(list[--n]);
            free(list);
            return -1;
    }
    #define scandir e2fs_scandir
    #define alphasort e2fs_alphasort
    #endif
  '';

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

    postPatch = (oa.postPatch or "") + ''
      # fix 2: et_c.awk `struct et_list link` vs cosmocc POSIX link()
      sed -i \
        -e 's/struct et_list link = /struct et_list et_link = /' \
        -e 's/if (!link\.table)/if (!et_link.table)/' \
        -e 's/et = &link;/et = \&et_link;/' \
        lib/et/et_c.awk

      # fix 3: parse-types.sh probe <asm/types.h> → <linux/types.h>
      sed -i 's|#include <asm/types.h>|#include <linux/types.h>|' config/parse-types.sh

      # fix 1: O_EXCL on a regular file → EINVAL under cosmo's NT open().
      # Neutralize it in this one TU only (O_EXCL is only meaningful for
      # block devices, which Windows images aren't).
      awk '/#include <fcntl.h>/ && !done {print; print "#ifdef __COSMOPOLITAN__"; print "#undef O_EXCL"; print "#define O_EXCL 0"; print "#endif"; done=1; next} {print}' \
        lib/ext2fs/unix_io.c > t && mv t lib/ext2fs/unix_io.c

      # fix 4: no-op sbrk() stub (cosmocc lacks it; only the optional
      # "memory used" diagnostic references sbrk(0)).
      cp ${cosmoCompatH} cosmo-compat.h

      # fix 5: splice the cosmo scandir() before __populate_fs's call site
      # (anchor on its leading comment; uniquely present once).
      awk 'FNR==NR{ins=ins $0 ORS; next}
           /Copy files from source_dir to fs in alphabetical order/ && !done{printf "%s", ins; done=1}
           {print}' \
        ${cosmoScandir} misc/create_inode.c > t && mv t misc/create_inode.c
    '';

    preBuild = (oa.preBuild or "") + ''
      export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -include $PWD/cosmo-compat.h"
    '';
  });

in
(import ./multicall.nix { inherit lib; }).mkMulticall {
  aliasPkgs = cosmoPkgs;
  hostTools = nat;
  basePkg = basePkg;
  isCosmo = true;
}
