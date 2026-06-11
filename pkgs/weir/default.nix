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

  nativeBuildInputs = [
    zig
  ];

  passthru.shell = mkShell {
    name = "weir-dev-shell";

    packages = [
      zig
      qemu
    ];
  };
})
