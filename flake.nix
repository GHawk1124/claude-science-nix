{
  description = "Claude Science: self-updating Nix flake for Linux and macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        packages = {
          default = pkgs.callPackage ./package.nix { };
          claude-science = pkgs.callPackage ./package.nix { };
        };

        apps = let
          # Wrapper: default to 'serve' so `nix run` starts the daemon
          # without the y/N prompt.  Passes through explicit subcommands.
          entrypoint = pkgs.writeShellScriptBin "claude-science-entry" ''
            if [ $# -eq 0 ]; then
              exec ${self.packages.${system}.claude-science}/bin/claude-science serve
            else
              exec ${self.packages.${system}.claude-science}/bin/claude-science "$@"
            fi
          '';
        in {
          default = {
            type = "app";
            program = "${entrypoint}/bin/claude-science-entry";
          };
          claude-science = {
            type = "app";
            program = "${entrypoint}/bin/claude-science-entry";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nix-prefetch
            nixpkgs-fmt
          ];
        };

        formatter = pkgs.nixpkgs-fmt;
      }
    )
    // {
      overlays.default = final: _prev: {
        claude-science = final.callPackage ./package.nix { };
      };
    };
}
