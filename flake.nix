{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
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
          devShells.default = pkgs.mkShell {
            packages = [
              beamPackages.erlang
              beamPackages.elixir
              beamPackages.expert
              beamPackages.hex
              pkgs.dexter

              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt

              pkgs.postgresql
              pkgs.process-compose

              pkgs.biome
              pkgs.just
            ]
            ++ (lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]);

            env = {
              ESBUILD_PATH = lib.getExe pkgs.esbuild;
            };
          };

          packages = rec {
            default = server;
            server = pkgs.callPackage ./package.nix { inherit beamPackages; };
          };
        };
    };
}
