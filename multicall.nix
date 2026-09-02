# Upstream e2fsprogs is multi-binary — mke2fs/tune2fs/dumpe2fs/e2fsck are
# four separate executables (each plus its own argv[0]-aliased symlinks:
# mkfs.ext2/3/4, e2label, fsck.ext2/3/4...). To honour the unpins one-pkg-
# one-bin rule we post-link them into a single multicall ELF / Mach-O / APE.
#
# This file exposes a shared `mkMulticall` used by two callers:
#   - flake.nix `build`        → native pkgsStatic (Linux ELF, macOS Mach-O)
#   - cosmo.nix `windowsBuild`  → Cosmopolitan cross (Windows APE via apelink)
# Keeping one recipe avoids the X+Z phase logic drifting between targets.
#
# Why a post-link route (no source patch): every tool keeps its own
# `int main()` and several share helpers under the same global names but
# with INCOMPATIBLE signatures (misc/util.c and e2fsck/util.c both define
# `dump_mmp_msg` with different arg lists; misc/util.c and e2fsck/util.c
# both define their own `util.o`; recovery.o/revoke.o are compiled by
# both subdirs from the same e2fsck/*.c). Renaming via source-rewriting
# is fragile and high-noise. Instead we use the X+Z preprocessor-rename
# recipe:
#
#   A. Discovery: NM each tool's first-pass .o set and emit a per-tool
#      rename header (`#define main <tool>_main` + `#define <sym>
#      <tool>__<sym>` for every other defined global).
#   B. Per-tool rebuild + isolate: rm the tool's .o files, re-run
#      `make <objs>` with NIX_CFLAGS_COMPILE augmented to `-include` the
#      rename header, then copy the freshly-renamed .o into multicall/<tool>/
#      (mke2fs and tune2fs share misc/util.o at one physical path, so each
#      tool's bits must be saved before the next rebuild clobbers it).
#   C. A small dispatcher.c (basename(argv[0]) → *_main) is compiled, then
#      the final link is delegated to upstream's misc/Makefile via an
#      injected `unpin-multicall.mk` fragment that reuses the same per-target
#      variables mke2fs's own recipe uses ($(LIBBLKID), $(LIBUUID),
#      $(LIBARCHIVE), $(SYSLIBS), $(ALL_LDFLAGS) …) — those resolve
#      differently per target (Linux `-L<util-linux> -lblkid`; Darwin/cosmo
#      in-tree `$(LIB)/libblkid.a`), so letting make expand them keeps every
#      per-target detail intact.
#   D. Strip all upstream-installed binaries, ship one multicall at
#      $out/bin/e2fsprogs (+ applet symlinks on ELF/Mach-O). `lib.withAliases`
#      embeds the applet names as an UNPIN_META block; `lib.withMan` (on by
#      default) folds the man pages into the binary.
#
# Measured win (x86_64 musl-static, stripped, with full libarchive):
# 4 separate bins ~13 MB total → 1 multicall ~8.3 MB. 13 applet names
# embedded.
{ lib, winTable }:
let
  multicallObjs = {
    mke2fs = [
      "misc/mke2fs.o"
      "misc/util.o"
      "misc/default_profile.o"
      "misc/mk_hugefiles.o"
      "misc/create_inode.o"
      "misc/create_inode_libarchive.o"
    ];
    tune2fs = [
      "misc/tune2fs.o"
      "misc/util.o"
      "misc/journal.o"
      "misc/recovery.o"
      "misc/revoke.o"
    ];
    dumpe2fs = [
      "misc/dumpe2fs.o"
    ];
    e2fsck = [
      "e2fsck/unix.o" "e2fsck/e2fsck.o" "e2fsck/super.o"
      "e2fsck/pass1.o" "e2fsck/pass1b.o" "e2fsck/pass2.o"
      "e2fsck/pass3.o" "e2fsck/pass4.o" "e2fsck/pass5.o"
      "e2fsck/journal.o" "e2fsck/badblocks.o" "e2fsck/util.o"
      "e2fsck/dirinfo.o" "e2fsck/dx_dirinfo.o" "e2fsck/ehandler.o"
      "e2fsck/problem.o" "e2fsck/message.o" "e2fsck/quota.o"
      "e2fsck/recovery.o" "e2fsck/region.o" "e2fsck/revoke.o"
      "e2fsck/ea_refcount.o" "e2fsck/rehash.o" "e2fsck/logfile.o"
      "e2fsck/sigcatcher.o" "e2fsck/readahead.o" "e2fsck/extents.o"
      "e2fsck/encrypted_files.o"
    ];
  };

  # Every name the binary answers to, from the table the flake declares. The
  # many-to-one rows are the point: mke2fs/tune2fs/e2fsck each re-check argv[0]
  # internally (tune2fs recognises e2label/e2mmpstatus/findfs), so an alias
  # routes straight to its tool's main and the tool decides the variant.
  appletAliases = winTable.announced;

  # Build the multicall from a base e2fsprogs derivation.
  #   aliasPkgs      pkgs passed to lib.withAliases / lib.withMan
  #   hostTools      native pkgs providing build-time writeText
  #                  (native: pkgs; cosmo: cosmoPkgs.buildPackages)
  #   basePkg        the e2fsprogs derivation to post-process
  #   isTargetDarwin Mach-O nm leading-underscore + section-data ('S') handling
  #   isCosmo        Windows APE target: no applet symlinks (no symlinks on
  #                  Windows; the apelink hook renames the binary to .exe), and
  #                  withAliases gets an explicit name list instead.
  mkMulticall =
    { aliasPkgs
    , hostTools
    , basePkg
    , isTargetDarwin ? false
    , isCosmo ? false
    }:
    let
      # Darwin's ld64 doesn't accept --start-group/--end-group and its
      # clang+compiler-rt has no libgcc.a; cosmocc targets x86_64 (no i686
      # thunks) and also ships no libgcc. The --start-group + libgcc trick
      # only matters for i686's `__x86.get_pc_thunk.*` PIC helpers, so blank
      # both the group directives and -lgcc on Darwin and cosmo.
      noGroup = isTargetDarwin || isCosmo;
      multicallGroupOpen = if noGroup then "" else "-Wl,--start-group";
      multicallGroupClose = if noGroup then "" else "-Wl,--end-group";
      multicallLibgcc = if noGroup then "" else "-lgcc";

      # Custom Makefile fragment that reuses upstream's misc/Makefile
      # variables to do the final link. Written via writeText so neither Nix
      # interpolation nor bash heredoc indentation/escaping mangles the recipe
      # tabs. `top_builddir` is one level up from misc/.
      multicallMk = hostTools.writeText "unpin-multicall.mk" ''
        MULTI_OUT ?= $(top_builddir)/multicall/e2fsprogs

        .PHONY: multicall-link
        multicall-link: $(MULTI_OUT)

        $(MULTI_OUT): $(top_builddir)/multicall/dispatcher.o $(MULTI_TOOL_OBJS) $(DEPLIBS) $(LIBE2P) $(DEPLIBBLKID) $(DEPLIBUUID) $(LIBEXT2FS) $(LIBSUPPORT)
        	$(CC) $(ALL_LDFLAGS) -o $@ \
        		$(top_builddir)/multicall/dispatcher.o $(MULTI_TOOL_OBJS) \
        		$(MULTI_GROUP_OPEN) \
        		$(LIBSUPPORT) $(LIBS) $(LIBBLKID) $(LIBUUID) \
        		$(LIBEXT2FS) $(LIBE2P) $(LIBINTL) \
        		$(SYSLIBS) $(LIBMAGIC) $(LIBARCHIVE) \
        		$(MULTI_LIBGCC) \
        		$(MULTI_GROUP_CLOSE)
      '';

      multicall = basePkg.overrideAttrs (old: {
        pname = "e2fsprogs-multi";

        # nixpkgs splits e2fsprogs into 7 outputs (bin/dev/out/man/info/
        # scripts/fuse2fs); collapse to one. The split-output postInstall
        # moves files our X+Z installPhase doesn't produce.
        outputs = [ "out" ];
        postInstall = "";

        # Skip `make check`. It depends on `all`, which re-links the
        # standalone per-tool binaries — and phase B renamed their `main` →
        # `<tool>_main`, so that relink fails with "Undefined symbol _main".
        # Same reason the installPhase below skips `make install`.
        doCheck = false;

        postBuild = (old.postBuild or "") + ''
          # applets.list + dispatcher.c, both rendered from the ONE table the
          # flake declares. e2fsprogs is not itself a program, so the table's
          # naming rule lists on a bare or unknown name.
${winTable.emit { }}

          _orig_NIX_CFLAGS_COMPILE=''${NIX_CFLAGS_COMPILE:-}

          # Phase A: discovery (write rename headers from first-pass .o)
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList
            (tool: objs: ''
              {
                echo "/* multicall rename header: ${tool} */"
                echo "#define main ${tool}_main"
                # Emit `#define <sym> <tool>__<sym>` for every defined global.
                # Two Mach-O portability points (no-ops on ELF/cosmo):
                #   - ld64 mangles C symbols with a leading `_`; strip one on
                #     Darwin so the macro key matches the source token.
                #   - Darwin nm tags section data (rodata/cstring) `S`; include
                #     it so data globals get renamed too, not just `T`.
                $NM --defined-only -g ${lib.concatStringsSep " " objs} 2>/dev/null \
                  | awk -v t="${tool}" -v strip=${if isTargetDarwin then "1" else "0"} '
                      $2 ~ /^[TBDRWVCS]$/ {
                        sym = $3
                        if (strip && sym ~ /^_/) sym = substr(sym, 2)
                        if (sym ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && sym != "main" && !seen[sym]++)
                          print "#define " sym " " t "__" sym
                      }'
              } > multicall/${tool}.rename.h
            '')
            multicallObjs)}

          # Phase B: per-tool rebuild and isolate. e2fsprogs's Makefile is
          # recursive — misc/journal.o, misc/recovery.o, misc/revoke.o have
          # custom cross-dir rules in misc/Makefile (compiled from
          # e2fsck/journal.c et al). Group $objs by subdir and recurse via
          # `make -C <subdir> <basename>` for each group.
          : > multicall/all_objs.list
          ${lib.concatStringsSep "\n          " (lib.mapAttrsToList
            (tool: objs: ''
              rm -f ${lib.concatStringsSep " " objs}
              declare -A _e2fs_subdirs_${tool}=()
              for obj in ${lib.concatStringsSep " " objs}; do
                subdir=$(dirname "$obj")
                base=$(basename "$obj")
                _e2fs_subdirs_${tool}[$subdir]+=" $base"
              done
              for subdir in "''${!_e2fs_subdirs_${tool}[@]}"; do
                NIX_CFLAGS_COMPILE="$_orig_NIX_CFLAGS_COMPILE -include $PWD/multicall/${tool}.rename.h" \
                  make -C "$subdir" -j''${NIX_BUILD_CORES:-1} ''${_e2fs_subdirs_${tool}[$subdir]}
              done
              unset _e2fs_subdirs_${tool}
              mkdir -p multicall/${tool}
              for obj in ${lib.concatStringsSep " " objs}; do
                flat=$(echo "$obj" | tr '/' '_')
                cp "$obj" "multicall/${tool}/$flat"
                echo "multicall/${tool}/$flat" >> multicall/all_objs.list
              done
            '')
            multicallObjs)}

          $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

          # Delegate the final link to upstream's misc/Makefile so its
          # per-target $(LIBBLKID)/$(LIBUUID)/$(LIBARCHIVE)/... expansions are
          # the source of truth (see header).
          install -m644 ${multicallMk} misc/unpin-multicall.mk

          make -C misc -f Makefile -f unpin-multicall.mk \
            MULTI_TOOL_OBJS="$(awk 'BEGIN{ORS=" "} { print "$(top_builddir)/" $0 }' multicall/all_objs.list)" \
            MULTI_GROUP_OPEN="${multicallGroupOpen}" \
            MULTI_GROUP_CLOSE="${multicallGroupClose}" \
            MULTI_LIBGCC="${multicallLibgcc}" \
            multicall-link

          # Generate the section-8 man pages for the applets we ship.
          # Upstream `make install` is skipped, so build just the `<name>.8`
          # targets (the .8.in → .8 substitution, no relink; roff is
          # platform-agnostic).
          make -C misc   mke2fs.8 tune2fs.8 dumpe2fs.8 e2label.8 e2mmpstatus.8 findfs.8
          make -C e2fsck e2fsck.8
        '';

        # Skip upstream's `make install`: after X+Z's per-tool recompile
        # (renamed `main` → `<tool>_main`), automake's install rule would
        # relink each standalone binary and fail to resolve `main`. We only
        # need the multicall + applet symlinks (ELF/Mach-O) / man.
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin"
          install -m755 multicall/e2fsprogs "$out/bin/e2fsprogs"
        '' + lib.optionalString (!isCosmo) ''
          for n in ${lib.concatStringsSep " " appletAliases}; do
            ln -s e2fsprogs "$out/bin/$n"
          done
        '' + ''

          # Install man for the shipped applets so `lib.withMan` (embedMan, on
          # by default) can fold them into the binary. Real pages for the
          # canonical tools; `.so` stubs for the fs-variant aliases
          # (mkfs.ext*/fsck.ext*), resolved inside the embedded archive by
          # mkman's kind-0 .so support and mirroring the argv[0] dispatch.
          # findfs.8 is `SMANPAGES`-gated on @BLKID_CMT@ upstream, but the `.8`
          # rule is not and this build DOES dispatch findfs (the cosmo branch
          # takes the private blkid, so CONFIG_BUILD_FINDFS is on) — it was the
          # one announced name shipping without a page.
          mkdir -p "$out/share/man/man8"
          install -m644 misc/mke2fs.8 misc/tune2fs.8 misc/dumpe2fs.8 \
                        misc/e2label.8 misc/e2mmpstatus.8 misc/findfs.8 \
                        e2fsck/e2fsck.8 \
                        "$out/share/man/man8/"
          for a in mkfs.ext2 mkfs.ext3 mkfs.ext4; do
            printf '.so man8/mke2fs.8\n' > "$out/share/man/man8/$a.8"
          done
          for a in fsck.ext2 fsck.ext3 fsck.ext4; do
            printf '.so man8/e2fsck.8\n' > "$out/share/man/man8/$a.8"
          done

          runHook postInstall
        '';
      });
    in
    lib.withAliases aliasPkgs
      ({
        primary = if isCosmo then "e2fsprogs.exe" else "e2fsprogs";
      } // (if isCosmo
        then { aliases = appletAliases; }
        else { aliasesFromSymlinksIn = "bin"; }))
      multicall;

in
{
  inherit mkMulticall appletAliases multicallObjs;

  # Native (Linux ELF / macOS Mach-O) entry used by flake.nix `build`.
  native = pkgs: mkMulticall {
    aliasPkgs = pkgs;
    hostTools = pkgs;
    basePkg = pkgs.pkgsStatic.e2fsprogs;
    isTargetDarwin = pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin;
  };
}
