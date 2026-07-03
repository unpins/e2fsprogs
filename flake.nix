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
      windowsBuild = import ./cosmo.nix { inherit unpins-lib; };

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
        programs = [
          { name = "mke2fs"; aliases = [ "mkfs.ext2" "mkfs.ext3" "mkfs.ext4" ]; }
          { name = "tune2fs"; aliases = [ "e2label" "e2mmpstatus" "findfs" ]; }
          { name = "dumpe2fs"; }
          { name = "e2fsck"; aliases = [ "fsck.ext2" "fsck.ext3" "fsck.ext4" ]; }
        ];
      };

      # Engine path for Linux AND darwin (mac-on-mac): the four upstream binaries
      # compile to bitcode and the standalone self-folds them into one
      # `e2fsprogs`. multicall.nix's objcopy fold can't run here — nix-lib's
      # universal bitcode libc makes the objects LLVM bitcode, which
      # `llvm-objcopy --redefine-syms` rejects — so it's windows-only now (cosmo.nix
      # still imports its `mkMulticall`).
      #
      # Drop libarchive (nixpkgs builds e2fsprogs `--with-libarchive=direct` for
      # `mke2fs -d <tarball>` — populating an image straight from an archive; a
      # source DIRECTORY still works without it). It pulls libxml2 (libarchive's
      # XAR format support), and that hurts BOTH targets: on Linux libxml2's
      # compiled-in default catalog path (file:///…/libxml2/etc/xml/catalog) is a
      # store reference that keeps libxml2 in the closure; on darwin libarchive +
      # libxml2 reference iconv/iconv_close/iconv_open, which live in a separate
      # libiconv there (not libSystem) and go undefined at the mke2fs link. Both
      # vanish once libarchive is out — the binary stays self-contained (0-ref) and
      # links cleanly on darwin. Re-enable --with-libarchive if the archive-input
      # feature is ever wanted (costs the closure ref + a darwin -liconv fix).
      build = pkgs:
        pkgs.pkgsStatic.e2fsprogs.overrideAttrs (old: {
          configureFlags =
            (builtins.filter
              (f: !(pkgs.lib.hasPrefix "--with-libarchive" f))
              (old.configureFlags or [ ]))
            ++ [ "--without-libarchive" ];
          buildInputs = builtins.filter
            (x: !(pkgs.lib.hasInfix "libarchive" (x.pname or x.name or "")))
            (old.buildInputs or [ ]);
        });
    };
}
