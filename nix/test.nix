{ self }:
{ lib, ... }:
{
  name = "tracker";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];

      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 4096;
      environment.systemPackages = [ pkgs.curl ];

      systemd.services.tracker-fixtures = {
        before = [
          "tracker.service"
          "tracker-https.service"
        ];
        requiredBy = [
          "tracker.service"
          "tracker-https.service"
        ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        path = [
          pkgs.openssl
          pkgs.git
        ];
        script = ''
          install --directory --mode=0700 /run/tracker-secrets
          umask 0077
          printf '%s\n' '${
            lib.concatStrings (lib.genList (_: "0123456789") 7)
          }' > /run/tracker-secrets/secret-key-base
          printf '%s\n' token-signing-secret > /run/tracker-secrets/token-signing-secret
          printf '%s\n' test-metrics-token > /run/tracker-secrets/metrics-token
          printf '%s' test-client-secret > /run/tracker-secrets/client-secret
          openssl genrsa -out /run/tracker-secrets/github-key 2048
          install --directory --mode=0755 /run/tracker-https
          openssl req -x509 -newkey rsa:2048 -nodes -keyout /run/tracker-secrets/https-key -out /run/tracker-https/cert.pem -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost
          chmod 0644 /run/tracker-https/cert.pem
          umask 0022
          git init /run/tracker-https/repo
          printf '%s\n' sandbox-network-ok > /run/tracker-https/repo/probe
          git -C /run/tracker-https/repo add probe
          git -C /run/tracker-https/repo -c user.name=Test -c user.email=test@localhost commit --message=fixture
          git -C /run/tracker-https/repo update-server-info
        '';
      };

      systemd.services.tracker-https = {
        before = [ "tracker.service" ];
        requiredBy = [ "tracker.service" ];
        serviceConfig = {
          WorkingDirectory = "/run/tracker-https";
          ExecStart = "${pkgs.openssl}/bin/openssl s_server -accept 8443 -cert /run/tracker-https/cert.pem -key /run/tracker-secrets/https-key -WWW";
        };
      };

      services.tracker = {
        enable = true;
        database.createLocally = true;
        settings = {
          PORT = "6951";
          TRACKER_GITHUB_CLIENT_ID = "test-client-id";
          TRACKER_GITHUB_APP_ID = "1";
          TRACKER_GITHUB_INSTALLATION_ID = "1";
          TRACKER_GITHUB_REDIRECT_URI = "http://localhost:6951/auth/user/github/callback";
        };
        credentials = {
          SECRET_KEY_BASE_FILE = "/run/tracker-secrets/secret-key-base";
          TOKEN_SIGNING_SECRET_FILE = "/run/tracker-secrets/token-signing-secret";
          TRACKER_METRICS_TOKEN_FILE = "/run/tracker-secrets/metrics-token";
          TRACKER_GITHUB_CLIENT_SECRET_FILE = "/run/tracker-secrets/client-secret";
          TRACKER_GITHUB_APP_PRIVATE_KEY_FILE = "/run/tracker-secrets/github-key";
        };
      };

      systemd.services.tracker.serviceConfig.ExecStartPre = lib.mkBefore [
        (pkgs.writeShellScript "tracker-sandbox-check" ''
          set -eu
          test "$(umask)" = 0077
          test ! -e /proc/meminfo
          test ! -e /proc/1
          test "$(stat --dereference --format=%a /var/lib/tracker)" = 700
          test "$(stat --dereference --format=%a /run/tracker)" = 700
          test ! -r /run/tracker-secrets/client-secret
          test ! -r /run/tracker-secrets/github-key
          test ! -r /run/tracker-secrets/metrics-token
          test -z "''${TRACKER_METRICS_TOKEN+x}"
          test "$TRACKER_GITHUB_ENABLED" = true
          test "$(cat "$TRACKER_METRICS_TOKEN_FILE")" = test-metrics-token
          test "$(cat "$TRACKER_GITHUB_CLIENT_SECRET_FILE")" = test-client-secret
          ${pkgs.openssl}/bin/openssl rsa -in "$TRACKER_GITHUB_APP_PRIVATE_KEY_FILE" -check -noout
          ${pkgs.curl}/bin/curl --fail --silent --show-error --retry 10 --retry-connrefused --cacert /run/tracker-https/cert.pem https://localhost:8443/repo/probe
          rm --recursive --force /var/lib/tracker/network-probe
          GIT_SMART_HTTP=0 ${pkgs.git}/bin/git -c http.sslCAInfo=/run/tracker-https/cert.pem clone https://localhost:8443/repo/.git /var/lib/tracker/network-probe
          test "$(cat /var/lib/tracker/network-probe/probe)" = sandbox-network-ok
          test "$(stat --format=%a /var/lib/tracker/network-probe/probe)" = 600
        '')
      ];

      specialisation.legacy.configuration = {
        services.tracker.settings.PHX_IP = "0.0.0.0";
        services.postgresql.ensureUsers = lib.mkForce [
          {
            name = "tracker";
            ensureDBOwnership = true;
            ensureClauses.superuser = true;
          }
        ];
      };
    };

  testScript = ''
    machine.wait_for_unit("tracker.service")
    machine.wait_for_open_port(6951)
    machine.succeed("curl --fail --silent --show-error --output /dev/null http://localhost:6951/")
    metrics = machine.succeed("curl --fail --silent --show-error --header 'Authorization: Bearer test-metrics-token' http://localhost:6951/metrics")
    assert any(line.startswith("tracker_prom_ex_prom_ex_status_info") and float(line.split()[-1]) == 1 for line in metrics.splitlines()), metrics
    machine.succeed("ss --listening --tcp --numeric | grep '127.0.0.1:6951'")
    machine.fail("ss --listening --tcp --numeric | grep '0.0.0.0:6951'")
    machine.succeed("test $(stat --format=%a /run/tracker-secrets/client-secret) = 600")
    machine.succeed("test $(stat --format=%a /run/tracker-secrets/github-key) = 600")
    roles = machine.succeed("sudo --user=postgres psql --command='\\du tracker'")
    assert "Superuser" not in roles, roles
    extensions = machine.succeed("sudo --user=postgres psql --dbname=tracker --command='\\dx'")
    for extension in ["pg_trgm", "btree_gist", "citext"]:
        assert extension in extensions, extensions
    tables = machine.succeed("sudo --user=postgres psql --dbname=tracker --command='\\dt'")
    assert "schema_migrations" in tables, tables
    original = machine.succeed("readlink --canonicalize /run/current-system").strip()
    machine.succeed(f"{original}/specialisation/legacy/bin/switch-to-configuration test")
    machine.wait_for_unit("tracker.service")
    machine.wait_until_succeeds("ss --listening --tcp --numeric | grep '0.0.0.0:6951'")
    roles = machine.succeed("sudo --user=postgres psql --command='\\du tracker'")
    assert "Superuser" in roles, roles
    machine.succeed(f"{original}/bin/switch-to-configuration test")
    machine.wait_for_unit("tracker.service")
    machine.wait_until_succeeds("ss --listening --tcp --numeric | grep '127.0.0.1:6951'")
    roles = machine.succeed("sudo --user=postgres psql --command='\\du tracker'")
    assert "Superuser" not in roles, roles
    machine.succeed("curl --fail --silent --show-error --output /dev/null http://localhost:6951/")
  '';
}
