{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    sower.url = "git+https://tangled.org/adam.robins.wtf/sower";

  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.sower.flakeModules.sower
      ];

      flake.nixosModules = rec {
        tracker = import ./nix/module.nix inputs.self;
        default = tracker;
      };

      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
          inputs',
          lib,
          pkgs,
          ...
        }:
        let
          beamPackages = pkgs.beamMinimal29Packages.extend (
            _: prev: {
              elixir = prev.elixir_1_20;
            }
          );

          playwrightAssets = pkgs.runCommand "playwright-assets" { } ''
            mkdir -p $out/node_modules
            ln -s ${pkgs.playwright-driver} $out/node_modules/playwright
          '';
        in
        {
          devShells = {
            ci = pkgs.mkShell {
              packages = [
                pkgs.niks3
                inputs'.sower.packages.sower
              ];
            };

            default = pkgs.mkShell {
              packages = [
                beamPackages.erlang
                beamPackages.elixir
                beamPackages.expert
                beamPackages.hex
                pkgs.dexter

                pkgs.cargo
                pkgs.rustc
                pkgs.rustfmt

                pkgs.postgresql_18
                pkgs.process-compose

                pkgs.biome
                pkgs.just
              ]
              ++ (lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.inotify-tools ]);

              env = {
                ESBUILD_PATH = lib.getExe pkgs.esbuild;
                PLAYWRIGHT_ASSETS_DIR = "${playwrightAssets}";
                PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
                PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
                # PGBINOLD = "${pkgs.postgresql_17}/bin";
                # PGDATAOLD = ".services/postgres/data/17";
                # PGDATANEW = ".services/postgres/data/18";
              };

              shellHook = ''
                export PGDATA="$PWD/.services/postgres/data/18"
              '';
            };
          };

          packages = rec {
            default = server;
            server = pkgs.callPackage ./package.nix { inherit beamPackages; };
          };

          checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            vm = pkgs.testers.runNixOSTest (import ./nix/test.nix { inherit (inputs) self; });
          };
        };
    };
}
