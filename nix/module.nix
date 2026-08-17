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
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Provision a local PostgreSQL server, database and role, and connect
          over its unix socket. The role is a superuser because the schema
          installs the `pg_trgm` and `btree_gist` extensions.
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
        description = "File containing the OAuth client secret.";
      };

      appId = lib.mkOption {
        type = lib.types.int;
        description = "Numeric ID of the GitHub app.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "File containing the GitHub app's PEM private key.";
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
          ensureClauses.superuser = true;
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
        PORT = toString cfg.port;
        HOME = stateDir;
        RELEASE_TMP = "/run/tracker";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "tracker";
        NIXPKGS_GIT_PATH = cfg.nixpkgsGitPath;
        TRACKER_GITHUB_CLIENT_ID = cfg.github.clientId;
        TRACKER_GITHUB_CLIENT_SECRET_FILE = toString cfg.github.clientSecretFile;
        TRACKER_GITHUB_APP_ID = toString cfg.github.appId;
        TRACKER_GITHUB_APP_PRIVATE_KEY_FILE = toString cfg.github.privateKeyFile;
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
        Restart = "on-failure";

        DynamicUser = true;
        User = "tracker";
        Group = "tracker";
        StateDirectory = "tracker";
        RuntimeDirectory = "tracker";

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
