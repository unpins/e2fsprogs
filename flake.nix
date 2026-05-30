{
  description = "Standalone build of e2fsprogs";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Multi-binary upstream (mke2fs/tune2fs/dumpe2fs/e2fsck + their argv[0]-
  # dispatch siblings like mkfs.ext2/3/4, e2label, fsck.ext2/3/4) is post-
  # linked into a single multicall ELF/Mach-O via the recipe in
  # ./multicall.nix. `lib.withAliases` then embeds the applet names as an
  # UNPIN_META block so unpin's installer can recreate the argv[0] shims.
  # See ./multicall.nix for the link mechanics (ELF objcopy --redefine-sym
  # vs Mach-O ld -r -exported_symbols_list, libgcc closure on i686, …).
  outputs = { self, unpins-lib }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "e2fsprogs";

      # Smoke floor: bare `e2fsprogs` (no applet) prints usage and exits 1,
      # so probe a representative applet through the argv[1] dispatch.
      # `mke2fs -V` prints `mke2fs 1.47.3 (…)` to stderr and exits 0; the
      # smoke step matches stdout+stderr, and the version-shaped pattern
      # can't pass on the usage banner.
      smoke = [ "mke2fs" "-V" ];
      smokePattern = "mke2fs [0-9]+[.][0-9]+[.][0-9]+";

      build = pkgs:
        import ./multicall.nix {
          lib = pkgs.lib // unpins-lib.lib;
        } pkgs;
    };
}
