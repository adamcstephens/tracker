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
  pkg-config,
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
          version = "3.29.3";
          drv = buildMix {
            inherit version;
            name = "ash";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash";
              sha256 = "2a7a45d3a3b980457b5cc7e339a84a35c232a7ab99047bbf7ce55e7dc36df357";
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
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "ash_admin";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_admin";
              sha256 = "f8bd6c08b584a315a9574c7bbe9c1c914bc5c51838045994b0e5369871f9b3d8";
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

      ash_authentication =
        let
          version = "4.14.1";
          drv = buildMix {
            inherit version;
            name = "ash_authentication";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_authentication";
              sha256 = "e149234fc70dc2544aac7a52656318bebca89a58ecbe98fb884ae41cf76fe6d7";
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
              plug
              spark
              splode
            ];
          };
        in
        drv;

      ash_authentication_phoenix =
        let
          version = "2.17.1";
          drv = buildMix {
            inherit version;
            name = "ash_authentication_phoenix";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_authentication_phoenix";
              sha256 = "7df06425f487f268eb1623b5588762f7bf6b07805fa41ab3319fb3b9564a7dec";
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
              slugify
            ];
          };
        in
        drv;

      ash_json_api =
        let
          version = "1.7.1";
          drv = buildMix {
            inherit version;
            name = "ash_json_api";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_json_api";
              sha256 = "0ff72b51d99c93f7ee655d2d5e10b29f5561ad36a0ee11dadcbcec7a4b995368";
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
          version = "0.8.10";
          drv = buildMix {
            inherit version;
            name = "ash_oban";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_oban";
              sha256 = "e60992bd6df3a264cac0fd25e43358396d4fe92357210450d94c29e818eb469c";
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
          version = "2.3.24";
          drv = buildMix {
            inherit version;
            name = "ash_phoenix";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_phoenix";
              sha256 = "46e3209cfe5063c0e8d39cad98198cb8fbbccf9df6b29075c3ae45576f94c467";
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
          version = "2.10.0";
          drv = buildMix {
            inherit version;
            name = "ash_postgres";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_postgres";
              sha256 = "e73298910d29b8051b30af390094165848b588288204ab12990f365c9fc653cc";
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
          version = "0.6.5";
          drv = buildMix {
            inherit version;
            name = "ash_sql";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ash_sql";
              sha256 = "e054670f5cf59e5dd2b13695c5de02ade592dc2f012ece10adb98a87e94cca8b";
            };

            beamDeps = [
              ash
              ecto
              ecto_sql
            ];
          };
        in
        drv;

      assent =
        let
          version = "0.2.13";
          drv = buildMix {
            inherit version;
            name = "assent";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "assent";
              sha256 = "bf9f351b01dd6bceea1d1f157f05438f6765ce606e6eb8d29296003d29bf6eab";
            };

            beamDeps = [
              finch
              jose
              mint
              req
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
            appConfigPath = ./config;

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
          version = "1.12.0";
          drv = buildMix {
            inherit version;
            name = "bandit";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "45dac82dc86f45cf4a196dee9cc5a8b791d9c9469d996055f055e6ee36c66e20";
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
            appConfigPath = ./config;

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

      castore =
        let
          version = "1.0.20";
          drv = buildMix {
            inherit version;
            name = "castore";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "castore";
              sha256 = "940eafbfd8b14bee649f083bc11b3b54ec555b54c3e4ea8213351ff6fee39c10";
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
            appConfigPath = ./config;

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

      cinder =
        let
          version = "0.16.0";
          drv = buildMix {
            inherit version;
            name = "cinder";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "cinder";
              sha256 = "7248781ee0f0f616185bb61eaab822092be37bee2ed0036c9634fc46af397d07";
            };

            beamDeps = [
              ash
              ash_phoenix
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
            appConfigPath = ./config;

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
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "conv_case";
              sha256 = "88f29a3d97d1742f9865f7e394ed3da011abb7c5e8cc104e676fdef6270d4b4a";
            };
          };
        in
        drv;

      crux =
        let
          version = "0.1.4";
          drv = buildMix {
            inherit version;
            name = "crux";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "crux";
              sha256 = "ff7d880cf732d82360aa81e439b8d4831cd30768061c9233f90c97e10162b9c0";
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
            appConfigPath = ./config;

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
          version = "3.1.1";
          drv = buildMix {
            inherit version;
            name = "decimal";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "c5f25f2ced74a0587d03e6023f595db8e924c9d3922c8c8ffd9edfc4498cf1f6";
            };
          };
        in
        drv;

      dns_cluster =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "dns_cluster";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "dns_cluster";
              sha256 = "ba6f1893411c69c01b9e8e8f772062535a4cf70f3f35bcc964a324078d8c8240";
            };
          };
        in
        drv;

      ecto =
        let
          version = "3.14.1";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "24b991956796700f467d0a3ef3d303138a3ef9ddddf8b98f43758ee067b20a30";
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
            appConfigPath = ./config;

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
          version = "0.9.0";
          drv = buildMix {
            inherit version;
            name = "elixir_make";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "elixir_make";
              sha256 = "db23d4fd8b757462ad02f8aa73431a426fe6671c80b200d9710caf3d1dd0ffdb";
            };
          };
        in
        drv;

      esbuild =
        let
          version = "0.10.0";
          drv = buildMix {
            inherit version;
            name = "esbuild";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "esbuild";
              sha256 = "468489cda427b974a7cc9f03ace55368a83e1a7be12fba7e30969af78e5f8c70";
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
            appConfigPath = ./config;

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
          version = "0.12.10";
          drv = buildMix {
            inherit version;
            name = "ex_ast";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ex_ast";
              sha256 = "e03f668c4354e3a1382c3d762c0fcc82ca9670f6f37e62b9097ce752be6adf39";
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
            appConfigPath = ./config;

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
            appConfigPath = ./config;

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
          version = "0.23.0";
          drv = buildMix {
            inherit version;
            name = "finch";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "80e58d3f936f57e3fdf404f83a3642897ae6d9fb642934e46da4d8fe761b99d5";
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
          version = "0.1.6";
          drv = buildMix {
            inherit version;
            name = "fine";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "fine";
              sha256 = "5638eb4495488e885ebec167fa57973e5c35e1a50c344eb7666c90ec1c4e3b12";
            };
          };
        in
        drv;

      floki =
        let
          version = "0.38.4";
          drv = buildMix {
            inherit version;
            name = "floki";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "floki";
              sha256 = "bdb34645eee8e79845c7edaca2d4099a52804ee4d4a3ecc683a69451f0244973";
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
            appConfigPath = ./config;

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
          version = "0.1.11";
          drv = buildMix {
            inherit version;
            name = "glob_ex";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "glob_ex";
              sha256 = "342729363056e3145e61766b416769984c329e4378f1d558b63e341020525de4";
            };
          };
        in
        drv;

      hpax =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "hpax";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "afc7cb142ebcc2d01ce7816190b98ce5dd49e799111b24249f3443d730f377ca";
            };
          };
        in
        drv;

      idna =
        let
          version = "7.1.0";
          drv = buildRebar3 {
            inherit version;
            name = "idna";

            src = fetchHex {
              inherit version;
              pkg = "idna";
              sha256 = "6ae959a025bf36df61a8cab8508d9654891b5426a84c44d82deaffd6ddf8c71f";
            };
          };
        in
        drv;

      igniter =
        let
          version = "0.8.2";
          drv = buildMix {
            inherit version;
            name = "igniter";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "igniter";
              sha256 = "89146ad3fba21f3ea10873ae509fc760618623d4578e4723929a9dd1532aa30f";
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
            appConfigPath = ./config;

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
            appConfigPath = ./config;

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
          version = "2.6.2";
          drv = buildMix {
            inherit version;
            name = "joken";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "joken";
              sha256 = "5134b5b0a6e37494e46dbf9e4dad53808e5e787904b7c73972651b51cce3d72b";
            };

            beamDeps = [
              jose
            ];
          };
        in
        drv;

      jose =
        let
          version = "1.11.12";
          drv = buildMix {
            inherit version;
            name = "jose";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "jose";
              sha256 = "31e92b653e9210b696765cdd885437457de1add2a9011d92f8cf63e4641bab7b";
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
            appConfigPath = ./config;

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
          version = "0.1.11";
          drv = buildMix {
            inherit version;
            name = "lazy_html";
            appConfigPath = ./config;

            nativeBuildInputs = [
              lexbor
            ];

            src = fetchHex {
              inherit version;
              pkg = "lazy_html";
              sha256 = "3b1be592929c31eca1a21673d25696e5c14cddfe922d9d1a3e3b48be4163883b";
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
          version = "0.6.2";
          drv = buildMix {
            inherit version;
            name = "lumis";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "lumis";
              sha256 = "c58c28580574fb080b1e9f68e889fa4d26df7553b57e171a78e8424fe7f2603b";
            };

            beamDeps = [
              nimble_options
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      mdex =
        let
          version = "0.13.3";
          drv = buildMix {
            inherit version;
            name = "mdex";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "mdex";
              sha256 = "e970a6e323b46c14af5926cb1fbfa855aba782394abc3b7deb99d849f47412de";
            };

            beamDeps = [
              jason
              lumis
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
          version = "0.2.6";
          drv = buildMix {
            inherit version;
            name = "mdex_native";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "mdex_native";
              sha256 = "eaaf2af27162c9879f5aef66344101dadf1898e71ea6ac9eb811c8d92d8e49ad";
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
            appConfigPath = ./config;

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
          version = "1.9.3";
          drv = buildMix {
            inherit version;
            name = "mint";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "5f7c9342480c069dbbc4eeac3490303c9e01870ff01a7f1d29b6107054fc1e74";
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
          version = "0.16.1-mg.4";
          drv = buildMix {
            inherit version;
            name = "multigraph";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "multigraph";
              sha256 = "b9f3e2577cef4658eeedf97c76d22a86d33a7aab702a93c1da9c122e849e9037";
            };
          };
        in
        drv;

      nimble_options =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "nimble_options";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_options";
              sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
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
            appConfigPath = ./config;

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
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "nimble_pool";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "nimble_pool";
              sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
            };
          };
        in
        drv;

      oban =
        let
          version = "2.23.0";
          drv = buildMix {
            inherit version;
            name = "oban";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "oban";
              sha256 = "8e5f0cec5abecce78dd08cb14dc5438db90ec3884987b44773ce76fe60dd3f81";
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
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "oban_met";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "oban_met";
              sha256 = "5c81fd33beeb172603cf83bea760298eeb8709d584fbe79ae2d07b09917d6110";
            };

            beamDeps = [
              oban
            ];
          };
        in
        drv;

      oban_web =
        let
          version = "2.12.6";
          drv = buildMix {
            inherit version;
            name = "oban_web";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "oban_web";
              sha256 = "1ade7bbbde1a731c9e4aa23f9f7c8a3f2871e734c6bc46fa4e4384688a69921d";
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

      open_api_spex =
        let
          version = "3.22.3";
          drv = buildMix {
            inherit version;
            name = "open_api_spex";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "open_api_spex";
              sha256 = "5f74f1878fdc38f8e961b0b943ac7af88dcf3a82a0c0ef6680ddfd3d161aecbd";
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
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "owl";
              sha256 = "351e768af8f2edc575cdaab1a5a2f6d6381be591758a026c701c703145508a0c";
            };
          };
        in
        drv;

      phoenix =
        let
          version = "1.8.9";
          drv = buildMix {
            inherit version;
            name = "phoenix";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "3477e2dd5a4f61820341169031bdfe21275f659923bea9c5c0ea2aa1c3fcc046";
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
            appConfigPath = ./config;

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
          version = "4.3.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_html";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html";
              sha256 = "3eaa290a78bab0f075f791a46a981bbe769d94bc776869f4f3063a14f30497ad";
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
            appConfigPath = ./config;

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
          version = "0.8.7";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_dashboard";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_dashboard";
              sha256 = "3a8625cab39ec261d48a13b7468dc619c0ede099601b084e343968309bd4d7d7";
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
          version = "1.2.7";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "61e97938a4fcca6d6f2c836925623abf2f52a572cc8c6085e4074f3f6337e0eb";
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
          version = "2.2.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "adc313a5bf7136039f63cfd9668fde73bba0765e0614cba80c06ac9460ff3e96";
            };
          };
        in
        drv;

      phoenix_template =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "phoenix_template";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "phoenix_template";
              sha256 = "2c0c81f0e5c6753faf5cca2f229c9709919aba34fab866d3bc05060c9c444206";
            };

            beamDeps = [
              phoenix_html
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
            appConfigPath = ./config;

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
            appConfigPath = ./config;

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

      plug =
        let
          version = "1.20.3";
          drv = buildMix {
            inherit version;
            name = "plug";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "be266aee1b8536ef6409d58cf39a3121319f0ec47cfa1b24024485aa0e76ad76";
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
          version = "2.1.1";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "6470bce6ffe41c8bd497612ffde1a7e4af67f36a15eea5f921af71cf3e11247c";
            };
          };
        in
        drv;

      postgrex =
        let
          version = "0.22.3";
          drv = buildMix {
            inherit version;
            name = "postgrex";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "f018c13752b2b46e8d35d7e2d84c3276557cbfd880769109021a1d0ee36c1cfe";
            };

            beamDeps = [
              db_connection
              decimal
              jason
            ];
          };
        in
        drv;

      reactor =
        let
          version = "1.0.2";
          drv = buildMix {
            inherit version;
            name = "reactor";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "reactor";
              sha256 = "19fd55aaaadaae28f55133351051c25d4ac217f99e3e5a67940cc4a321e3948e";
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
          version = "0.6.3";
          drv = buildMix {
            inherit version;
            name = "req";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "e85b5c6c990e6c3f52bbba68e6f099118f2b8252825f96c7c3636b97a3de307d";
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
          version = "0.2.4";
          drv = buildMix {
            inherit version;
            name = "req_s3";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "req_s3";
              sha256 = "9a4662332c6f07e9d12017a11e42958e3f7169ec739e6704915ba2d4494772a2";
            };

            beamDeps = [
              req
            ];
          };
        in
        drv;

      rewrite =
        let
          version = "1.3.0";
          drv = buildMix {
            inherit version;
            name = "rewrite";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "rewrite";
              sha256 = "d111ac7ff3a58a802ef4f193bbd1831e00a9c57b33276e5068e8390a212714a5";
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
            appConfigPath = ./config;

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
          version = "0.9.0";
          drv = buildMix {
            inherit version;
            name = "rustler_precompiled";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "rustler_precompiled";
              sha256 = "471d97315bd3bf7b64623418b3693eedd8e47de3d1cb79a0ac8f9da7d770d94c";
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
            appConfigPath = ./config;

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
          version = "1.12.2";
          drv = buildMix {
            inherit version;
            name = "sourceror";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "sourceror";
              sha256 = "da37d3da09c5b890528802c7056a8f585a061973820d7656b6e3649c14f0e9cb";
            };
          };
        in
        drv;

      spark =
        let
          version = "2.7.2";
          drv = buildMix {
            inherit version;
            name = "spark";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "spark";
              sha256 = "adb323ddbf9dbbe326f9e5def54ac96c47911e852b2c270bb19a5147c56f1b45";
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
          version = "0.3.13";
          drv = buildMix {
            inherit version;
            name = "spitfire";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "spitfire";
              sha256 = "3601be88ceed4967b584e96444de3e1d12d6555ae0864a7390b9cd5332d134b4";
            };
          };
        in
        drv;

      splode =
        let
          version = "0.3.1";
          drv = buildMix {
            inherit version;
            name = "splode";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "splode";
              sha256 = "8f2309b6ec2ecbb01435656429ed1d9ed04ba28797a3280c3b0d1217018ecfbd";
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
            appConfigPath = ./config;

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
          version = "1.26.3";
          drv = buildMix {
            inherit version;
            name = "swoosh";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "swoosh";
              sha256 = "c7683d070fe8f8aa9d174e61b01f2d527be73cd8ac40037b7109184941eb569f";
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
          version = "1.4.2";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1";
            };
          };
        in
        drv;

      telemetry_metrics =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "telemetry_metrics";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "telemetry_metrics";
              sha256 = "e7b79e8ddfde70adb6db8a6623d1778ec66401f366e9a8f5dd0955c56bc8ce67";
            };

            beamDeps = [
              telemetry
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
            appConfigPath = ./config;

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
          version = "1.5.0";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "708923d40523e43cf99041ab37a0d4b0ec426ac6438fa3716ab23d919eaeb412";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      typedstruct =
        let
          version = "0.5.4";
          drv = buildMix {
            inherit version;
            name = "typedstruct";
            appConfigPath = ./config;

            src = fetchFromGitHub {
              owner = "saleyn";
              repo = "typedstruct";
              rev = "a5939bb210619cd9c362b87094ee343c55494ec3";
              hash = "sha256-Iw5Bbqa5J+37+NTFXTmQfko8BX5O2eHUVmhA7SUz3UI=";
            };
          };
        in
        drv;

      websock =
        let
          version = "0.5.3";
          drv = buildMix {
            inherit version;
            name = "websock";
            appConfigPath = ./config;

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
          version = "0.6.0";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "50021a85bce8f203b086705d9e0c5415e2c7eb05d319111b0428fe71f9934617";
            };

            beamDeps = [
              bandit
              plug
              websock
            ];
          };
        in
        drv;

      xema =
        let
          version = "0.17.9";
          drv = buildMix {
            inherit version;
            name = "xema";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "xema";
              sha256 = "5cb8757c006ee57423fc8f076f3289377dedce9baeb93d1997d6f19d5cee73a8";
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
          version = "2.4.0";
          drv = buildMix {
            inherit version;
            name = "xml_builder";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "xml_builder";
              sha256 = "833e325bb997f032b5a1b740d2fd6feed3c18ca74627f9f5f30513a9ae1a232d";
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
            appConfigPath = ./config;

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
          version = "5.1.5";
          drv = buildMix {
            inherit version;
            name = "ymlr";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ymlr";
              sha256 = "7030cb240c46850caeb3b01be745307632be319b15f03083136f6251f49b516d";
            };
          };
        in
        drv;

    };
in
self
