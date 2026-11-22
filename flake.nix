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
  # engine (bitcode self-fold, see the `build` fn); Windows uses the X+Z
  # rename recipe in ./multicall.nix (cosmo.nix). The applet names are embedded
  # (`unpin/aliases`) so unpin's installer recreates the commands.
  outputs = { self, unpins-lib }:
    let
      # The four filesystem tools every platform gets. Windows (cosmo) and
      # darwin stop here: cosmo.nix's recipe builds exactly these, and the rest
      # of upstream is Linux-only (ioctl-driven attribute/extent tools).
      #
      # The fs-variant names (mkfs.ext*/fsck.ext*) and the tools' internal
      # argv[0]-recheck names (e2label/e2mmpstatus/findfs) are argv[0] aliases of
      # their real program, not separate binaries. `findfs` needs
      # CONFIG_BUILD_FINDFS — see `build`.
      corePrograms = [
        { name = "mke2fs"; aliases = [ "mkfs.ext2" "mkfs.ext3" "mkfs.ext4" ]; }
        { name = "tune2fs"; aliases = [ "e2label" "findfs" ]; }
        { name = "dumpe2fs"; aliases = [ "e2mmpstatus" ]; }
        { name = "e2fsck"; aliases = [ "fsck.ext2" "fsck.ext3" "fsck.ext4" ]; }
      ];
      # The programs upstream builds on every Unix, on top of the four.
      portableImagePrograms = map (n: { name = n; }) [
        "badblocks"
        "debugfs"
        "e2freefrag"
        "e2image"
        "e2undo"
        "logsave"
        "mklost+found"
        "resize2fs"
      ];
      portablePrograms = portableImagePrograms
        ++ map (n: { name = n; }) [ "chattr" "lsattr" ];
      # Linux: what nixpkgs installs. e4crypt/e4defrag are Linux-only in
      # misc/Makefile, filefrag's main only runs on Linux, and fuse2fs is
      # nixpkgs' separate `fuse2fs` output.
      programs = corePrograms ++ portablePrograms
        ++ map (n: { name = n; }) [ "e4crypt" "e4defrag" "filefrag" "fuse2fs" ];
      # macOS: what nixpkgs installs there, minus filefrag (it only prints
      # "only supported on Linux"). Off Linux upstream builds its own libblkid
      # and libuuid, and with them blkid, uuidgen, uuidd and the fsck wrapper.
      darwinPrograms = corePrograms ++ portablePrograms
        ++ map (n: { name = n; }) [ "blkid" "fsck" "uuidd" "uuidgen" ];
      # Every name the dispatcher answers to on a given target, aliases folded
      # in: what the embedded man set has to cover, and nothing more.
      announcedOf = ps: builtins.concatMap (p: [ p.name ] ++ (p.aliases or [ ])) ps;
      # The cosmo fold dispatches the core set, so it reads the SAME list:
      # ./multicall.nix renders applets.list and the dispatcher from the table,
      # `withAliases` announces it, and `multicall.windowsTable` hands it to CI.
      # Windows (cosmo): the tools that work on an image file. chattr/lsattr,
      # filefrag, e4crypt/e4defrag and fuse2fs need a mounted ext filesystem.
      windowsPrograms = corePrograms ++ portableImagePrograms;
      winTable = unpins-lib.lib.multicallTableOf { name = "e2fsprogs"; programs = windowsPrograms; };
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "e2fsprogs";
      # shipped programs (mke2fs/e2fsck/…) are GPL-2.0-or-later; libext2fs/libcom_err
      # (LGPL) and libuuid (BSD) are linked in but don't govern the binary.
      license = "GPL-2.0-or-later";

      # Smoke floor: bare `e2fsprogs` (no applet) prints usage and exits 1,
      # so probe a representative applet through the `--unpin-program=` selector.
      # `mke2fs -V` prints `mke2fs <version> (…)` to stderr and exits 0; the
      # smoke step matches stdout+stderr, and the version-shaped pattern
      # can't pass on the usage banner.
      smoke = [ "--unpin-program=mke2fs" "-V" ];
      smokePattern = "mke2fs [0-9]+[.][0-9]+[.][0-9]+";

      # Windows: routed through Cosmopolitan (`windowsBuild = import
      # ./cosmo.nix …`). mingw cross of e2fsprogs is a non-starter (no
      # block-device / fs-image I/O layer, util-linux libblkid/libuuid deps);
      # cosmocc builds the same source with a small set of libc-portability
      # fixes (O_EXCL on regular files, internal libuuid/libblkid, zlib-only
      # libarchive). Folded by the X+Z recipe in ./multicall.nix.
      windowsBuild = import ./cosmo.nix { inherit unpins-lib winTable; };

      # Build via the unpin-llvm engine + emit a bitcode multicall module: the
      # engine compiles plain pkgsStatic.e2fsprogs (separate binaries upstream)
      # to bitcode and the standalone self-folds them into one `e2fsprogs`.
      # The X+Z fold in ./multicall.nix can't run on bitcode objects, so it is
      # the Windows (cosmo) path only. Pure C — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        inherit programs;
        # darwin: gettext's libintl (langprefs.c) calls CoreFoundation for the
        # user's preferred languages. The mega relinks from bitcode and never
        # sees the -framework the static build got from libintl's link flags,
        # so name it here.
        requires.frameworks = [ "CoreFoundation" ];
        inherit darwinPrograms;
        windowsTable = winTable;
      };

      # Engine path for Linux AND darwin: the upstream binaries compile to
      # bitcode and the standalone self-folds them into one `e2fsprogs`.
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
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
        in
        (pkgs.pkgsStatic.e2fsprogs.override {
          libarchive = unpins-lib.lib.unpinLibarchive pkgs;
        }).overrideAttrs (old: {
          # `findfs` is announced on every target and, on LINUX ONLY, dispatched
          # nowhere: tune2fs.c wraps both do_findfs() and its argv[0] check in
          # `#ifdef CONFIG_BUILD_FINDFS`, which configure defines only when
          # e2fsprogs builds its PRIVATE blkid — and nixpkgs passes
          # `--disable-libblkid` on Linux to use util-linux's. Measured on the
          # published artifact: `e2fsprogs --unpin-program=findfs LABEL=x` fell
          # through to tune2fs' own option parser. The non-Linux branch has no
          # such flag, so darwin and the cosmo .exe were always fine.
          #
          # Define the macro instead of flipping `--disable-libblkid`: the ONLY
          # thing the flag would buy is this macro, and it would swap the
          # maintained util-linux libblkid — already linked, since tune2fs calls
          # blkid_get_devname() outside the ifdef for `-U`/journal lookups — for
          # e2fsprogs' frozen in-tree copy. Same reason `findfs.8` is installed
          # by hand below: `FINDFS_MAN` is gated on the same @BLKID_CMT@.
          #
          # One `env`, both platforms: a trailing `// lib.optionalAttrs isDarwin
          # { env = …; }` REPLACES the attr rather than merging into it, so the
          # darwin -liconv below would have dropped this silently.
          env = (old.env or { })
            // lib.optionalAttrs isLinux {
            NIX_CFLAGS_COMPILE = ((old.env or { }).NIX_CFLAGS_COMPILE or "")
              + " -DCONFIG_BUILD_FINDFS";
          }
            // lib.optionalAttrs isDarwin {
            NIX_LDFLAGS = ((old.env or { }).NIX_LDFLAGS or "") + " -liconv";
          };
          # /etc for mke2fs.conf/e2fsck.conf, /usr/share/locale for the
          # translations, and only the tar reader for `mke2fs -d` (see above);
          # each patch carries its reason.
          patches = (old.patches or [ ]) ++ [
            ./patches/sysconfdir-etc.patch
            ./patches/localedir-usr-share.patch
            ./patches/mke2fs-d-tar-only.patch
          ];
          # `SMANPAGES` takes findfs.8 from `$(FINDFS_MAN)`, empty under
          # `--disable-libblkid` — so the page the macro above makes reachable
          # still isn't installed. The `.8` rule itself is unconditional (a
          # `.8.in` substitution, no link), so build and install just that one.
          # `$man`, not `$out`: upstream's own install already wrote man8 into the
          # split output, and a second `$out/share/man/man8` makes the multiout
          # move fail outright ("Directory not empty") rather than merge.
          postInstall = (old.postInstall or "") + lib.optionalString isLinux ''
            make -C misc findfs.8
            install -Dm644 misc/findfs.8 "''${man:-$out}/share/man/man8/findfs.8"
          '' + ''
            # Upstream installs a page for everything in the tree, this binary
            # folds the programs listed above, and the whole man tree gets
            # embedded -- so `unpin man e2fsprogs debugfs` used to render for
            # tools that were not in there (and, before the fold grew, for most
            # of the package). Keep a page only where there is a program to run,
            # plus the config/format pages those programs read.
            __unpin_keep="mke2fs.conf e2fsck.conf ext2 ext3 ext4 ${
              builtins.concatStringsSep " "
                (announcedOf (if isDarwin then darwinPrograms else programs))
            }"
            find "''${man:-$out}/share/man" \( -type f -o -type l \) -print | while read -r __unpin_f; do
              __unpin_s=''${__unpin_f##*/}
              __unpin_s=''${__unpin_s%.gz}
              __unpin_s=''${__unpin_s%.[0-9]}
              case " $__unpin_keep " in
                *" $__unpin_s "*) ;;
                *) rm -f "$__unpin_f" ;;
              esac
            done
          '';
        });
    };
}
