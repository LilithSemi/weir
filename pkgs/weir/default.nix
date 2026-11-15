{
  lib,
  stdenv,
  mkShell,
  zig_0_17,
  qemu,
  flakever,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "weir";
  inherit (flakever) version;

  src = lib.cleanSource ../../.;

  zigDeps = zig_0_17.fetchDeps {
    inherit (finalAttrs) src pname version;
    hash = "sha256-lS//HnBMruyFPHLm6AsOViLbwhfV42ABIyF1yNZw8ls=";
  };

  nativeBuildInputs = [
    zig_0_17
  ];

  postConfigure = ''
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  zigBuildFlags = [
    "-Dversion=${finalAttrs.version}"
  ];

  passthru.shell = mkShell {
    name = "weir-dev-shell";

    packages = [
      zig_0_17
      qemu
    ];
  };
})
