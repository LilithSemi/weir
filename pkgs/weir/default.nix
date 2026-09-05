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
    hash = "sha256-hjVog5bdAS8oCt7cINjcpkfnTLP5BiVEAzmnA7/UOAc=";
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
