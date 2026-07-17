{
  beamPackages,
  callPackages,
  cargo,
  esbuild,
  lib,
  postgresql,
  postgresqlTestHook,
  rustc,
  rustPlatform,
}:
beamPackages.mixRelease rec {
  pname = "tracker-server";
  version = "0.0.1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./assets
      ./lib
      ./config
      ./mix.exs
      ./mix.lock
      ./native
      ./priv
      ./test
    ];
  };

  mixNixDeps = callPackages ./deps.nix {
    inherit beamPackages;
    rustlerPrecompiledOverrides = {
      # overrideAttrs runs after buildRustPackage maps buildFeatures ->
      # cargoBuildFeatures, so the low-level names are what take effect here.
      mdex_native = _old: {
        cargoBuildNoDefaultFeatures = true;
        cargoBuildFeatures = [
          "nif_version_2_15"
          "lumis"
        ];
      };
      lumis = _old: {
        cargoDeps = rustPlatform.importCargoLock { lockFile = ./nix/lumis_nif-Cargo.lock; };
        postPatch = "cp ${./nix/lumis_nif-Cargo.lock} Cargo.lock";
      };
    };
    overrides =
      _self: prev:
      let
        # The workaround installs cargo's lib<crate>.so, but Rustler's
        # force-build load path is priv/native/<crate>.so; add the alias.
        fixNif =
          drv:
          drv.override (old: {
            appConfigPath = ./config;
            preConfigure = (old.preConfigure or "") + ''
              for so in priv/native/lib*.so; do
                [ -e "$so" ] || continue
                ln -sf "$(basename "$so")" "priv/native/$(basename "$so" | sed 's/^lib//')"
              done
            '';
          });
      in
      {
        mdex_native = fixNif prev.mdex_native;
        ex_brotli = fixNif prev.ex_brotli;
        lumis = fixNif prev.lumis;
      };
  };

  nativeBuildInputs = [
    cargo
    rustc
    rustPlatform.cargoSetupHook
  ];
  cargoDeps = rustPlatform.importCargoLock { lockFile = ./native/package_stream/Cargo.lock; };
  cargoRoot = "native/package_stream";

  postBuild = ''
    mix do deps.loadpaths --no-deps-check + assets.deploy --no-deps-check
  '';

  doCheck = true;
  env = {
    PGDATABASE = "tracker_test";
    # prevent mix from trying to download binaries
    ESBUILD_PATH = lib.getExe esbuild;
  };
  nativeCheckInputs = [
    postgresql
    postgresqlTestHook
  ];
  checkPhase = ''
    runHook preCheck

    export MIX_ENV=test
    ln -sv $PWD/_build/prod _build/test

    mix do deps.loadpaths --no-deps-check + ecto.setup + test

    export MIX_ENV=prod

    runHook postCheck
  '';

  passthru = {
    inherit mixNixDeps;
  };

  meta.mainProgram = "tracker";
}
