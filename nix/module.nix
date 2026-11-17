self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tracker;
  stateDir = "/var/lib/tracker";
in
{
  options.services.tracker = {
    enable = lib.mkEnableOption "the tracker server";

    package = lib.mkPackageOption self.packages.${pkgs.stdenv.hostPlatform.system} "server" {
      pkgsText = "tracker.packages.\${system}";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = "Public hostname used to generate URLs.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "IP address the HTTP endpoint binds to; defaults to loopback.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6950;
      description = "Port the HTTP endpoint listens on.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to an environment file read by systemd. Must define
        `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET`, plus `DATABASE_URL`
        unless {option}`services.tracker.database.createLocally` is set.
        Optionally define `TRACKER_METRICS_TOKEN` to enable bearer-authenticated
        Prometheus scraping at `/metrics`; without it the endpoint returns 404.
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Provision a local PostgreSQL server, database and non-superuser owner
          role, and connect over its unix socket.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "tracker";
        description = "Database and role name used when provisioning locally.";
      };
    };

    github = {
      clientId = lib.mkOption {
        type = lib.types.str;
        description = "OAuth client ID of the GitHub app.";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Runtime path to the OAuth client secret, loaded by systemd as a
          credential. The source file may be root-only. Do not put secret
          contents in the Nix store.
        '';
      };

      appId = lib.mkOption {
        type = lib.types.int;
        description = "Numeric ID of the GitHub app.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Runtime path to the GitHub app's PEM private key, loaded by systemd
          as a credential. The source file may be root-only. Do not put secret
          contents in the Nix store.
        '';
      };

      installationId = lib.mkOption {
        type = lib.types.int;
        description = "Installation ID of the GitHub app.";
      };

      redirectUri = lib.mkOption {
        type = lib.types.str;
        description = "OAuth redirect URI registered with the GitHub app.";
      };
    };

    nixpkgsGitPath = lib.mkOption {
      type = lib.types.path;
      default = "${stateDir}/nixpkgs";
      description = "Local clone of nixpkgs maintained by `Tracker.GitServer`.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        POOL_SIZE = "20";
      };
      description = ''
        Extra environment variables for the service, such as `POOL_SIZE` or the
        `TRACKER_S3_*` cache settings. Secrets belong in
        {option}`services.tracker.environmentFile` instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.name;
          ensureDBOwnership = true;
          ensureClauses.superuser = false;
        }
      ];
    };

    systemd.services.tracker = {
      description = "tracker server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ lib.optional cfg.database.createLocally "postgresql.target";
      requires = lib.optional cfg.database.createLocally "postgresql.target";

      path = [ pkgs.git ];

      environment = {
        PHX_SERVER = "true";
        PHX_HOST = cfg.host;
        PHX_IP = cfg.listenAddress;
        PORT = toString cfg.port;
        HOME = stateDir;
        RELEASE_TMP = "/run/tracker";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "tracker";
        TZDIR = "${pkgs.tzdata}/share/zoneinfo";
        NIXPKGS_GIT_PATH = cfg.nixpkgsGitPath;
        TRACKER_GITHUB_CLIENT_ID = cfg.github.clientId;
        TRACKER_GITHUB_CLIENT_SECRET_FILE = "%d/github-client-secret";
        TRACKER_GITHUB_APP_ID = toString cfg.github.appId;
        TRACKER_GITHUB_APP_PRIVATE_KEY_FILE = "%d/github-private-key";
        TRACKER_GITHUB_INSTALLATION_ID = toString cfg.github.installationId;
        TRACKER_GITHUB_REDIRECT_URI = cfg.github.redirectUri;
      }
      // lib.optionalAttrs cfg.database.createLocally {
        DATABASE_URL = "ecto://${cfg.database.name}@localhost/${cfg.database.name}?socket_dir=/run/postgresql";
      }
      // cfg.extraEnvironment;

      serviceConfig = {
        Type = "exec";
        ExecStartPre = "${lib.getExe cfg.package} eval 'Tracker.Release.migrate()'";
        ExecStart = "${lib.getExe cfg.package} start";
        EnvironmentFile = cfg.environmentFile;
        LoadCredential = [
          "github-client-secret:${toString cfg.github.clientSecretFile}"
          "github-private-key:${toString cfg.github.privateKeyFile}"
        ];
        Restart = "on-failure";

        DynamicUser = true;
        User = "tracker";
        Group = "tracker";
        StateDirectory = "tracker";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "tracker";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";

        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };
  };
}
