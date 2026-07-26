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
              ++ (lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]);

              env = {
                ESBUILD_PATH = lib.getExe pkgs.esbuild;
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
        };
    };
}
