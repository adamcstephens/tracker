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

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        PHX_HOST = "tracker.example.org";
        PORT = "6950";
        POOL_SIZE = "20";
      };
      description = "Non-secret environment variables, using the names Tracker reads.";
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.externalPath;
      default = { };
      example = {
        SECRET_KEY_BASE_FILE = "/run/secrets/tracker-secret-key-base";
        TRACKER_GITHUB_APP_PRIVATE_KEY_FILE = "/run/secrets/tracker-github-key";
      };
      description = ''
        Runtime paths to secret files outside the Nix store, keyed by the
        `_FILE` environment variable names Tracker reads. systemd loads the
        files with `LoadCredential` and passes the loaded paths to Tracker.
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
        PHX_HOST = "localhost";
        PHX_IP = "127.0.0.1";
        PORT = "6950";
        HOME = stateDir;
        RELEASE_TMP = "/run/tracker";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "tracker";
        TZDIR = "${pkgs.tzdata}/share/zoneinfo";
        NIXPKGS_GIT_PATH = "${stateDir}/nixpkgs";
      }
      // lib.optionalAttrs cfg.database.createLocally {
        DATABASE_URL = "ecto://${cfg.database.name}@localhost/${cfg.database.name}?socket_dir=/run/postgresql";
      }
      // cfg.settings
      // lib.mapAttrs (name: _: "%d/${name}") cfg.credentials;

      serviceConfig = {
        Type = "exec";
        ExecStartPre = "${lib.getExe cfg.package} eval 'Tracker.Release.migrate()'";
        ExecStart = "${lib.getExe cfg.package} start";
        LoadCredential = lib.mapAttrsToList (name: path: "${name}:${toString path}") cfg.credentials;
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
