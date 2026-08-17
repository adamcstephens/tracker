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
      # 0.7.0 lock is broken
      lumis = _old: {
        cargoDeps = rustPlatform.importCargoLock { lockFile = ./nix/lumis_nif-Cargo.lock; };
        postPatch = "cp ${./nix/lumis_nif-Cargo.lock} Cargo.lock";
      };
    };
    overrides =
      _self: prev:
      let
        withAppConfig = drv: drv.override { appConfigPath = ./config; };
      in
      {
        ash = withAppConfig prev.ash;
        ash_json_api = withAppConfig prev.ash_json_api;
        ash_phoenix = withAppConfig prev.ash_phoenix;
        crux = withAppConfig prev.crux;
        ex_brotli = withAppConfig prev.ex_brotli;
        lumis = withAppConfig prev.lumis;
        mdex_native = withAppConfig prev.mdex_native;
        mime = withAppConfig prev.mime;
        spark = withAppConfig prev.spark;
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
