{
  lib,
  stdenv,
  mkShell,
  zig,
  qemu,
  flakever,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "weir";
  inherit (flakever) version;

  src = lib.cleanSource ../../.;

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) src pname version;
    hash = "sha256-Xyyhc7R6XDAWfA4WBj9UcKk08V8a5UcauMlpPaQjnL4=";
  };

  nativeBuildInputs = [
    zig
  ];

  postConfigure = ''
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  passthru.shell = mkShell {
    name = "weir-dev-shell";

    packages = [
      zig
      qemu
    ];
  };
})
