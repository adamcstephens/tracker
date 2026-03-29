defmodule Tracker.Nixpkgs.PackageSetMappingTest do
  use ExUnit.Case, async: true

  alias Tracker.Nixpkgs.PackageSetMapping

  describe "parse/1" do
    # Python: python311Packages.numpy → python 3.11
    test "python versioned package set" do
      assert PackageSetMapping.parse("python313Packages.numpy") == %{
               package_set: "python313Packages",
               set_version: "3.13",
               family_name: "numpy",
               ecosystem: "python"
             }
    end

    test "python different versions" do
      for {attr, version} <- [
            {"python311Packages.django", "3.11"},
            {"python312Packages.django", "3.12"},
            {"python314Packages.django", "3.14"}
          ] do
        result = PackageSetMapping.parse(attr)
        assert result.ecosystem == "python"
        assert result.set_version == version
        assert result.family_name == "django"
      end
    end

    # Perl: perlPackages.DBI, perl540Packages.DBI
    test "perl versioned package set" do
      assert PackageSetMapping.parse("perl540Packages.DBI") == %{
               package_set: "perl540Packages",
               set_version: "5.40",
               family_name: "DBI",
               ecosystem: "perl"
             }
    end

    test "perl unversioned package set" do
      assert PackageSetMapping.parse("perlPackages.DBI") == %{
               package_set: "perlPackages",
               set_version: nil,
               family_name: "DBI",
               ecosystem: "perl"
             }
    end

    test "perl5Packages (alias)" do
      result = PackageSetMapping.parse("perl5Packages.DBI")
      assert result.ecosystem == "perl"
      assert result.family_name == "DBI"
    end

    # Ruby: rubyPackages.rake, rubyPackages_3_4.rake
    test "ruby versioned package set" do
      assert PackageSetMapping.parse("rubyPackages_3_4.rake") == %{
               package_set: "rubyPackages_3_4",
               set_version: "3.4",
               family_name: "rake",
               ecosystem: "ruby"
             }
    end

    test "ruby unversioned package set" do
      assert PackageSetMapping.parse("rubyPackages.rake") == %{
               package_set: "rubyPackages",
               set_version: nil,
               family_name: "rake",
               ecosystem: "ruby"
             }
    end

    # OCaml: ocamlPackages.dune, ocamlPackages_latest.dune
    test "ocaml package set" do
      assert PackageSetMapping.parse("ocamlPackages.dune") == %{
               package_set: "ocamlPackages",
               set_version: nil,
               family_name: "dune",
               ecosystem: "ocaml"
             }
    end

    test "ocaml latest package set" do
      assert PackageSetMapping.parse("ocamlPackages_latest.dune") == %{
               package_set: "ocamlPackages_latest",
               set_version: "latest",
               family_name: "dune",
               ecosystem: "ocaml"
             }
    end

    # Beam: beam27Packages.elixir, beamMinimal26Packages.elixir
    test "beam package set" do
      assert PackageSetMapping.parse("beam27Packages.elixir") == %{
               package_set: "beam27Packages",
               set_version: "27",
               family_name: "elixir",
               ecosystem: "beam"
             }
    end

    test "beam minimal package set maps to same ecosystem" do
      assert PackageSetMapping.parse("beamMinimal26Packages.elixir") == %{
               package_set: "beamMinimal26Packages",
               set_version: "26-minimal",
               family_name: "elixir",
               ecosystem: "beam"
             }
    end

    # Linux: linuxPackages.bcc, linuxPackages_zen.bcc
    test "linux default package set" do
      assert PackageSetMapping.parse("linuxPackages.bcc") == %{
               package_set: "linuxPackages",
               set_version: nil,
               family_name: "bcc",
               ecosystem: "linux"
             }
    end

    test "linux variant package set" do
      assert PackageSetMapping.parse("linuxPackages_zen.bcc") == %{
               package_set: "linuxPackages_zen",
               set_version: "zen",
               family_name: "bcc",
               ecosystem: "linux"
             }
    end

    test "linux latest variant" do
      result = PackageSetMapping.parse("linuxPackages_latest.bcc")
      assert result.ecosystem == "linux"
      assert result.set_version == "latest"
    end

    # LLVM: llvmPackages_18.clang
    test "llvm package set" do
      assert PackageSetMapping.parse("llvmPackages_18.clang") == %{
               package_set: "llvmPackages_18",
               set_version: "18",
               family_name: "clang",
               ecosystem: "llvm"
             }
    end

    # CUDA: cudaPackages_11.cudnn
    test "cuda versioned package set" do
      assert PackageSetMapping.parse("cudaPackages_11.cudnn") == %{
               package_set: "cudaPackages_11",
               set_version: "11",
               family_name: "cudnn",
               ecosystem: "cuda"
             }
    end

    test "cuda unversioned package set" do
      assert PackageSetMapping.parse("cudaPackages.cudnn") == %{
               package_set: "cudaPackages",
               set_version: nil,
               family_name: "cudnn",
               ecosystem: "cuda"
             }
    end

    # Godot: godotPackages_4_4.godot
    test "godot package set" do
      assert PackageSetMapping.parse("godotPackages_4_4.godot") == %{
               package_set: "godotPackages_4_4",
               set_version: "4.4",
               family_name: "godot",
               ecosystem: "godot"
             }
    end

    # Zabbix: zabbix72.server
    test "zabbix package set" do
      assert PackageSetMapping.parse("zabbix72.server") == %{
               package_set: "zabbix72",
               set_version: "72",
               family_name: "server",
               ecosystem: "zabbix"
             }
    end

    # Qt: qt5.qtbase, qt6.qtbase
    test "qt package set" do
      assert PackageSetMapping.parse("qt6.qtbase") == %{
               package_set: "qt6",
               set_version: "6",
               family_name: "qtbase",
               ecosystem: "qt"
             }
    end

    # Chicken: chickenPackages_5.egg
    test "chicken package set" do
      assert PackageSetMapping.parse("chickenPackages_5.egg") == %{
               package_set: "chickenPackages_5",
               set_version: "5",
               family_name: "egg",
               ecosystem: "chicken"
             }
    end

    # Factor: factorPackages-0_99.foo
    test "factor package set" do
      assert PackageSetMapping.parse("factorPackages-0_99.foo") == %{
               package_set: "factorPackages-0_99",
               set_version: "0.99",
               family_name: "foo",
               ecosystem: "factor"
             }
    end

    # PHP: php83Packages vs php83Extensions are separate ecosystems
    test "php packages" do
      assert PackageSetMapping.parse("php83Packages.composer") == %{
               package_set: "php83Packages",
               set_version: "8.3",
               family_name: "composer",
               ecosystem: "php"
             }
    end

    test "php extensions are separate ecosystem" do
      assert PackageSetMapping.parse("php83Extensions.redis") == %{
               package_set: "php83Extensions",
               set_version: "8.3",
               family_name: "redis",
               ecosystem: "php-extensions"
             }
    end

    test "php unversioned packages" do
      result = PackageSetMapping.parse("phpPackages.composer")
      assert result.ecosystem == "php"
      assert result.set_version == nil
    end

    # Single-set ecosystems (no version variants)
    test "haskell single-set ecosystem" do
      assert PackageSetMapping.parse("haskellPackages.aeson") == %{
               package_set: "haskellPackages",
               set_version: nil,
               family_name: "aeson",
               ecosystem: "haskell"
             }
    end

    test "emacs single-set ecosystem" do
      result = PackageSetMapping.parse("emacsPackages.magit")
      assert result.ecosystem == "emacs"
      assert result.family_name == "magit"
    end

    test "R single-set ecosystem" do
      result = PackageSetMapping.parse("rPackages.ggplot2")
      assert result.ecosystem == "r"
      assert result.family_name == "ggplot2"
    end

    test "texlive single-set ecosystem" do
      result = PackageSetMapping.parse("texlivePackages.latex")
      assert result.ecosystem == "texlive"
      assert result.family_name == "latex"
    end

    # Lua: lua53Packages.foo, luaPackages.foo
    test "lua versioned package set" do
      result = PackageSetMapping.parse("lua53Packages.foo")
      assert result.ecosystem == "lua"
      assert result.set_version == "5.3"
      assert result.family_name == "foo"
    end

    test "lua unversioned package set" do
      result = PackageSetMapping.parse("luaPackages.foo")
      assert result.ecosystem == "lua"
      assert result.set_version == nil
      assert result.family_name == "foo"
    end

    # Top-level runtime packages
    test "top-level python interpreter" do
      assert PackageSetMapping.parse("python311") == %{
               package_set: nil,
               set_version: "3.11",
               family_name: "python",
               ecosystem: "python"
             }
    end

    test "top-level elixir" do
      assert PackageSetMapping.parse("elixir_1_18") == %{
               package_set: nil,
               set_version: "1.18",
               family_name: "elixir",
               ecosystem: "beam"
             }
    end

    test "top-level erlang" do
      assert PackageSetMapping.parse("erlang_27") == %{
               package_set: nil,
               set_version: "27",
               family_name: "erlang",
               ecosystem: "beam"
             }
    end

    # Fallback: unknown dotted attribute
    test "unknown dotted attribute gets family with no ecosystem" do
      assert PackageSetMapping.parse("xorg.libX11") == %{
               package_set: "xorg",
               set_version: nil,
               family_name: "libX11",
               ecosystem: ""
             }
    end

    # Undotted non-matching: no family
    test "undotted non-matching returns all nils" do
      assert PackageSetMapping.parse("vim") == %{
               package_set: nil,
               set_version: nil,
               family_name: nil,
               ecosystem: nil
             }
    end

    test "undotted non-matching complex name" do
      assert PackageSetMapping.parse("firefox") == %{
               package_set: nil,
               set_version: nil,
               family_name: nil,
               ecosystem: nil
             }
    end

    # Edge case: multi-dot attribute takes everything after first dot
    test "multi-dot attribute" do
      result = PackageSetMapping.parse("linuxKernel.kernels.linux_6_18")
      assert result.family_name == "kernels.linux_6_18"
    end

    # Edge case: python without version suffix is not matched as top-level
    test "bare python3 is not matched" do
      result = PackageSetMapping.parse("python3")
      assert result.family_name == nil
    end
  end
end
