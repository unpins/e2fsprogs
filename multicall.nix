# Upstream e2fsprogs is multi-binary — mke2fs/tune2fs/dumpe2fs/e2fsck are
# four separate executables (each plus its own argv[0]-aliased symlinks:
# mkfs.ext2/3/4, e2label, fsck.ext2/3/4...). To honour the unpins one-pkg-
# one-bin rule we post-link them into a single multicall ELF.
#
# Why a post-link route (no source patch): every tool keeps its own
# `int main()` and several share helpers under the same global names but
# with INCOMPATIBLE signatures (misc/util.c and e2fsck/util.c both define
# `dump_mmp_msg` with different arg lists; misc/util.c and e2fsck/util.c
# both define their own `util.o`; recovery.o/revoke.o are compiled by
# both subdirs from the same e2fsck/*.c). Renaming via source-rewriting
# is fragile and high-noise. Instead we use the binutils-level recipe:
#
#   1. Let `make` run upstream normally — all .o files land in misc/* and
#      e2fsck/*, all archives in lib/{support,ext2fs,e2p,et}/.
#   2. For each entry point (mke2fs, tune2fs, dumpe2fs, e2fsck) the
#      mechanism branches by target ABI because llvm-objcopy and GNU ld
#      cover different feature sets:
#        a. `ld -r` collects its .o set into a single partial-link object.
#        b. ELF (Linux): `objcopy --redefine-sym` in a loop renames the
#           tool's `main` → `<tool>_main` and every other defined global
#           `foo` → `<tool>__foo` (privately scoped across the final
#           link). Internal cross-refs are already resolved by step (a),
#           so the rename propagates through relocations as well, and the
#           prefix dissolves the collision set wholesale.
#        c. Mach-O (Darwin): do the visibility surgery at the `ld -r`
#           pass itself via `-exported_symbols_list <main_only>`. ld64
#           demotes every non-listed global to N_PEXT (private extern) in
#           one shot, which is the Mach-O equivalent of file-local. We
#           still run `objcopy --redefine-sym _main=_<tool>_main`
#           afterwards because `_main` is the symbol the dispatcher
#           imports — and the TEXT-symbol rename path of llvm-objcopy
#           does work on Mach-O. We DON'T use `--redefine-sym` to prefix
#           data globals on Darwin: llvm-objcopy's rename on Mach-O
#           updates TEXT symbols (functions) but is a no-op for DATA/BSS
#           symbols, so we'd be left with the same `duplicate symbol
#           _journal_flags` ld64 error. `--localize-symbols` and the
#           `--redefine-syms=<file>` form are also no-ops on Mach-O.
#   3. A small dispatcher.c (basename(argv[0]) → *_main) is compiled
#      separately, then the final link is delegated to upstream's
#      misc/Makefile via an injected `unpin-multicall.mk` fragment.
#      Reason: the lib paths needed for the link ($(LIBBLKID), $(LIBUUID),
#      $(LIBARCHIVE), $(SYSLIBS), $(ALL_LDFLAGS) …) resolve differently per
#      target — Linux passes `--disable-libblkid` so LIBBLKID becomes
#      `-L<util-linux>/lib -lblkid ...`; Darwin keeps libblkid in-tree so
#      LIBBLKID becomes `$(LIB)/libblkid.a $(LIBUUID)`; cc-wrapper's
#      implicit libgcc cascade (needed on linux-i686 for the libgcc
#      __x86.get_pc_thunk.* helpers PIC code uses) only kicks in when the
#      compiler is invoked via the wrapper with the right flag set, which
#      `$(CC) $(ALL_LDFLAGS)` reproduces. Letting make do the variable
#      substitution against mke2fs's own recipe (with e2fsck's
#      `$(LIBSUPPORT)` added) keeps every per-target detail intact.
#   4. We strip all upstream-installed binaries and replace them with one
#      multicall binary at $bin/bin/e2fsprogs plus applet symlinks for the
#      argv[0]-dispatch names. `lib.withAliases` then harvests those
#      symlinks, validates them, embeds the CSV as an UNPIN_META section,
#      and strips them — same shape as coreutils/kmod.
#
# Measured win (x86_64 musl-static, stripped, with full libarchive):
# 4 separate bins ~13 MB total → 1 multicall ~8.3 MB. 13 applet names
# embedded.
{ lib }:
pkgs:
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

  # Applet names dispatched by argv[0]. Mke2fs/tune2fs/e2fsck each do their
  # own argv[0] re-check internally (e.g. tune2fs recognises e2label/
  # e2mmpstatus/findfs), so we route the alias straight to the tool main
  # and the tool decides the variant.
  appletAliases = [
    "mke2fs" "mkfs.ext2" "mkfs.ext3" "mkfs.ext4"
    "tune2fs" "e2label" "e2mmpstatus" "findfs"
    "dumpe2fs"
    "e2fsck" "fsck.ext2" "fsck.ext3" "fsck.ext4"
  ];

  # Dispatcher source. Routes basename(argv[0]) → tool_main. Extra
  # `e2fsprogs <applet> [args]` form so the primary binary is still
  # callable directly without renaming/symlinking.
  dispatcherC = ''
    #include <string.h>
    #include <stdio.h>

    int mke2fs_main(int argc, char *argv[]);
    int tune2fs_main(int argc, char *argv[]);
    int dumpe2fs_main(int argc, char *argv[]);
    int e2fsck_main(int argc, char *argv[]);

    struct applet { const char *name; int (*fn)(int, char **); };

    static const struct applet applets[] = {
        {"mke2fs",    mke2fs_main},
        {"mkfs.ext2", mke2fs_main},
        {"mkfs.ext3", mke2fs_main},
        {"mkfs.ext4", mke2fs_main},
        {"tune2fs",   tune2fs_main},
        {"e2label",   tune2fs_main},
        {"e2mmpstatus", tune2fs_main},
        {"findfs",    tune2fs_main},
        {"dumpe2fs",  dumpe2fs_main},
        {"e2fsck",    e2fsck_main},
        {"fsck.ext2", e2fsck_main},
        {"fsck.ext3", e2fsck_main},
        {"fsck.ext4", e2fsck_main},
        {NULL, NULL}
    };

    int main(int argc, char *argv[])
    {
        char *name = argv[0];
        char *slash = strrchr(name, '/');
        if (slash) name = slash + 1;
        if (strncmp(name, "lt-", 3) == 0) name += 3;

        if (strcmp(name, "e2fsprogs") == 0) {
            if (argc < 2) {
                fprintf(stderr, "e2fsprogs: usage: %s <applet> [args...]\n", argv[0]);
                fprintf(stderr, "applets:");
                for (const struct applet *a = applets; a->name; a++)
                    fprintf(stderr, " %s", a->name);
                fprintf(stderr, "\n");
                return 1;
            }
            name = argv[1];
            argv++;
            argc--;
        }

        for (const struct applet *a = applets; a->name; a++) {
            if (strcmp(name, a->name) == 0)
                return a->fn(argc, argv);
        }
        fprintf(stderr, "e2fsprogs: unknown applet '%s'\n", name);
        return 1;
    }
  '';

  # Darwin's ld64 doesn't accept --start-group/--end-group (errors with
  # "unknown option: --start-group"), and its clang+compiler-rt has no
  # `libgcc.a` for `-lgcc` to resolve. Pick the right link-line prefix/
  # suffix per target. The thunk + late-libc-symbol problem that --start-
  # group + libgcc solves is i686-specific (RIP-relative on x86_64,
  # different/no thunks on the other ISAs) — Mach-O linkers also rescan
  # symbol tables naturally, so neither directive is needed on Darwin.
  isTargetDarwin = pkgs.pkgsStatic.stdenv.hostPlatform.isDarwin;
  multicallGroupOpen = if isTargetDarwin then "" else "-Wl,--start-group";
  multicallGroupClose = if isTargetDarwin then "" else "-Wl,--end-group";
  multicallLibgcc = if isTargetDarwin then "" else "-lgcc";

  # Custom Makefile fragment that reuses upstream's misc/Makefile variables
  # ($(LIBBLKID), $(LIBUUID), $(LIBARCHIVE), $(LIBS), $(SYSLIBS), $(ALL_LDFLAGS)
  # …) to do the final link. Written via pkgs.writeText so neither Nix
  # interpolation nor bash heredoc indentation/escaping mangles the recipe
  # tabs. `top_builddir` is one level up from misc/, matching upstream's
  # misc/Makefile.in.
  # X+Z final link: feed dispatcher.o + every tool's renamed .o files
  # directly into gcc. All .o are bitcode (no per-tool materialization),
  # so lto-plugin runs the full LTO across tools + lib/{support,ext2fs,
  # e2p,et} + musl.
  multicallMk = pkgs.writeText "unpin-multicall.mk" ''
    MULTI_OUT ?= $(top_builddir)/multicall/e2fsprogs

    .PHONY: multicall-link
    multicall-link: $(MULTI_OUT)

    # `--start-group ... $(MULTI_LIBGCC) --end-group` is the key
    # difference vs upstream's per-tool recipes. The bigger combined
    # link drags in additional libc.a members whose PIC-mode references
    # to `__x86.get_pc_thunk.*` (i686 specific) need libgcc inside the
    # group — the cc-driver's implicit `-lgcc -lc -lgcc` tail is scanned
    # once. Darwin (ld64) doesn't accept the group directives and has
    # no libgcc; MULTI_LIBGCC/MULTI_GROUP_* expand to empty there.
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

  multicall = pkgs.pkgsStatic.e2fsprogs.overrideAttrs (old: {
    pname = "e2fsprogs-multi";

    # nixpkgs splits e2fsprogs into 7 outputs (bin/dev/out/man/info/
    # scripts/fuse2fs); collapse to one. The split-output postInstall
    # does `mv $bin/bin/fuse2fs $fuse2fs/bin/fuse2fs` etc. expecting
    # files our X+Z installPhase doesn't produce (we ship only the
    # multicall, no fuse2fs / mk_cmds / e2scrub / …).
    outputs = [ "out" ];
    postInstall = "";

    # Skip `make check`. It depends on `all`, which re-links the standalone
    # per-tool binaries — and phase B renamed their `main` → `<tool>_main`,
    # so that relink fails with "Undefined symbol _main". Same reason the
    # installPhase below skips `make install`. Static-musl builds default to
    # doCheck=false so this only bit the Darwin (native pkgsStatic) target.
    doCheck = false;

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall
      cat > multicall/dispatcher.c <<'DISPATCHER_EOF'
${dispatcherC}
DISPATCHER_EOF

      # X+Z: rebuild every tool with renames at preprocessor time.
      # mke2fs and tune2fs share `misc/util.o` at the same path (one
      # physical file, two tool consumers) — so we use the same
      # two-phase + per-tool-isolation trick as procps-ng:
      #
      #   A. Discovery: NM each tool's .o set (canonical first-pass
      #      output of upstream's buildPhase) and emit
      #      `multicall/<tool>.rename.h` with `#define <sym>
      #      <tool>__<sym>` lines + `#define main <tool>_main`.
      #   B. Per-tool rebuild + isolate: rm the tool's .o files,
      #      re-run `make $objs` with `NIX_CFLAGS_COMPILE` augmented to
      #      `-include` the per-tool rename header; then immediately
      #      copy the freshly-recompiled .o files into
      #      `multicall/<tool>/` so the next iteration's rebuild can
      #      clobber the shared path without losing this tool's bits.
      #
      # Output is bitcode end-to-end — no ld -r, no objcopy
      # --redefine-sym, no -flinker-output=nolto-rel. lto-plugin sees
      # tools + lib/{support,ext2fs,e2p,et} + musl together at final
      # link and inlines/DCEs across all of it. Drops Darwin's special
      # `-exported_symbols_list + N_PEXT` ld64 trick — the preprocessor
      # rename works on both ABIs, with one Mach-O wrinkle (nm's leading
      # `_` and `S`-tagged section data) normalized in phase A below.
      _orig_NIX_CFLAGS_COMPILE=''${NIX_CFLAGS_COMPILE:-}

      # Phase A: discovery (write rename headers from first-pass .o)
      ${lib.concatStringsSep "\n      " (lib.mapAttrsToList
        (tool: objs: ''
          {
            echo "/* multicall rename header: ${tool} */"
            echo "#define main ${tool}_main"
            # Emit `#define <sym> <tool>__<sym>` for every defined global,
            # keyed by the name the C SOURCE uses so the -include rename
            # fires at preprocess time. Two Mach-O portability points:
            #   - ld64 mangles C symbols with a leading `_` (nm prints
            #     `_jbd2_journal_*` for source `jbd2_journal_*`). Strip one
            #     `_` on Darwin or the macro key never matches the source
            #     token, the rename no-ops, and the un-prefixed globals
            #     collide at the final link (72 dup `_jbd2_*` symbols).
            #   - Darwin nm tags section data (rodata/cstring) `S`, which
            #     GNU nm doesn't — include it so data globals get renamed
            #     too, not just `T` functions.
            # Also filter to valid C identifiers: gcc LTO sometimes emits
            # globals with dot-disambiguation suffixes that aren't legal
            # cpp macro names.
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
      # e2fsck/journal.c et al). Running `make misc/journal.o` from the
      # package root fails ("No rule to make target") because the
      # top-level Makefile doesn't know that target — only misc/Makefile
      # does. So group $objs by subdir and recurse via `make -C
      # <subdir> <basename>` for each group.
      : > multicall/all_objs.list
      ${lib.concatStringsSep "\n      " (lib.mapAttrsToList
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

      # Delegate the final link to upstream's misc/Makefile by adding a
      # custom target that reuses the same variables mke2fs uses
      # ($(LIBBLKID), $(LIBUUID), $(LIBARCHIVE), $(LIBS), $(SYSLIBS),
      # $(ALL_LDFLAGS), ...). Why: those vars resolve differently per
      # target — Linux passes `--disable-libblkid` so LIBBLKID becomes
      # `-L<util-linux>/lib -lblkid ...`; Darwin keeps libblkid in-tree
      # so LIBBLKID becomes `$(LIB)/libblkid.a $(LIBUUID)`. Hard-coding
      # `-lblkid -luuid` breaks Darwin; hard-coding the .a paths breaks
      # Linux. Make's variable expansion is the source of truth.
      install -m644 ${multicallMk} misc/unpin-multicall.mk

      make -C misc -f Makefile -f unpin-multicall.mk \
        MULTI_TOOL_OBJS="$(awk 'BEGIN{ORS=" "} { print "$(top_builddir)/" $0 }' multicall/all_objs.list)" \
        MULTI_GROUP_OPEN="${multicallGroupOpen}" \
        MULTI_GROUP_CLOSE="${multicallGroupClose}" \
        MULTI_LIBGCC="${multicallLibgcc}" \
        multicall-link
    '';

    # Skip upstream's `make install`: after X+Z's per-tool recompile
    # (which renamed `main` to `<tool>_main` in every tool's .o files),
    # automake's install rule would relink each tool's standalone binary
    # — those links can't resolve `main` because we renamed it. We don't
    # need the per-tool binaries; only the multicall + applet symlinks.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/e2fsprogs "$out/bin/e2fsprogs"
      for n in ${lib.concatStringsSep " " appletAliases}; do
        ln -s e2fsprogs "$out/bin/$n"
      done
      runHook postInstall
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "e2fsprogs";
    aliasesFromSymlinksIn = "bin";
  }
  multicall
