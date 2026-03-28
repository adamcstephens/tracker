{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    services-flake.url = "github:juspay/services-flake";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.process-compose-flake.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          beamPackages = pkgs.beamMinimal28Packages.extend (
            _: prev: {
              elixir = prev.elixir_1_19;
            }
          );
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.process-compose.devServices.services.outputs.devShell ];

            packages = [
              beamPackages.erlang
              beamPackages.elixir
              beamPackages.expert
              beamPackages.hex

              pkgs.postgresql
              pkgs.process-compose

              pkgs.just
            ]
            ++ (lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]);

            shellHook = ''
              export PC_CONFIG_FILES=${config.process-compose.devServices.outputs.settingsFile}
            '';
          };

          process-compose.devServices = {
            imports = [
              inputs.services-flake.processComposeModules.default
            ];

            services.postgres.postgres1 = {
              enable = true;
              superuser = "postgres";
              port = 15433;
            };
          };
        };
    };
}
