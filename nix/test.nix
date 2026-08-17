{ self }:
{ lib, ... }:
{
  name = "tracker";

  nodes.machine =
    { pkgs, ... }:
    let
      environmentFile = pkgs.writeText "tracker.env" ''
        SECRET_KEY_BASE=${lib.concatStrings (lib.genList (_: "0123456789") 7)}
        TOKEN_SIGNING_SECRET=token-signing-secret
      '';

      githubKey = pkgs.runCommand "tracker-test-github-key" {
        nativeBuildInputs = [ pkgs.openssl ];
      } "openssl genrsa -out $out 2048";
    in
    {
      imports = [ self.nixosModules.default ];

      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 4096;

      environment.systemPackages = [ pkgs.curl ];

      services.tracker = {
        enable = true;
        database.createLocally = true;
        inherit environmentFile;

        github = {
          clientId = "test-client-id";
          clientSecretFile = pkgs.writeText "client-secret" "test-client-secret";
          appId = 1;
          privateKeyFile = githubKey;
          installationId = 1;
          redirectUri = "http://localhost:6950/auth/user/github/callback";
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("tracker.service")
    machine.wait_for_open_port(6950)
    machine.succeed("curl --fail --silent --show-error --output /dev/null http://localhost:6950/")
  '';
}
