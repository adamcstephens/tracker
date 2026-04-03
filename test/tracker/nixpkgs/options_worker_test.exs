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

      nginx_mod = Enum.find(modules, &(&1.display_name == "services.nginx"))
      openssh_mod = Enum.find(modules, &(&1.display_name == "services.openssh"))

      assert nginx_mod
      assert openssh_mod

      # Verify declarations are in the join table
      declarations = Ash.read!(Tracker.Nixpkgs.ModuleDeclaration)

      nginx_decl = Enum.find(declarations, &(&1.module_id == nginx_mod.id))
      assert nginx_decl.path == "nixos/modules/services/web-servers/nginx/default.nix"

      openssh_decl = Enum.find(declarations, &(&1.module_id == openssh_mod.id))
      assert openssh_decl.path == "nixos/modules/services/networking/ssh/sshd.nix"

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
      # Display name is the longest common prefix of all option names under this module
      assert mod.display_name == "services.misskey.reverseProxy.webserver"

      # Synthetic declaration derived from first 2 segments of option name
      decl = hd(Ash.read!(Tracker.Nixpkgs.ModuleDeclaration))
      assert decl.module_id == mod.id
      assert decl.path == "services.misskey"

      options_records = Ash.read!(Tracker.Nixpkgs.Option)
      assert Enum.all?(options_records, &(&1.module_id == mod.id))
    end

    test "normalizes doubled nixos/modules/ prefix in declarations" do
      channel_revision = create_successful_revision("nixos-unstable", "opt008")

      options = %{
        "console.font" => %{
          "declarations" => ["nixos/modules/nixos/modules/config/console.nix"],
          "description" => "The font used for the virtual consoles.",
          "loc" => ["console", "font"],
          "readOnly" => false,
          "type" => "string"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      mod = hd(Ash.read!(Tracker.Nixpkgs.Module))
      decl = hd(Ash.read!(Tracker.Nixpkgs.ModuleDeclaration))
      assert decl.module_id == mod.id
      assert decl.path == "nixos/modules/config/console.nix"
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
      assert mod.display_name == "fileSystems"

      decl = hd(Ash.read!(Tracker.Nixpkgs.ModuleDeclaration))
      assert decl.module_id == mod.id
      assert decl.path == "nixos/modules/tasks/filesystems.nix"

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

  describe "option-package linking" do
    test "creates OptionPackage links for type=package with pkgs.ATTR default" do
      channel_revision = create_successful_revision("nixos-unstable", "link001")

      # Create packages in the DB first
      Tracker.Nixpkgs.Package.bulk_upsert_all([
        %{attribute: "nginx"},
        %{attribute: "openssh"}
      ])

      options = %{
        "services.nginx.package" => %{
          "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
          "description" => "The nginx package.",
          "loc" => ["services", "nginx", "package"],
          "readOnly" => false,
          "type" => "package",
          "default" => %{"_type" => "literalExpression", "text" => "pkgs.nginx"}
        },
        "services.openssh.package" => %{
          "declarations" => ["nixos/modules/services/networking/ssh/sshd.nix"],
          "description" => "The openssh package.",
          "loc" => ["services", "openssh", "package"],
          "readOnly" => false,
          "type" => "package",
          "default" => %{"_type" => "literalExpression", "text" => "pkgs.openssh"}
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      option_packages = Ash.read!(Tracker.Nixpkgs.OptionPackage)
      assert length(option_packages) == 2

      nginx_opt =
        Enum.find(Ash.read!(Tracker.Nixpkgs.Option), &(&1.name == "services.nginx.package"))

      nginx_pkg_id = Tracker.Nixpkgs.Package.get_by_attribute!("nginx").id

      assert Enum.any?(option_packages, fn op ->
               op.option_id == nginx_opt.id and op.package_id == nginx_pkg_id
             end)
    end

    test "skips unresolved attribute paths" do
      channel_revision = create_successful_revision("nixos-unstable", "link002")

      # No packages in DB — attribute won't resolve
      options = %{
        "services.nonexistent.package" => %{
          "declarations" => ["nixos/modules/test.nix"],
          "description" => "Test.",
          "loc" => ["services", "nonexistent", "package"],
          "readOnly" => false,
          "type" => "package",
          "default" => %{"_type" => "literalExpression", "text" => "pkgs.does-not-exist"}
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      assert Ash.read!(Tracker.Nixpkgs.OptionPackage) == []
    end

    test "creates links from relatedPackages field" do
      channel_revision = create_successful_revision("nixos-unstable", "link003")

      Tracker.Nixpkgs.Package.bulk_upsert_all([
        %{attribute: "xorg.xorgserver"},
        %{attribute: "xterm"}
      ])

      options = %{
        "services.xserver.enable" => %{
          "declarations" => ["nixos/modules/services/x11/xserver.nix"],
          "description" => "Enable X server.",
          "loc" => ["services", "xserver", "enable"],
          "readOnly" => false,
          "type" => "boolean",
          "relatedPackages" =>
            "- [`pkgs.xorg.xorgserver`](#opt-services.xserver.package)\n- [`pkgs.xterm`](#opt-something)"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      option_packages = Ash.read!(Tracker.Nixpkgs.OptionPackage)
      assert length(option_packages) == 2
    end
  end

  describe "backfill_channel/1" do
    test "schedules jobs for successful revisions missing options" do
      alias Tracker.Nixpkgs.ReleaseCache
      alias Tracker.Nixpkgs.ReleaseCache.Release

      channel = "nixos-bkf-#{System.unique_integer([:positive])}"

      ReleaseCache.put_releases(channel, [
        %Release{
          short_hash: "bkf002",
          base_url: "https://releases.nixos.org/nixos/unstable/#{channel}.bkf002",
          released_at: "2026-04-02T10:00:00Z"
        },
        %Release{
          short_hash: "bkf001",
          base_url: "https://releases.nixos.org/nixos/unstable/#{channel}.bkf001",
          released_at: "2026-04-01T10:00:00Z"
        }
      ])

      # Create two successful revisions (as if packages were already backfilled)
      rev1 = create_successful_revision(channel, "bkf001aaa111")
      _rev2 = create_successful_revision(channel, "bkf002bbb222")

      # Give rev1 some option_revisions so it looks already processed
      OptionsWorker.write_to_database(
        %{
          "services.nginx.enable" => %{
            "declarations" => ["nixos/modules/services/web-servers/nginx/default.nix"],
            "description" => "Enable nginx.",
            "loc" => ["services", "nginx", "enable"],
            "readOnly" => false,
            "type" => "boolean"
          }
        },
        rev1
      )

      # Backfill should only schedule a job for rev2 (rev1 already has options)
      assert {:ok, 1} = OptionsWorker.backfill_channel(channel)

      assert_enqueued(
        worker: Tracker.Nixpkgs.OptionsWorker,
        args: %{
          "channel" => channel,
          "revision" => "bkf002bbb222",
          "base_url" => "https://releases.nixos.org/nixos/unstable/#{channel}.bkf002",
          "remaining" => 0
        }
      )
    end

    test "schedules only the first job with remaining count for chaining" do
      alias Tracker.Nixpkgs.ReleaseCache
      alias Tracker.Nixpkgs.ReleaseCache.Release

      channel = "nixos-chain-#{System.unique_integer([:positive])}"

      ReleaseCache.put_releases(channel, [
        %Release{
          short_hash: "chain003",
          base_url: "https://releases.nixos.org/nixos/unstable/#{channel}.chain003",
          released_at: "2026-04-03T10:00:00Z"
        },
        %Release{
          short_hash: "chain002",
          base_url: "https://releases.nixos.org/nixos/unstable/#{channel}.chain002",
          released_at: "2026-04-02T10:00:00Z"
        },
        %Release{
          short_hash: "chain001",
          base_url: "https://releases.nixos.org/nixos/unstable/#{channel}.chain001",
          released_at: "2026-04-01T10:00:00Z"
        }
      ])

      _rev1 = create_successful_revision(channel, "chain001aaa111")
      _rev2 = create_successful_revision(channel, "chain002bbb222")
      _rev3 = create_successful_revision(channel, "chain003ccc333")

      # All 3 need options, but only 1 job should be scheduled (oldest first)
      assert {:ok, 3} = OptionsWorker.backfill_channel(channel)

      assert_enqueued(
        worker: Tracker.Nixpkgs.OptionsWorker,
        args: %{
          "channel" => channel,
          "revision" => "chain001aaa111",
          "remaining" => 2
        }
      )
    end

    test "returns zero when all revisions already have options" do
      alias Tracker.Nixpkgs.ReleaseCache
      alias Tracker.Nixpkgs.ReleaseCache.Release

      channel = "nixos-zero-#{System.unique_integer([:positive])}"

      ReleaseCache.put_releases(channel, [
        %Release{
          short_hash: "bkf003",
          base_url: "https://releases.nixos.org/nixos/unstable/#{channel}.bkf003",
          released_at: "2026-04-01T10:00:00Z"
        }
      ])

      rev = create_successful_revision(channel, "bkf003ccc333")

      OptionsWorker.write_to_database(
        %{
          "services.test.enable" => %{
            "declarations" => ["nixos/modules/test.nix"],
            "description" => "Test.",
            "loc" => ["services", "test", "enable"],
            "readOnly" => false,
            "type" => "boolean"
          }
        },
        rev
      )

      assert {:ok, 0} = OptionsWorker.backfill_channel(channel)
    end
  end

  describe "module merging" do
    test "merges modules with same display_name from different declarations" do
      channel_revision = create_successful_revision("nixos-unstable", "opt009")

      options = %{
        "boot.devSize" => %{
          "declarations" => ["nixos/modules/system/boot/stage-2.nix"],
          "description" => "Size of /dev.",
          "loc" => ["boot", "devSize"],
          "readOnly" => false,
          "type" => "string"
        },
        "boot.runSize" => %{
          "declarations" => ["nixos/modules/system/boot/stage-2.nix"],
          "description" => "Size of /run.",
          "loc" => ["boot", "runSize"],
          "readOnly" => false,
          "type" => "string"
        },
        "boot.growPartition" => %{
          "declarations" => ["nixos/modules/system/boot/grow-partition.nix"],
          "description" => "Whether to grow the root partition.",
          "loc" => ["boot", "growPartition"],
          "readOnly" => false,
          "type" => "boolean"
        }
      }

      OptionsWorker.write_to_database(options, channel_revision)

      # Both declarations produce display_name "boot", so should merge into one module
      modules = Ash.read!(Tracker.Nixpkgs.Module)
      assert length(modules) == 1

      mod = hd(modules)
      assert mod.display_name == "boot"

      # Should have two declarations in the join table
      declarations = Ash.read!(Tracker.Nixpkgs.ModuleDeclaration)
      assert length(declarations) == 2
      assert Enum.all?(declarations, &(&1.module_id == mod.id))

      paths = Enum.map(declarations, & &1.path) |> Enum.sort()

      assert paths == [
               "nixos/modules/system/boot/grow-partition.nix",
               "nixos/modules/system/boot/stage-2.nix"
             ]

      # All 3 options should belong to the merged module
      options_records = Ash.read!(Tracker.Nixpkgs.Option)
      assert length(options_records) == 3
      assert Enum.all?(options_records, &(&1.module_id == mod.id))
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
