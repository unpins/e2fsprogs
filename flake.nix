{
  description = "e2fsprogs as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Multi-binary upstream (mke2fs/tune2fs/dumpe2fs/e2fsck + their argv[0]-
  # dispatch siblings like mkfs.ext2/3/4, e2label, fsck.ext2/3/4) is folded
  # into a single multicall binary. Linux + darwin fold via the unpin-llvm
  # engine (bitcode self-fold, see the `build` fn); Windows uses the objcopy
  # recipe in ./multicall.nix (cosmo.nix's `mkMulticall`). The applet names are
  # embedded as an UNPIN_META block so unpin's installer recreates the argv[0]
  # shims.
  outputs = { self, unpins-lib }:
    let
      # The fs-variant names (mkfs.ext*/fsck.ext*) and the tools' internal
      # argv[0]-recheck names (e2label/e2mmpstatus/findfs) are argv[0] aliases of
      # their real program, not separate binaries.
      programs = [
        { name = "mke2fs"; aliases = [ "mkfs.ext2" "mkfs.ext3" "mkfs.ext4" ]; }
        { name = "tune2fs"; aliases = [ "e2label" "e2mmpstatus" "findfs" ]; }
        { name = "dumpe2fs"; }
        { name = "e2fsck"; aliases = [ "fsck.ext2" "fsck.ext3" "fsck.ext4" ]; }
      ];
      # The cosmo fold dispatches exactly that set, so it reads the SAME list:
      # ./multicall.nix renders applets.list and the dispatcher from the table,
      # `withAliases` announces it, and `multicall.windowsTable` hands it to CI.
      winTable = unpins-lib.lib.multicallTableOf { name = "e2fsprogs"; inherit programs; };
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "e2fsprogs";
      # shipped programs (mke2fs/e2fsck/…) are GPL-2.0-or-later; libext2fs/libcom_err
      # (LGPL) and libuuid (BSD) are linked in but don't govern the binary.
      license = "GPL-2.0-or-later";

      # Smoke floor: bare `e2fsprogs` (no applet) prints usage and exits 1,
      # so probe a representative applet through the `--unpin-program=` selector.
      # `mke2fs -V` prints `mke2fs 1.47.3 (…)` to stderr and exits 0; the
      # smoke step matches stdout+stderr, and the version-shaped pattern
      # can't pass on the usage banner.
      smoke = [ "--unpin-program=mke2fs" "-V" ];
      smokePattern = "mke2fs [0-9]+[.][0-9]+[.][0-9]+";

      # Windows: routed through Cosmopolitan (`windowsBuild = import
      # ./cosmo.nix …`). mingw cross of e2fsprogs is a non-starter (no
      # block-device / fs-image I/O layer, util-linux libblkid/libuuid deps);
      # cosmocc builds the same source with a small set of libc-portability
      # fixes (O_EXCL on regular files, internal libuuid/libblkid, zlib-only
      # libarchive). Same X+Z multicall recipe as native — see ./multicall.nix.
      windowsBuild = import ./cosmo.nix { inherit unpins-lib winTable; };

      # Build via the unpin-llvm engine + emit a bitcode multicall module. On
      # Linux the engine compiles plain pkgsStatic.e2fsprogs (mke2fs/tune2fs/
      # dumpe2fs/e2fsck are four separate binaries upstream builds by default)
      # to bitcode and the standalone self-folds them into one `e2fsprogs`
      # binary. The fs-variant names (mkfs.ext*/fsck.ext*) and the tools'
      # internal argv[0]-recheck names (e2label/e2mmpstatus/findfs) are argv[0]
      # aliases of their real program, not separate binaries. The old X+Z fold
      # in ./multicall.nix can't run on the engine's -flto bitcode objects, so
      # it's reserved for the Windows (cosmo) path. Pure C — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        inherit programs;
        windowsTable = winTable;
      };

      # Engine path for Linux AND darwin (mac-on-mac): the four upstream binaries
      # compile to bitcode and the standalone self-folds them into one
      # `e2fsprogs`. multicall.nix's objcopy fold can't run here — nix-lib's
      # universal bitcode libc makes the objects LLVM bitcode, which
      # `llvm-objcopy --redefine-syms` rejects — so it's windows-only now (cosmo.nix
      # still imports its `mkMulticall`).
      #
      # libarchive is kept (nixpkgs builds e2fsprogs `--with-libarchive=direct`
      # for `mke2fs -d <archive>` — populating an image straight from a tarball).
      # It comes from the SHARED lib.unpinLibarchive recipe — the very same
      # derivation `tar` links its bsdtar against — so the catalog mega folds ONE
      # libarchive (an external STOREA depArchive, deduped by path) instead of a
      # separate copy per consumer. That recipe drops xar/libxml2 and bakes the
      # darwin iconv fix (libiconvReal), so libarchive.a references libiconv()
      # rather than the SDK's plain iconv. e2fsprogs links mke2fs with
      # `--with-libarchive=direct` and does NOT pull libarchive's transitive
      # `-liconv`, so on darwin add it to the final link (structuredAttrs →
      # env.NIX_LDFLAGS); darwinIconvFixed supplies the -L for libiconvReal. On
      # Linux/musl iconv lives in libc, so nothing extra there.
      #
      # CRYPTO CONTAINMENT: the shared libarchive is built --with-mbedtls on linux
      # (so `tar` keeps encrypted-ZIP/7z + mtree digests). e2fsprogs must NOT drag
      # that crypto in. create_inode_libarchive.c's direct-link branch points its
      # dispatcher at `archive_read_support_format_all`, which references the
      # zip/7z/mtree handlers → the digest/cryptor layer → mbedtls. Repoint it at
      # `archive_read_support_format_tar`: `mke2fs -d`'s job is "populate from a
      # tarball", and the filter layer (archive_read_support_filter_all, still
      # registered, crypto-free) transparently decompresses .tar.gz/.xz/.zst — so
      # every compressed tarball still works, while e2fsprogs references NO crypto
      # member and mbedtls stays out of its binary even though it links the same
      # crypto-enabled `.a`. (cpio/zip/7z as an mke2fs image source are dropped —
      # nobody populates an ext image from those; the feature is a tarball.)
      build = pkgs:
        let
          lib = pkgs.lib;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        in
        (pkgs.pkgsStatic.e2fsprogs.override {
          libarchive = unpins-lib.lib.unpinLibarchive pkgs;
        }).overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            # mke2fs and e2fsck read $ROOT_SYSCONFDIR/{mke2fs,e2fsck}.conf, and
            # configure substitutes that constant with our own store prefix
            # (lib/dirpaths.h.in) -- the ONLY place the shipped binary looks,
            # and it exists nowhere on a user's machine, so mke2fs silently
            # falls back to its compiled-in defaults instead of the distro's
            # filesystem profiles. /etc is where every distro keeps them.
            # Substituting the TEMPLATE (not the make variable) leaves the
            # install itself in $out: ROOT_SYSCONFDIR is baked at configure
            # time, so a make-time override never reaches the binary.
            substituteInPlace lib/dirpaths.h.in \
              --replace-fail '"@root_sysconfdir@"' '"/etc"'

            substituteInPlace misc/create_inode_libarchive.c \
              --replace-fail \
                'dl_archive_read_support_format_all = archive_read_support_format_all;' \
                'dl_archive_read_support_format_all = archive_read_support_format_tar;'
          '';
        } // lib.optionalAttrs isDarwin {
          env = (old.env or { }) // {
            NIX_LDFLAGS = ((old.env or { }).NIX_LDFLAGS or "") + " -liconv";
          };
        });
    };
}
