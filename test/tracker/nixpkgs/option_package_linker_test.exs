defmodule Tracker.Nixpkgs.OptionPackageLinkerTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.OptionPackageLinker

  describe "extract_links/1" do
    test "signal 1: extracts pkgs.ATTR from type=package with clean default" do
      options = %{
        "services.nginx.package" => %{
          "type" => "package",
          "default" => "pkgs.nginx"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.nginx.package", "nginx"} in links
    end

    test "signal 1: handles dotted attribute paths like pkgs.xorg.xorgserver" do
      options = %{
        "services.xserver.package" => %{
          "type" => "package",
          "default" => "pkgs.xorg.xorgserver"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.xserver.package", "xorg.xorgserver"} in links
    end

    test "signal 1: handles trailing whitespace or newlines" do
      options = %{
        "services.test.package" => %{
          "type" => "package",
          "default" => "pkgs.hello\n"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.test.package", "hello"} in links
    end

    test "signal 1: handles raw {_type, text} map structure" do
      options = %{
        "services.nginx.package" => %{
          "type" => "package",
          "default" => %{"_type" => "literalExpression", "text" => "pkgs.nginx"}
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.nginx.package", "nginx"} in links
    end

    test "signal 2: extracts multiple pkgs.X from conditional default" do
      options = %{
        "services.test.package" => %{
          "type" => "package",
          "default" =>
            "if config.services.test.useAlternative then pkgs.alt-pkg else pkgs.main-pkg"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.test.package", "alt-pkg"} in links
      assert {"services.test.package", "main-pkg"} in links
    end

    test "signal 2: handles nil default for type=package" do
      options = %{
        "services.test.package" => %{
          "type" => "package",
          "default" => nil
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert links == []
    end

    test "signal 2: handles missing default key for type=package" do
      options = %{
        "services.test.package" => %{
          "type" => "package"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert links == []
    end

    test "signal 3: extracts from relatedPackages markdown" do
      options = %{
        "services.xserver.enable" => %{
          "type" => "boolean",
          "relatedPackages" =>
            "- [`pkgs.xorg.xorgserver`](#opt-services.xserver.package)\n- [`pkgs.xterm`](#opt-something)"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.xserver.enable", "xorg.xorgserver"} in links
      assert {"services.xserver.enable", "xterm"} in links
    end

    test "signal 3: extracts from search.nixos.org show= URLs" do
      options = %{
        "services.test.enable" => %{
          "type" => "boolean",
          "relatedPackages" =>
            "See [NixOS Search](https://search.nixos.org/packages?show=hello&from=0)"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.test.enable", "hello"} in links
    end

    test "deduplicates links across signals" do
      options = %{
        "services.test.package" => %{
          "type" => "package",
          "default" => "pkgs.hello",
          "relatedPackages" => "- [`pkgs.hello`](#opt-something)"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      hello_links = Enum.filter(links, fn {_, attr} -> attr == "hello" end)
      assert length(hello_links) == 1
    end

    test "ignores non-package type options without relatedPackages" do
      options = %{
        "services.nginx.enable" => %{
          "type" => "boolean",
          "default" => "false"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert links == []
    end

    test "combines signals from multiple options" do
      options = %{
        "services.nginx.package" => %{
          "type" => "package",
          "default" => "pkgs.nginx"
        },
        "services.xserver.enable" => %{
          "type" => "boolean",
          "relatedPackages" => "- [`pkgs.xterm`](#opt-something)"
        }
      }

      links = OptionPackageLinker.extract_links(options)
      assert {"services.nginx.package", "nginx"} in links
      assert {"services.xserver.enable", "xterm"} in links
    end
  end
end
