{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ];

      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { lib, pkgs, ... }:
        {
          devShells.default =

            let
              beamPackages = pkgs.beam_minimal.packages.erlang_27;
              elixir = beamPackages.elixir_1_17;
              elixir-ls = (beamPackages.elixir-ls.override { inherit elixir; });
            in
            pkgs.mkShell {
              packages = [
                beamPackages.erlang
                elixir
                elixir-ls
                pkgs.next-ls
              ] ++ (lib.optionals pkgs.stdenv.isLinux [ pkgs.inotify-tools ]);

              shellHook = ''
                export ERL_AFLAGS="-kernel shell_history enabled -kernel shell_history_file_bytes 1024000"
              '';
            };
        };
    };
}
