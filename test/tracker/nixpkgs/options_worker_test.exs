defmodule Tracker.Nixpkgs.OptionsWorkerTest do
  use Tracker.DataCase, async: true

  alias Tracker.Nixpkgs.OptionsWorker

  @sample_options %{
    "services.nginx.enable" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "Whether to enable Nginx Web Server.",
      "loc" => ["services", "nginx", "enable"],
      "readOnly" => false,
      "type" => "boolean",
      "default" => %{"_type" => "literalExpression", "text" => "false"},
      "example" => %{"_type" => "literalExpression", "text" => "true"}
    },
    "services.nginx.package" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "The nginx package to use.",
      "loc" => ["services", "nginx", "package"],
      "readOnly" => false,
      "type" => "package",
      "default" => %{"_type" => "literalExpression", "text" => "pkgs.nginx"}
    },
    "services.nginx.virtualHosts" => %{
      "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
      "description" => "Declarative vhost config.",
      "loc" => ["services", "nginx", "virtualHosts"],
      "readOnly" => false,
      "type" => "attribute set of (submodule)"
    },
    "services.openssh.enable" => %{
      "declarations" => ["nixos/modules/services/networking/ssh/sshd.nix"],
      "description" => "Whether to enable the OpenSSH secure shell daemon.",
      "loc" => ["services", "openssh", "enable"],
      "readOnly" => false,
      "type" => "boolean",
      "default" => %{"_type" => "literalExpression", "text" => "false"}
    },
    "services.openssh.ports" => %{
      "declarations" => ["nixos/modules/services/networking/ssh/sshd.nix"],
      "description" => "Specifies on which ports the SSH daemon listens.",
      "loc" => ["services", "openssh", "ports"],
      "readOnly" => false,
      "type" => "list of 16 bit unsigned integer; between 0 and 65535 (both inclusive)",
      "default" => %{"_type" => "literalExpression", "text" => "[ 22 ]"},
      "example" => %{"_type" => "literalExpression", "text" => "[ 22 2222 ]"}
    }
  }

  defp create_successful_revision(channel, revision) do
    rev =
      Tracker.Nixpkgs.ChannelRevision.create!(%{
        revision: revision,
        channel: channel,
        released_at: "2026-04-01T10:00:00Z"
      })

    Tracker.Nixpkgs.ChannelRevision.record_result!(rev, %{result: :success})
  end

  describe "write_to_database/2" do
    test "ingests options, creating modules, options, and option revisions" do
      channel_revision = create_successful_revision("nixos-unstable", "opt001")

      OptionsWorker.write_to_database(@sample_options, channel_revision)

      # Should create 2 modules (nginx and openssh declarations)
      modules = Ash.read!(Tracker.Nixpkgs.Module)
      assert length(modules) == 2

      nginx_mod =
        Enum.find(
          modules,
          &(&1.declaration == "nixos/modules/services/web-servers/nginx/default.nix")
        )

      openssh_mod =
        Enum.find(modules, &(&1.declaration == "nixos/modules/services/networking/ssh/sshd.nix"))

      assert nginx_mod.display_name == "services.nginx"
      assert openssh_mod.display_name == "services.openssh"

      # Should create 5 options
      options = Ash.read!(Tracker.Nixpkgs.Option)
      assert length(options) == 5

      nginx_enable = Enum.find(options, &(&1.name == "services.nginx.enable"))
      assert nginx_enable.module_id == nginx_mod.id

      openssh_enable = Enum.find(options, &(&1.name == "services.openssh.enable"))
      assert openssh_enable.module_id == openssh_mod.id

      # Should create 5 option revisions
      revisions = Ash.read!(Tracker.Nixpkgs.OptionRevision)
      assert length(revisions) == 5

      nginx_enable_rev = Enum.find(revisions, &(&1.option_id == nginx_enable.id))
      assert nginx_enable_rev.channel_revision_id == channel_revision.id
      assert nginx_enable_rev.description == "Whether to enable Nginx Web Server."
      assert nginx_enable_rev.type == "boolean"
      assert nginx_enable_rev.default == "false"
      assert nginx_enable_rev.example == "true"
      assert nginx_enable_rev.read_only == false
      assert nginx_enable_rev.loc == ["services", "nginx", "enable"]

      assert nginx_enable_rev.declarations == [
               "nixos/modules/services/web-servers/nginx/default.nix"
             ]
    end

    test "extracts text from {_type, text} default and example structures" do
      channel_revision = create_successful_revision("nixos-unstable", "opt002")

      options = %{
        "services.test.opt" => %{
          "declarations" => ["nixos/modules/test.nix"],
          "description" => "A test option.",
          "loc" => ["services", "test", "opt"],
          "readOnly" => false,
          "type" => "string",
          "default" => %{"_type" => "literalExpression", "text" => "\"hello\""},
          "example" => %{"_type" => "literalMD", "text" => "`\"world\"`"}
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      revisions = Ash.read!(Tracker.Nixpkgs.OptionRevision)
      assert length(revisions) == 1

      rev = hd(revisions)
      assert rev.default == "\"hello\""
      assert rev.example == "`\"world\"`"
    end

    test "handles options without default or example" do
      channel_revision = create_successful_revision("nixos-unstable", "opt003")

      options = %{
        "services.test.bare" => %{
          "declarations" => ["nixos/modules/test.nix"],
          "description" => "Bare option.",
          "loc" => ["services", "test", "bare"],
          "readOnly" => false,
          "type" => "string"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      rev = hd(Ash.read!(Tracker.Nixpkgs.OptionRevision))
      assert rev.default == nil
      assert rev.example == nil
    end

    test "derives module from option name prefix when declarations are empty" do
      channel_revision = create_successful_revision("nixos-unstable", "opt004")

      options = %{
        "services.misskey.reverseProxy.webserver.host" => %{
          "declarations" => [],
          "description" => "Webserver host.",
          "loc" => ["services", "misskey", "reverseProxy", "webserver", "host"],
          "readOnly" => false,
          "type" => "string"
        },
        "services.misskey.reverseProxy.webserver.port" => %{
          "declarations" => [],
          "description" => "Webserver port.",
          "loc" => ["services", "misskey", "reverseProxy", "webserver", "port"],
          "readOnly" => false,
          "type" => "16 bit unsigned integer"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      modules = Ash.read!(Tracker.Nixpkgs.Module)
      assert length(modules) == 1

      mod = hd(modules)
      # Synthetic declaration derived from first 2 segments of option name
      assert mod.declaration == "services.misskey"
      # Display name is the longest common prefix of all option names under this module
      assert mod.display_name == "services.misskey.reverseProxy.webserver"

      options_records = Ash.read!(Tracker.Nixpkgs.Option)
      assert Enum.all?(options_records, &(&1.module_id == mod.id))
    end

    test "handles options with multiple declarations using the first one" do
      channel_revision = create_successful_revision("nixos-unstable", "opt005")

      options = %{
        "fileSystems" => %{
          "declarations" => [
            "nixos/modules/tasks/filesystems.nix",
            "nixos/modules/tasks/filesystems/zfs.nix"
          ],
          "description" => "The file systems to be mounted.",
          "loc" => ["fileSystems"],
          "readOnly" => false,
          "type" => "attribute set of (submodule)"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      mod = hd(Ash.read!(Tracker.Nixpkgs.Module))
      assert mod.declaration == "nixos/modules/tasks/filesystems.nix"

      opt = hd(Ash.read!(Tracker.Nixpkgs.Option))
      assert opt.module_id == mod.id
    end

    test "stores related_packages field" do
      channel_revision = create_successful_revision("nixos-unstable", "opt006")

      options = %{
        "services.xserver.enable" => %{
          "declarations" => ["nixos/modules/services/x11/xserver.nix"],
          "description" => "Whether to enable the X server.",
          "loc" => ["services", "xserver", "enable"],
          "readOnly" => false,
          "type" => "boolean",
          "relatedPackages" => "- [`xorg.xorgserver`](#opt-services.xserver.package)"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      rev = hd(Ash.read!(Tracker.Nixpkgs.OptionRevision))
      assert rev.related_packages == "- [`xorg.xorgserver`](#opt-services.xserver.package)"
    end

    test "stores read_only options" do
      channel_revision = create_successful_revision("nixos-unstable", "opt007")

      options = %{
        "system.build.toplevel" => %{
          "declarations" => ["nixos/modules/system/activation/top-level.nix"],
          "description" => "The top-level derivation.",
          "loc" => ["system", "build", "toplevel"],
          "readOnly" => true,
          "type" => "package"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      rev = hd(Ash.read!(Tracker.Nixpkgs.OptionRevision))
      assert rev.read_only == true
    end
  end

  describe "option events" do
    test "generates added events when options appear in a new revision" do
      rev1 = create_successful_revision("nixos-unstable", "evtopt001")

      options1 = %{
        "services.nginx.enable" => %{
          "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
          "description" => "Enable nginx.",
          "loc" => ["services", "nginx", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        }
      }

      OptionsWorker.write_to_database(options1, rev1)
      assert Tracker.Nixpkgs.OptionEvent.list!() == []

      # Second revision adds openssh
      rev2 =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          revision: "evtopt002",
          channel: "nixos-unstable",
          released_at: "2026-04-02T10:00:00Z",
          previous_channel_revision_id: rev1.id
        })

      Tracker.Nixpkgs.ChannelRevision.record_result!(rev2, %{result: :success})

      options2 = %{
        "services.nginx.enable" => %{
          "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
          "description" => "Enable nginx.",
          "loc" => ["services", "nginx", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        },
        "services.openssh.enable" => %{
          "declarations" => ["nixos/modules/services/networking/ssh/sshd.nix"],
          "description" => "Enable sshd.",
          "loc" => ["services", "openssh", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        }
      }

      OptionsWorker.write_to_database(options2, rev2)

      events = Tracker.Nixpkgs.OptionEvent.list!()
      assert length(events) == 1

      event = hd(events)

      openssh_opt =
        Enum.find(Ash.read!(Tracker.Nixpkgs.Option), &(&1.name == "services.openssh.enable"))

      assert event.type == :added
      assert event.option_id == openssh_opt.id
    end

    test "generates removed events when options disappear" do
      rev1 = create_successful_revision("nixos-unstable", "evtopt003")

      options1 = %{
        "services.nginx.enable" => %{
          "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
          "description" => "Enable nginx.",
          "loc" => ["services", "nginx", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        },
        "services.openssh.enable" => %{
          "declarations" => ["nixos/modules/services/networking/ssh/sshd.nix"],
          "description" => "Enable sshd.",
          "loc" => ["services", "openssh", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        }
      }

      OptionsWorker.write_to_database(options1, rev1)

      # Second revision removes openssh
      rev2 =
        Tracker.Nixpkgs.ChannelRevision.create!(%{
          revision: "evtopt004",
          channel: "nixos-unstable",
          released_at: "2026-04-02T10:00:00Z",
          previous_channel_revision_id: rev1.id
        })

      Tracker.Nixpkgs.ChannelRevision.record_result!(rev2, %{result: :success})

      options2 = %{
        "services.nginx.enable" => %{
          "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
          "description" => "Enable nginx.",
          "loc" => ["services", "nginx", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        }
      }

      OptionsWorker.write_to_database(options2, rev2)

      events = Tracker.Nixpkgs.OptionEvent.list!()
      assert length(events) == 1

      event = hd(events)

      openssh_opt =
        Enum.find(Ash.read!(Tracker.Nixpkgs.Option), &(&1.name == "services.openssh.enable"))

      assert event.type == :removed
      assert event.option_id == openssh_opt.id
    end

    test "no events when no previous revision" do
      rev = create_successful_revision("nixos-unstable", "evtopt005")

      options = %{
        "services.nginx.enable" => %{
          "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
          "description" => "Enable nginx.",
          "loc" => ["services", "nginx", "enable"],
          "readOnly" => false,
          "type" => "boolean"
        }
      }

      OptionsWorker.write_to_database(options, rev)

      assert Tracker.Nixpkgs.OptionEvent.list!() == []
    end
  end

  describe "display_name_for_options/1" do
    test "computes longest common prefix" do
      option_names = [
        "services.nginx.enable",
        "services.nginx.package",
        "services.nginx.virtualHosts"
      ]

      assert OptionsWorker.display_name_for_options(option_names) == "services.nginx"
    end

    test "single option uses all but last segment" do
      assert OptionsWorker.display_name_for_options(["fileSystems"]) == "fileSystems"
    end

    test "deeply nested common prefix" do
      option_names = [
        "services.nginx.virtualHosts.foo.bar",
        "services.nginx.virtualHosts.foo.baz"
      ]

      assert OptionsWorker.display_name_for_options(option_names) ==
               "services.nginx.virtualHosts.foo"
    end
  end
end
