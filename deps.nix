{
  lib,
  beamPackages,
  cmake,
  extend,
  lexbor,
  fetchFromGitHub,
  oniguruma,
  overrides ? (x: y: { }),
  overrideFenixOverlay ? null,
  rustlerPrecompiledOverrides ? { },
  stdenv,
  pkg-config,
  sqlite,
  vips,
  writeText,
}:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;

  workarounds = {
    portCompiler = _unusedArgs: old: {
      buildPlugins = [ beamPackages.pc ];
    };

    rustlerPrecompiled =
      {
        toolchain ? null,
        buildInputs ? [ ],
        nativeBuildInputs ? [ ],
        env ? { },
        ...
      }:
      old:
      let
        extendedPkgs = extend fenixOverlay;
        fenixOverlay =
          if overrideFenixOverlay == null then
            import "${
              fetchTarball {
                url = "https://github.com/nix-community/fenix/archive/6399553b7a300c77e7f07342904eb696a5b6bf9d.tar.gz";
                sha256 = "sha256-C6tT7K1Lx6VsYw1BY5S3OavtapUvEnDQtmQB5DSgbCc=";
              }
            }/overlay.nix"
          else
            overrideFenixOverlay;
        nativeDir = "${old.src}/native/${with builtins; head (attrNames (readDir "${old.src}/native"))}";
        fenix =
          if toolchain == null then
            extendedPkgs.fenix.stable
          else
            extendedPkgs.fenix.fromToolchainName toolchain;
        native =
          (
            (extendedPkgs.makeRustPlatform {
              inherit (fenix) cargo rustc;
            }).buildRustPackage
            {
              inherit env buildInputs;
              pname = "${old.beamModuleName}-native";
              version = old.version;
              src = nativeDir;
              cargoLock = {
                lockFile = "${nativeDir}/Cargo.lock";
              };
              nativeBuildInputs = [ extendedPkgs.cmake ] ++ nativeBuildInputs;
              doCheck = false;
            }
          ).overrideAttrs
            rustlerPrecompiledOverrides.${old.beamModuleName} or { };

      in
      {
        nativeBuildInputs = [ extendedPkgs.cargo ];

        env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
        env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "unused-but-required";

        preConfigure = ''
          mkdir -p priv/native
          for lib in ${native}/lib/*
          do
            dest="$(basename "$lib")"
            if [[ "''${dest##*.}" = "dylib" ]]
            then
              dest="''${dest%.dylib}.so"
            fi
            dest="''${dest#lib}"
            ln -s "$lib" "priv/native/$dest"
          done
        '';

        preBuild = ''
          suggestion() {
            echo "***********************************************"
            echo "                 deps_nix                      "
            echo
            echo " Rust dependency build failed.                 "
            echo
            echo " If you saw network errors, you might need     "
            echo " to disable compilation on the appropriate     "
            echo " RustlerPrecompiled module in your             "
            echo " application config.                           "
            echo
            echo " We think you need this:                       "
            echo
            echo -n " "
            grep -Rl 'use RustlerPrecompiled' lib \
              | xargs grep 'defmodule' \
              | sed 's/defmodule \(.*\) do/config :${old.beamModuleName}, \1, skip_compilation?: true/'
            echo "***********************************************"
            exit 1
          }
          trap suggestion ERR
        '';
      };

    elixirMake = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';
    };

    lazyHtml = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';

      postPatch = ''
        substituteInPlace mix.exs \
          --replace-fail "Fine.include_dir()" '"${packages.fine}/src/c_include"' \
          --replace-fail '@lexbor_git_sha "244b84956a6dc7eec293781d051354f351274c46"' '@lexbor_git_sha ""'
      '';

      preBuild = ''
        install -Dm644           -t _build/c/third_party/lexbor/$LEXBOR_GIT_SHA/build           ${lexbor}/lib/liblexbor_static.a
      '';
    };
  };

  defaultOverrides = (
    final: prev:

    let
      apps = {
        crc32cer = [
          {
            name = "portCompiler";
          }
        ];
        explorer = [
          {
            name = "rustlerPrecompiled";
            toolchain = {
              name = "nightly-2025-06-23";
              sha256 = "sha256-UAoZcxg3iWtS+2n8TFNfANFt/GmkuOMDf7QAE0fRxeA=";
            };
          }
        ];
        snappyer = [
          {
            name = "portCompiler";
          }
        ];
      };

      applyOverrides =
        appName: drv:
        let
          allOverridesForApp = builtins.foldl' (
            acc: workaround: acc // (workarounds.${workaround.name} workaround) drv
          ) { } apps.${appName};

        in
        if builtins.hasAttr appName apps then drv.override allOverridesForApp else drv;

    in
    builtins.mapAttrs applyOverrides prev
  );

  self = packages // (defaultOverrides self packages) // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {

      ash =
        let
          version = "3.38.0";
          drv = buildMix {
            inherit version;
            name = "ash";

            src = fetchHex {
              inherit version;
              pkg = "ash";
              sha256 = "10f6b312ca2361d422e6d83eb7f1a4494ebb6f3e987d1be0bc5313ba25aa994a";
            };

            beamDeps = [
              crux
              decimal
              ecto
              ets
              igniter
              jason
              picosat_elixir
              plug
              reactor
              spark
              splode
              stream_data
              telemetry
            ];
          };
        in
        drv;

      ash_admin =
        let
          version = "1.5.0";
          drv = buildMix {
            inherit version;
            name = "ash_admin";

            src = fetchHex {
              inherit version;
              pkg = "ash_admin";
              sha256 = "f031d4a340b9239b31411610c44b8c3903c0a13defaf79d629a0690c70be22d4";
            };

            beamDeps = [
              ash
              ash_phoenix
              cinder
              gettext
              jason
              phoenix
              phoenix_html
              phoenix_live_view
              phoenix_view
            ];
          };
        in
        drv;

      ash_ai =
        let
          version = "1.5.6";
          drv = buildMix {
            inherit version;
            name = "ash_ai";

            src = fetchHex {
              inherit version;
              pkg = "ash_ai";
              sha256 = "3adb246a08a6e988c6eae065cc46fe475a7308ecd9c4684fe816ed22337f02b1";
            };

            beamDeps = [
              ash
              ash_authentication
              ash_json_api
              ash_oban
              ash_phoenix
              ash_postgres
              igniter
              open_api_spex
              plug
              telemetry
            ];
          };
        in
        drv;

      ash_authentication =
        let
          version = "5.0.0-rc.18";
          drv = buildMix {
            inherit version;
            name = "ash_authentication";

            src = fetchHex {
              inherit version;
              pkg = "ash_authentication";
              sha256 = "316122a321bd44cccd051d839d4116f2142a24f0f41c18c5bd8444fef6e1cc3f";
            };

            beamDeps = [
              ash
              ash_postgres
              assent
              bcrypt_elixir
              castore
              finch
              igniter
              jason
              joken
              nimble_totp
              plug
              spark
              splode
              wax_
            ];
          };
        in
        drv;

      ash_authentication_phoenix =
        let
          version = "3.0.0-rc.12";
          drv = buildMix {
            inherit version;
            name = "ash_authentication_phoenix";

            src = fetchHex {
              inherit version;
              pkg = "ash_authentication_phoenix";
              sha256 = "d36295f3561227e56e442cfb449fb383facf87e687f2c3c6726a2a7971f7d990";
            };

            beamDeps = [
              ash
              ash_authentication
              ash_phoenix
              bcrypt_elixir
              gettext
              igniter
              jason
              phoenix
              phoenix_html
              phoenix_html_helpers
              phoenix_live_view
              phoenix_view
              rustler
              slugify
              wax_
            ];
          };
        in
        drv;

      ash_json_api =
        let
          version = "1.8.0";
          drv = buildMix {
            inherit version;
            name = "ash_json_api";

            src = fetchHex {
              inherit version;
              pkg = "ash_json_api";
              sha256 = "d6e6ba8a1ec7212745fff0732abc6044579a95dac84bfa37ea4f935f8db0c400";
            };

            beamDeps = [
              ash
              igniter
              jason
              json_xema
              open_api_spex
              phoenix
              plug
              spark
            ];
          };
        in
        drv;

      ash_oban =
        let
          version = "0.10.3";
          drv = buildMix {
            inherit version;
            name = "ash_oban";

            src = fetchHex {
              inherit version;
              pkg = "ash_oban";
              sha256 = "4d075eb90308b4c4d92c5410eeda02dd6c2f719f0ea6372033251874458d0a89";
            };

            beamDeps = [
              ash
              oban
              postgrex
            ];
          };
        in
        drv;

      ash_phoenix =
        let
          version = "2.3.26";
          drv = buildMix {
            inherit version;
            name = "ash_phoenix";

            src = fetchHex {
              inherit version;
              pkg = "ash_phoenix";
              sha256 = "0f48079ceffdbd22bc45dd6a61007c92e023e355874d7a3bd9b937243a46a279";
            };

            beamDeps = [
              ash
              igniter
              phoenix
              phoenix_html
              phoenix_live_view
              spark
            ];
          };
        in
        drv;

      ash_postgres =
        let
          version = "2.16.0";
          drv = buildMix {
            inherit version;
            name = "ash_postgres";

            src = fetchHex {
              inherit version;
              pkg = "ash_postgres";
              sha256 = "137d702b73c143b6647b845e35e9e1ebdd4f8e71a0a42f33eca22bfd90b29c53";
            };

            beamDeps = [
              ash
              ash_sql
              ecto
              ecto_sql
              igniter
              jason
              postgrex
              spark
            ];
          };
        in
        drv;

      ash_sql =
        let
          version = "0.8.9";
          drv = buildMix {
            inherit version;
            name = "ash_sql";

            src = fetchHex {
              inherit version;
              pkg = "ash_sql";
              sha256 = "894203d0aac2c849ac846a46955c76270e31f7ae8d971ae814673fed220248a1";
            };

            beamDeps = [
              ash
              ecto
              ecto_sql
              jason
            ];
          };
        in
        drv;

      asn1_compiler =
        let
          version = "0.1.1";
          drv = buildMix {
            inherit version;
            name = "asn1_compiler";

            src = fetchHex {
              inherit version;
              pkg = "asn1_compiler";
              sha256 = "c250d24c22f1a3f305d88864400f9ac2df55c6886e1e3a030e2946efeb94695e";
            };
          };
        in
        drv;

      assent =
        let
          version = "0.3.2";
          drv = buildMix {
            inherit version;
            name = "assent";

            src = fetchHex {
              inherit version;
              pkg = "assent";
              sha256 = "e21b10e82a86cb50db47325d40028d5916184cf2a8d01277083e63741720af49";
            };

            beamDeps = [
              certifi
              finch
              jose
              req
              ssl_verify_fun
            ];
          };
        in
        drv;

      atomex =
        let
          version = "0.5.1";
          drv = buildMix {
            inherit version;
            name = "atomex";

            src = fetchHex {
              inherit version;
              pkg = "atomex";
              sha256 = "6248891b5fcab8503982e090eedeeadb757a6311c2ef2e2998b874f7d319ab3f";
            };

            beamDeps = [
              xml_builder
            ];
          };
        in
        drv;

      bandit =
        let
          version = "1.15.0";
          drv = buildMix {
            inherit version;
            name = "bandit";

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "e3b29c4a5107f4bf7dfaa263c50b9b97ddcc132622197c110e2e10a921641c44";
            };

            beamDeps = [
              hpax
              plug
              telemetry
              thousand_island
              websock
            ];
          };
        in
        drv;

      bcrypt_elixir =
        let
          version = "3.3.2";
          drv = buildMix {
            inherit version;
            name = "bcrypt_elixir";

            src = fetchHex {
              inherit version;
              pkg = "bcrypt_elixir";
              sha256 = "471be5151874ae7931911057d1467d908955f93554f7a6cd1b7d804cac8cef53";
            };

            beamDeps = [
              comeonin
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

      castle =
        let
          version = "0.3.1";
          drv = buildMix {
            inherit version;
            name = "castle";

            src = fetchHex {
              inherit version;
              pkg = "castle";
              sha256 = "3ee9ca04b069280ab4197fe753562958729c83b3aa08125255116a989e133835";
            };

            beamDeps = [
              forecastle
            ];
          };
        in
        drv;

      castore =
        let
          version = "1.0.22";
          drv = buildMix {
            inherit version;
            name = "castore";

            src = fetchHex {
              inherit version;
              pkg = "castore";
              sha256 = "c2a4d42723b4affbc1c3e15d8f6df3f7d8f1f627c84de643383634cce58493d5";
            };
          };
        in
        drv;

      cbor =
        let
          version = "1.0.2";
          drv = buildMix {
            inherit version;
            name = "cbor";

            src = fetchHex {
              inherit version;
              pkg = "cbor";
              sha256 = "edbc9b4a16eb93a582437b9b249c340a75af03958e338fb43d8c1be9fc65b864";
            };
          };
        in
        drv;

      cc_precompiler =
        let
          version = "0.1.11";
          drv = buildMix {
            inherit version;
            name = "cc_precompiler";

            src = fetchHex {
              inherit version;
              pkg = "cc_precompiler";
              sha256 = "3427232caf0835f94680e5bcf082408a70b48ad68a5f5c0b02a3bea9f3a075b9";
            };

            beamDeps = [
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

      certifi =
        let
          version = "2.19.0";
          drv = buildRebar3 {
            inherit version;
            name = "certifi";

            src = fetchHex {
              inherit version;
              pkg = "certifi";
              sha256 = "7bac57b76eae5c4b576d4a61a4fd083d186ba7f7918ee2c2b42cb02095e366a8";
            };
          };
        in
        drv;

      cinder =
        let
          version = "0.18.1";
          drv = buildMix {
            inherit version;
            name = "cinder";

            src = fetchHex {
              inherit version;
              pkg = "cinder";
              sha256 = "606c463de625fd1cfb90f46261fbefce47939dacf9cb3dca633670672afc93dc";
            };

            beamDeps = [
              ash
              ash_phoenix
              ash_sql
              gettext
              phoenix_live_view
            ];
          };
        in
        drv;

      comeonin =
        let
          version = "5.5.1";
          drv = buildMix {
            inherit version;
            name = "comeonin";

            src = fetchHex {
              inherit version;
              pkg = "comeonin";
              sha256 = "65aac8f19938145377cee73973f192c5645873dcf550a8a6b18187d17c13ccdb";
            };
          };
        in
        drv;

      conv_case =
        let
          version = "0.2.3";
          drv = buildMix {
            inherit version;
            name = "conv_case";

            src = fetchHex {
              inherit version;
              pkg = "conv_case";
              sha256 = "88f29a3d97d1742f9865f7e394ed3da011abb7c5e8cc104e676fdef6270d4b4a";
            };
          };
        in
        drv;

      cowlib =
        let
          version = "2.22.0";
          drv = buildRebar3 {
            inherit version;
            name = "cowlib";

            src = fetchHex {
              inherit version;
              pkg = "cowlib";
              sha256 = "b1ea5995d8f1ab5086ae7afe710c2075c7872c7e1acaf45dd0db7595e900c0fc";
            };
          };
        in
        drv;

      crux =
        let
          version = "0.1.5";
          drv = buildMix {
            inherit version;
            name = "crux";

            src = fetchHex {
              inherit version;
              pkg = "crux";
              sha256 = "56f4941d362a262a83e5f2ba4fae2173ac2f556a03b5b3965f58b6eb0aedbba3";
            };

            beamDeps = [
              picosat_elixir
              stream_data
            ];
          };
        in
        drv;

      db_connection =
        let
          version = "2.10.2";
          drv = buildMix {
            inherit version;
            name = "db_connection";

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      decimal =
        let
          version = "3.2.0";
          drv = buildMix {
            inherit version;
            name = "decimal";

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "190bca80580ce61aa69bb0eacadd7677710205c770225c2c2c07e32a5c31b234";
            };
          };
        in
        drv;

      ecto =
        let
          version = "3.14.3";
          drv = buildMix {
            inherit version;
            name = "ecto";

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "da2548bd3ced0f56c27d54255389bbbb8f110150ce15cffc95ec0cafa364465c";
            };

            beamDeps = [
              decimal
              jason
              telemetry
            ];
          };
        in
        drv;

      ecto_sql =
        let
          version = "3.14.0";
          drv = buildMix {
            inherit version;
            name = "ecto_sql";

            src = fetchHex {
              inherit version;
              pkg = "ecto_sql";
              sha256 = "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949";
            };

            beamDeps = [
              db_connection
              decimal
              ecto
              postgrex
              telemetry
            ];
          };
        in
        drv;

      elixir_make =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "elixir_make";

            src = fetchHex {
              inherit version;
              pkg = "elixir_make";
              sha256 = "ce1eaa234bc87f0279718e793fd6f8ad35b4e8ee8d412329e3879eee8d40adba";
            };
          };
        in
        drv;

      esbuild =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "esbuild";

            src = fetchHex {
              inherit version;
              pkg = "esbuild";
              sha256 = "890f251330052dcacafa40c409769e7c42e3876fb0ae450707bde831be7b34ea";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      ets =
        let
          version = "0.9.0";
          drv = buildMix {
            inherit version;
            name = "ets";

            src = fetchHex {
              inherit version;
              pkg = "ets";
              sha256 = "2861fdfb04bcaeff370f1a5904eec864f0a56dcfebe5921ea9aadf2a481c822b";
            };
          };
        in
        drv;

      ex_ast =
        let
          version = "0.16.0";
          drv = buildMix {
            inherit version;
            name = "ex_ast";

            src = fetchHex {
              inherit version;
              pkg = "ex_ast";
              sha256 = "700303b0cb693cb36dbac3a2f66a609282b108114fa20179395f36a13a9043b4";
            };

            beamDeps = [
              jason
              sourceror
            ];
          };
        in
        drv;

      ex_brotli =
        let
          version = "0.6.0";
          drv = buildMix {
            inherit version;
            name = "ex_brotli";

            src = fetchHex {
              inherit version;
              pkg = "ex_brotli";
              sha256 = "a45d4099098ba72b33363a6348ece8d9bc46029bfa455dc90326acc8dc77033d";
            };

            beamDeps = [
              phoenix
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      expo =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "expo";

            src = fetchHex {
              inherit version;
              pkg = "expo";
              sha256 = "5fb308b9cb359ae200b7e23d37c76978673aa1b06e2b3075d814ce12c5811640";
            };
          };
        in
        drv;

      finch =
        let
          version = "0.25.0";
          drv = buildMix {
            inherit version;
            name = "finch";

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "9fd9a2c47a9033f4d70fad6e7d656948c08bc6652699de20e609a5917c0bb0a5";
            };

            beamDeps = [
              mime
              mint
              nimble_options
              nimble_pool
              telemetry
            ];
          };
        in
        drv;

      fine =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "fine";

            src = fetchHex {
              inherit version;
              pkg = "fine";
              sha256 = "6f69a9e8dadbfd017b27f611b000362870683ae65f28aec904f36ec4c5058db5";
            };
          };
        in
        drv;

      floki =
        let
          version = "0.38.5";
          drv = buildMix {
            inherit version;
            name = "floki";

            src = fetchHex {
              inherit version;
              pkg = "floki";
              sha256 = "c8c5b04455f01b076cd489fee7dc26b49edf9851ef61146e743f4676114bf6b0";
            };
          };
        in
        drv;

      forecastle =
        let
          version = "0.1.3";
          drv = buildMix {
            inherit version;
            name = "forecastle";

            src = fetchHex {
              inherit version;
              pkg = "forecastle";
              sha256 = "07e1ffa79c56f3e0ead59f17c0163a747dafc210ca8f244a7e65a4bfa98dc96d";
            };
          };
        in
        drv;

      gettext =
        let
          version = "1.0.2";
          drv = buildMix {
            inherit version;
            name = "gettext";

            src = fetchHex {
              inherit version;
              pkg = "gettext";
              sha256 = "eab805501886802071ad290714515c8c4a17196ea76e5afc9d06ca85fb1bfeb3";
            };

            beamDeps = [
              expo
            ];
          };
        in
        drv;

      glob_ex =
        let
          version = "0.1.12";
          drv = buildMix {
            inherit version;
            name = "glob_ex";

            src = fetchHex {
              inherit version;
              pkg = "glob_ex";
              sha256 = "2e2fac83f113514434c7eaf267b4c38af2f91766f1cab2c5db7053b7fc1ee0bb";
            };
          };
        in
        drv;

      gun =
        let
          version = "2.8.0";
          drv = buildRebar3 {
            inherit version;
            name = "gun";

            src = fetchHex {
              inherit version;
              pkg = "gun";
              sha256 = "21a7c716f472fc5bc2c2bbcb2ec74ffa5d20d8073dc712acd054862b0a5176d8";
            };

            beamDeps = [
              cowlib
            ];
          };
        in
        drv;

      hpax =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "hpax";

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "0b8d0f05832f55571d65ac720f79bf8994138ffbb133209dc4685eae0ad456a8";
            };
          };
        in
        drv;

      idna =
        let
          version = "8.0.0";
          drv = buildRebar3 {
            inherit version;
            name = "idna";

            src = fetchHex {
              inherit version;
              pkg = "idna";
              sha256 = "e0c5ce7846f14515af66142a55b8097d5f46d10df9235e781f168bef5622bcf9";
            };
          };
        in
        drv;

      igniter =
        let
          version = "0.8.5";
          drv = buildMix {
            inherit version;
            name = "igniter";

            src = fetchHex {
              inherit version;
              pkg = "igniter";
              sha256 = "3593e74a12fb82dcdc86207c12890505cfd3f0f0e9e0db11446fbcd7cf7a089e";
            };

            beamDeps = [
              ex_ast
              glob_ex
              jason
              owl
              req
              rewrite
              sourceror
              spitfire
            ];
          };
        in
        drv;

      iterex =
        let
          version = "0.1.2";
          drv = buildMix {
            inherit version;
            name = "iterex";

            src = fetchHex {
              inherit version;
              pkg = "iterex";
              sha256 = "2e103b8bcc81757a9af121f6dc0df312c9a17220f302b1193ef720460d03029d";
            };
          };
        in
        drv;

      jason =
        let
          version = "1.4.5";
          drv = buildMix {
            inherit version;
            name = "jason";

            src = fetchHex {
              inherit version;
              pkg = "jason";
              sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
            };

            beamDeps = [
              decimal
            ];
          };
        in
        drv;

      joken =
        let
          version = "2.8.0";
          drv = buildMix {
            inherit version;
            name = "joken";

            src = fetchHex {
              inherit version;
              pkg = "joken";
              sha256 = "a76cc8ae7cca4c8144c1ed335c3d9a229c84e69a20a750a4eba24a1d549a89f6";
            };

            beamDeps = [
              jose
            ];
          };
        in
        drv;

      jose =
        let
          version = "1.11.13";
          drv = buildMix {
            inherit version;
            name = "jose";

            src = fetchHex {
              inherit version;
              pkg = "jose";
              sha256 = "15d8bd0f01ab29d1771e8da1f60f9c98725b23a17f7312cdd40e8e2757bd98c7";
            };
          };
        in
        drv;

      json_xema =
        let
          version = "0.6.5";
          drv = buildMix {
            inherit version;
            name = "json_xema";

            src = fetchHex {
              inherit version;
              pkg = "json_xema";
              sha256 = "b8ffdbc2f67aa8b91b44e1ba0ab77eb5c0b0142116f8fbb804977fb939d470ef";
            };

            beamDeps = [
              conv_case
              xema
            ];
          };
        in
        drv;

      lazy_html =
        let
          version = "0.1.15";
          drv = buildMix {
            inherit version;
            name = "lazy_html";

            buildInputs = [
              lexbor
            ];

            src = fetchHex {
              inherit version;
              pkg = "lazy_html";
              sha256 = "139b5a6ebb6a9181b2da660f7aeb47c12b1af48c79524a57ebf207552301df4a";
            };

            beamDeps = [
              cc_precompiler
              elixir_make
              fine
            ];
          };
        in
        drv.override (workarounds.lazyHtml { } drv);

      lumis =
        let
          version = "0.10.11";
          drv = buildMix {
            inherit version;
            name = "lumis";

            src = fetchHex {
              inherit version;
              pkg = "lumis";
              sha256 = "a114d9f1322e79a0a2d14b4eda7af8ab4cb87b5fed697a89b68279926d5ebc6d";
            };

            beamDeps = [
              nimble_options
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      lumis_wasm_nix =
        let
          version = "0.26.2";
          drv = buildMix {
            inherit version;
            name = "lumis_wasm_nix";

            src = fetchHex {
              inherit version;
              pkg = "lumis_wasm_nix";
              sha256 = "f70e0d04a1582f727c86549984797538bbbe6c4edb82308242e87b8e2e9443b0";
            };
          };
        in
        drv;

      mdex =
        let
          version = "0.14.8";
          drv = buildMix {
            inherit version;
            name = "mdex";

            src = fetchHex {
              inherit version;
              pkg = "mdex";
              sha256 = "7eb7b699603f1a335f3aedb59688612a2b60ca58ecd145c4ddd1908bd662e2d2";
            };

            beamDeps = [
              jason
              mdex_native
              nimble_options
              nimble_parsec
              phoenix_live_view
            ];
          };
        in
        drv;

      mdex_native =
        let
          version = "0.3.3";
          drv = buildMix {
            inherit version;
            name = "mdex_native";

            src = fetchHex {
              inherit version;
              pkg = "mdex_native";
              sha256 = "0472f847d50dca370f2e185ae699b4120bc776e15d85559a793fe36e73c98886";
            };

            beamDeps = [
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      mime =
        let
          version = "2.0.7";
          drv = buildMix {
            inherit version;
            name = "mime";

            src = fetchHex {
              inherit version;
              pkg = "mime";
              sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
            };
          };
        in
        drv;

      mint =
        let
          version = "1.11.0";
          drv = buildMix {
            inherit version;
            name = "mint";

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "c6279ba2d6aa3a383a1d4cfbe7b59f42e6efd400f58d8e2acfeac48a438693ab";
            };

            beamDeps = [
              castore
              hpax
            ];
          };
        in
        drv;

      multigraph =
        let
          version = "0.16.1-mg.5";
          drv = buildMix {
            inherit version;
            name = "multigraph";

            src = fetchHex {
              inherit version;
              pkg = "multigraph";
              sha256 = "d7e3511f1d29e96ed7e7cd01b92bb52eea487b6c61da838f1e61a2ec6838799d";
            };
          };
        in
        drv;

      nimble_options =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "nimble_options";

            src = fetchHex {
              inherit version;
              pkg = "nimble_options";
              sha256 = "3a784a75ef9e407619c8c9e98239b1acd29216deb737044a8c1063e2671ce6d9";
            };
          };
        in
        drv;

      nimble_parsec =
        let
          version = "1.4.2";
          drv = buildMix {
            inherit version;
            name = "nimble_parsec";

            src = fetchHex {
              inherit version;
              pkg = "nimble_parsec";
              sha256 = "4b21398942dda052b403bbe1da991ccd03a053668d147d53fb8c4e0efe09c973";
            };
          };
        in
        drv;

      nimble_pool =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "nimble_pool";

            src = fetchHex {
              inherit version;
              pkg = "nimble_pool";
              sha256 = "bc442e72578c21842589fa8e5886b6175fa5245fdbbad35fc08db277ac2b2c0d";
            };
          };
        in
        drv;

      nimble_totp =
        let
          version = "1.0.0";
          drv = buildMix {
            inherit version;
            name = "nimble_totp";

            src = fetchHex {
              inherit version;
              pkg = "nimble_totp";
              sha256 = "6ce5e4c068feecdb782e85b18237f86f66541523e6bad123e02ee1adbe48eda9";
            };
          };
        in
        drv;

      nostrum =
        let
          version = "0.10.4";
          drv = buildMix {
            inherit version;
            name = "nostrum";

            src = fetchHex {
              inherit version;
              pkg = "nostrum";
              sha256 = "fcc2642bf5b09792865ec2c26c1a11c6aa5432bc623a65dd81141e1eab9f1b99";
            };

            beamDeps = [
              castle
              certifi
              gun
              jason
              mime
            ];
          };
        in
        drv;

      oban =
        let
          version = "2.24.2";
          drv = buildMix {
            inherit version;
            name = "oban";

            src = fetchHex {
              inherit version;
              pkg = "oban";
              sha256 = "605a3b61d554ab416e0cf462b5ea060f7d19ae3dbf1516ec6b5ee30aeb1a5d0b";
            };

            beamDeps = [
              ecto_sql
              igniter
              jason
              postgrex
              telemetry
            ];
          };
        in
        drv;

      oban_met =
        let
          version = "1.3.3";
          drv = buildMix {
            inherit version;
            name = "oban_met";

            src = fetchHex {
              inherit version;
              pkg = "oban_met";
              sha256 = "ebfb81787c920bbd5a7b88b07e078e3eee2e20d5470c5fa67040462c0a78a7cc";
            };

            beamDeps = [
              oban
            ];
          };
        in
        drv;

      oban_web =
        let
          version = "2.13.2";
          drv = buildMix {
            inherit version;
            name = "oban_web";

            src = fetchHex {
              inherit version;
              pkg = "oban_web";
              sha256 = "deb5e4ada588b7ebbd81b67a65a5d5e882b740e57cabe41ae83eec20b7f8c145";
            };

            beamDeps = [
              jason
              oban
              oban_met
              phoenix
              phoenix_html
              phoenix_live_view
              phoenix_pubsub
            ];
          };
        in
        drv;

      octo_fetch =
        let
          version = "0.5.0";
          drv = buildMix {
            inherit version;
            name = "octo_fetch";

            src = fetchHex {
              inherit version;
              pkg = "octo_fetch";
              sha256 = "6226cc3c14ca948ee9f25fb0446322e5c288e215da9beba7899b6b5f4cd3ccb0";
            };

            beamDeps = [
              castore
              ssl_verify_fun
            ];
          };
        in
        drv;

      open_api_spex =
        let
          version = "3.22.4";
          drv = buildMix {
            inherit version;
            name = "open_api_spex";

            src = fetchHex {
              inherit version;
              pkg = "open_api_spex";
              sha256 = "f658d73396e2277e584085a6146481eb085d815a716089defe4f94b26cf8b05f";
            };

            beamDeps = [
              decimal
              jason
              plug
              ymlr
            ];
          };
        in
        drv;

      owl =
        let
          version = "0.13.1";
          drv = buildMix {
            inherit version;
            name = "owl";

            src = fetchHex {
              inherit version;
              pkg = "owl";
              sha256 = "351e768af8f2edc575cdaab1a5a2f6d6381be591758a026c701c703145508a0c";
            };
          };
        in
        drv;

      peep =
        let
          version = "4.4.0";
          drv = buildMix {
            inherit version;
            name = "peep";

            src = fetchHex {
              inherit version;
              pkg = "peep";
              sha256 = "f289959a9e5fcf92f5a4becaf4dd0df95c58841368f6ad0574b8ea830a7c1453";
            };

            beamDeps = [
              nimble_options
              plug
              telemetry
              telemetry_metrics
            ];
          };
        in
        drv;

      phoenix =
        let
          version = "1.8.17";
          drv = buildMix {
            inherit version;
            name = "phoenix";

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "21fd4d6a33c6af4e86b95156a49815a59140c2ba4ef8cf19565dbb7be881633e";
            };

            beamDeps = [
              bandit
              jason
              phoenix_pubsub
              phoenix_template
              phoenix_view
              plug
              plug_crypto
              telemetry
              websock_adapter
            ];
          };
        in
        drv;

      phoenix_ecto =
        let
          version = "4.7.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_ecto";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_ecto";
              sha256 = "1d75011e4254cb4ddf823e81823a9629559a1be93b4321a6a5f11a5306fbf4cc";
            };

            beamDeps = [
              ecto
              phoenix_html
              plug
              postgrex
            ];
          };
        in
        drv;

      phoenix_html =
        let
          version = "4.4.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_html";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html";
              sha256 = "94832038da7ab8f86d4c0d36f7797a269fd06fe611f25c69f55108c075505228";
            };
          };
        in
        drv;

      phoenix_html_helpers =
        let
          version = "1.0.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_html_helpers";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html_helpers";
              sha256 = "cffd2385d1fa4f78b04432df69ab8da63dc5cf63e07b713a4dcf36a3740e3090";
            };

            beamDeps = [
              phoenix_html
              plug
            ];
          };
        in
        drv;

      phoenix_live_dashboard =
        let
          version = "0.9.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_dashboard";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_dashboard";
              sha256 = "de25e1a28cfb64413d8bdaf3ba5b64da1a19e0ed44a02320119523cc45da051d";
            };

            beamDeps = [
              ecto
              mime
              phoenix_live_view
              telemetry_metrics
            ];
          };
        in
        drv;

      phoenix_live_view =
        let
          version = "1.2.15";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "06de7d327a964c81e93a4d64f67088852bf3512f30c04af563101feaac1deaf1";
            };

            beamDeps = [
              igniter
              jason
              lazy_html
              phoenix
              phoenix_html
              phoenix_template
              phoenix_view
              plug
              telemetry
            ];
          };
        in
        drv;

      phoenix_pubsub =
        let
          version = "2.4.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "352fba7a87bf61395b6e97da66944ad9b1bfe5459e5981039f60d68270bd9700";
            };
          };
        in
        drv;

      phoenix_template =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_template";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_template";
              sha256 = "eba70070de79b2c3501ef205a74a69f98ab352f3785aa15da9ed161f9fe0fd5d";
            };

            beamDeps = [
              phoenix_html
            ];
          };
        in
        drv;

      phoenix_test =
        let
          version = "0.14.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_test";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_test";
              sha256 = "0d090b0b6deb4193797f7bee8f19ecabdc4bb4000db51ccd140dded0b2d57be3";
            };

            beamDeps = [
              jason
              lazy_html
              mime
              phoenix
              phoenix_html
              phoenix_live_view
            ];
          };
        in
        drv;

      phoenix_test_playwright =
        let
          version = "0.19.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_test_playwright";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_test_playwright";
              sha256 = "0979bba45e54e8042bc0c13be9ae55d0b958c16603567adfea34f050e563b163";
            };

            beamDeps = [
              ecto_sql
              nimble_options
              phoenix
              phoenix_ecto
              phoenix_live_view
              phoenix_test
              playwright_ex
            ];
          };
        in
        drv;

      phoenix_view =
        let
          version = "2.0.4";
          drv = buildMix {
            inherit version;
            name = "phoenix_view";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_view";
              sha256 = "4e992022ce14f31fe57335db27a28154afcc94e9983266835bb3040243eb620b";
            };

            beamDeps = [
              phoenix_html
              phoenix_template
            ];
          };
        in
        drv;

      picosat_elixir =
        let
          version = "0.2.3";
          drv = buildMix {
            inherit version;
            name = "picosat_elixir";

            src = fetchHex {
              inherit version;
              pkg = "picosat_elixir";
              sha256 = "f76c9db2dec9d2561ffaa9be35f65403d53e984e8cd99c832383b7ab78c16c66";
            };

            beamDeps = [
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

      playwright_ex =
        let
          version = "0.16.0";
          drv = buildMix {
            inherit version;
            name = "playwright_ex";

            src = fetchHex {
              inherit version;
              pkg = "playwright_ex";
              sha256 = "8ef7f618e0c282dd68b5aba1bcbb73be48aef3b835e82828a21586050318a95f";
            };

            beamDeps = [
              mime
              nimble_options
            ];
          };
        in
        drv;

      plug =
        let
          version = "1.20.4";
          drv = buildMix {
            inherit version;
            name = "plug";

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "96ee42c0b8b35bcb14e3e65afb85abe9bb7745a8576e8c602802bbb01e5acf72";
            };

            beamDeps = [
              mime
              plug_crypto
              telemetry
            ];
          };
        in
        drv;

      plug_crypto =
        let
          version = "2.2.1";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "4417ccbd8f85e627321cd07d2ab9c4b621f1fd883b9905af241f9b4b780b94b6";
            };
          };
        in
        drv;

      postgrex =
        let
          version = "0.23.0";
          drv = buildMix {
            inherit version;
            name = "postgrex";

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "f001ab3fd56f5ef2b8b3cd4a512005614fcaeccca068ddb29e57d338a7f104ec";
            };

            beamDeps = [
              db_connection
              decimal
              jason
            ];
          };
        in
        drv;

      prom_ex =
        let
          version = "1.12.0";
          drv = buildMix {
            inherit version;
            name = "prom_ex";

            src = fetchHex {
              inherit version;
              pkg = "prom_ex";
              sha256 = "6357484941489ba2fee64bb1e9f2a1e86309545304f9e90144e3c10e553c958b";
            };

            beamDeps = [
              ecto
              finch
              jason
              oban
              octo_fetch
              peep
              phoenix
              phoenix_live_view
              plug
              telemetry
              telemetry_metrics
              telemetry_metrics_prometheus_core
              telemetry_poller
            ];
          };
        in
        drv;

      reactor =
        let
          version = "1.0.8";
          drv = buildMix {
            inherit version;
            name = "reactor";

            src = fetchHex {
              inherit version;
              pkg = "reactor";
              sha256 = "035dd63a02f10ed84997179b0514c5f0a8f13a9c62c2ed31a684a27fcdfcd72c";
            };

            beamDeps = [
              igniter
              iterex
              jason
              multigraph
              spark
              splode
              telemetry
              yaml_elixir
              ymlr
            ];
          };
        in
        drv;

      req =
        let
          version = "0.7.5";
          drv = buildMix {
            inherit version;
            name = "req";

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "576853c4bf403faa3c1fa5d093e0759227083b78f8a6864c67d62c0a9c45514d";
            };

            beamDeps = [
              finch
              jason
              mime
              plug
            ];
          };
        in
        drv;

      req_s3 =
        let
          version = "0.2.5";
          drv = buildMix {
            inherit version;
            name = "req_s3";

            src = fetchHex {
              inherit version;
              pkg = "req_s3";
              sha256 = "f675afe738b7d323a0a6d94e984cb8a7d1acc2f26fb6160d001eeaed4873ed44";
            };

            beamDeps = [
              req
            ];
          };
        in
        drv;

      rewrite =
        let
          version = "1.3.1";
          drv = buildMix {
            inherit version;
            name = "rewrite";

            src = fetchHex {
              inherit version;
              pkg = "rewrite";
              sha256 = "20b33e1161bcba0a30d842d983c08bfbb6baad83238399067364a5d2c5a206ae";
            };

            beamDeps = [
              glob_ex
              sourceror
              text_diff
            ];
          };
        in
        drv;

      rustler =
        let
          version = "0.38.0";
          drv = buildMix {
            inherit version;
            name = "rustler";

            src = fetchHex {
              inherit version;
              pkg = "rustler";
              sha256 = "704c03c1bf66be12b031c5a389347b91c81c5cb819a24b068b0de36fe4a5652a";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      rustler_precompiled =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "rustler_precompiled";

            src = fetchHex {
              inherit version;
              pkg = "rustler_precompiled";
              sha256 = "0efa66bc2a4206aec64a2c422ca0b1d69bdc411c7b359ec928feb889357b4abb";
            };

            beamDeps = [
              rustler
            ];
          };
        in
        drv;

      slugify =
        let
          version = "1.3.1";
          drv = buildMix {
            inherit version;
            name = "slugify";

            src = fetchHex {
              inherit version;
              pkg = "slugify";
              sha256 = "cb090bbeb056b312da3125e681d98933a360a70d327820e4b7f91645c4d8be76";
            };
          };
        in
        drv;

      sourceror =
        let
          version = "1.13.0";
          drv = buildMix {
            inherit version;
            name = "sourceror";

            src = fetchHex {
              inherit version;
              pkg = "sourceror";
              sha256 = "d72dd66dd2b82cc8e818b54ba0ab2ef0314c83ffcf231b1ad2ade00fa2ee3375";
            };
          };
        in
        drv;

      spark =
        let
          version = "2.7.10";
          drv = buildMix {
            inherit version;
            name = "spark";

            src = fetchHex {
              inherit version;
              pkg = "spark";
              sha256 = "fb2bde1cc85f06eb1a293bb7b3d5fc91df653d62945333ac71cbcb68a788e202";
            };

            beamDeps = [
              igniter
              jason
              sourceror
            ];
          };
        in
        drv;

      spitfire =
        let
          version = "0.4.3";
          drv = buildMix {
            inherit version;
            name = "spitfire";

            src = fetchHex {
              inherit version;
              pkg = "spitfire";
              sha256 = "4f771bbdf00fe6eda6e2a7e488c42ead48142fea697349510a41fabb41376632";
            };
          };
        in
        drv;

      splode =
        let
          version = "0.3.3";
          drv = buildMix {
            inherit version;
            name = "splode";

            src = fetchHex {
              inherit version;
              pkg = "splode";
              sha256 = "3f98c7799ec8960f816b4ccc5cc6a5d2b72a20ad3f8fff9199fb530194ad9f50";
            };
          };
        in
        drv;

      ssl_verify_fun =
        let
          version = "1.1.9";
          drv = buildMix {
            inherit version;
            name = "ssl_verify_fun";

            src = fetchHex {
              inherit version;
              pkg = "ssl_verify_fun";
              sha256 = "19f24ad715ef6255d530b2f0db8b2d2191ae435b6527234e943f523e84ed0895";
            };
          };
        in
        drv;

      stream_data =
        let
          version = "1.4.0";
          drv = buildMix {
            inherit version;
            name = "stream_data";

            src = fetchHex {
              inherit version;
              pkg = "stream_data";
              sha256 = "2b0ee3a340dcce1c8cf6302a763ee757d1e01c54d6e16d9069062509d68b1dc9";
            };
          };
        in
        drv;

      swoosh =
        let
          version = "1.30.0";
          drv = buildMix {
            inherit version;
            name = "swoosh";

            src = fetchHex {
              inherit version;
              pkg = "swoosh";
              sha256 = "d1b553f5264ae39fb299e0da12e01e33aaba49c2509757065ca3aef06e659b0c";
            };

            beamDeps = [
              bandit
              finch
              idna
              jason
              mime
              plug
              req
              telemetry
            ];
          };
        in
        drv;

      telemetry =
        let
          version = "1.4.3";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "17a63581cf2e832a238287f5fe6811e8ca1f333249f1376ad653164a3c4770d4";
            };
          };
        in
        drv;

      telemetry_metrics =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "telemetry_metrics";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_metrics";
              sha256 = "71dde12fc29b58b9c77ec17ec319109e5ca848d010fc1965ed4463bba1837c07";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      telemetry_metrics_prometheus_core =
        let
          version = "1.2.1";
          drv = buildMix {
            inherit version;
            name = "telemetry_metrics_prometheus_core";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_metrics_prometheus_core";
              sha256 = "5e2c599da4983c4f88a33e9571f1458bf98b0cf6ba930f1dc3a6e8cf45d5afb6";
            };

            beamDeps = [
              telemetry
              telemetry_metrics
            ];
          };
        in
        drv;

      telemetry_poller =
        let
          version = "1.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry_poller";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_poller";
              sha256 = "51f18bed7128544a50f75897db9974436ea9bfba560420b646af27a9a9b35211";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      text_diff =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "text_diff";

            src = fetchHex {
              inherit version;
              pkg = "text_diff";
              sha256 = "d1ffaaecab338e49357b6daa82e435f877e0649041ace7755583a0ea3362dbd7";
            };
          };
        in
        drv;

      thousand_island =
        let
          version = "1.6.0";
          drv = buildMix {
            inherit version;
            name = "thousand_island";

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "4d4720470f091fc21a1311777c2ac66916c43621bffc068590c9f9bb3cd057a3";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      typedstruct =
        let
          version = "0.6.3";
          drv = buildMix {
            inherit version;
            name = "typedstruct";

            src = fetchHex {
              inherit version;
              pkg = "typedstruct";
              sha256 = "d9e58c49efc6c6ab523be304f08f683b02c1434c97fcac15e30cb743c8a6941a";
            };
          };
        in
        drv;

      wax_ =
        let
          version = "0.7.0";
          drv = buildMix {
            inherit version;
            name = "wax_";

            src = fetchHex {
              inherit version;
              pkg = "wax_";
              sha256 = "473b3378608418747e67746b7164576f1690a4ed1e044a4c8085a754269d21ce";
            };

            beamDeps = [
              asn1_compiler
              cbor
              jason
              x509
            ];
          };
        in
        drv;

      websock =
        let
          version = "0.5.3";
          drv = buildMix {
            inherit version;
            name = "websock";

            src = fetchHex {
              inherit version;
              pkg = "websock";
              sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
            };
          };
        in
        drv;

      websock_adapter =
        let
          version = "0.7.2";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "f9e80710008783864177c81e9d8418d05769ce10a26e9e538f5ed72e283f7358";
            };

            beamDeps = [
              bandit
              plug
              websock
            ];
          };
        in
        drv;

      x509 =
        let
          version = "0.9.2";
          drv = buildMix {
            inherit version;
            name = "x509";

            src = fetchHex {
              inherit version;
              pkg = "x509";
              sha256 = "4c5ede75697e565d4b0f5be04c3b71bb1fd3a090ea243af4bd7dae144e48cfc7";
            };
          };
        in
        drv;

      xema =
        let
          version = "0.17.10";
          drv = buildMix {
            inherit version;
            name = "xema";

            src = fetchHex {
              inherit version;
              pkg = "xema";
              sha256 = "207353488d806cc6da0d5c5c1dc74d1be296a685cd52cd68792f7a1dc7d841a4";
            };

            beamDeps = [
              conv_case
              decimal
            ];
          };
        in
        drv;

      xml_builder =
        let
          version = "2.4.1";
          drv = buildMix {
            inherit version;
            name = "xml_builder";

            src = fetchHex {
              inherit version;
              pkg = "xml_builder";
              sha256 = "1b9a1146feb1e6c94e29d8acad0c8e7bf7d6df0ec68eb8c3501e47708da9eb00";
            };
          };
        in
        drv;

      yamerl =
        let
          version = "0.10.0";
          drv = buildRebar3 {
            inherit version;
            name = "yamerl";

            src = fetchHex {
              inherit version;
              pkg = "yamerl";
              sha256 = "346adb2963f1051dc837a2364e4acf6eb7d80097c0f53cbdc3046ec8ec4b4e6e";
            };
          };
        in
        drv;

      yaml_elixir =
        let
          version = "2.12.2";
          drv = buildMix {
            inherit version;
            name = "yaml_elixir";

            src = fetchHex {
              inherit version;
              pkg = "yaml_elixir";
              sha256 = "e7c1b10122f973e6558462d51c39026ba0e14afbc6745318e990ea82cfe9e159";
            };

            beamDeps = [
              yamerl
            ];
          };
        in
        drv;

      ymlr =
        let
          version = "5.1.6";
          drv = buildMix {
            inherit version;
            name = "ymlr";

            src = fetchHex {
              inherit version;
              pkg = "ymlr";
              sha256 = "b36d7c72384d2cb2094d2a3c8b0c3b12303e0ccd1b7b12333b81d75b1fe0b53a";
            };
          };
        in
        drv;

      zoneinfo =
        let
          version = "0.1.9";
          drv = buildMix {
            inherit version;
            name = "zoneinfo";

            src = fetchHex {
              inherit version;
              pkg = "zoneinfo";
              sha256 = "8bc3266afe79ab668de4fb2a7f182152c90f610bdd8519528e8ea1af70e0dea8";
            };
          };
        in
        drv;

    };
in
self
