# claude-science-nix

[![Build](https://github.com/ghawk/claude-science-nix/actions/workflows/build.yml/badge.svg)](https://github.com/ghawk/claude-science-nix/actions/workflows/build.yml)

Self-updating [Nix](https://nixos.org/) flake for [Claude Science](https://claude.com/product/claude-science), the AI-powered scientific workbench from Anthropic. Supports **Linux x86_64** and **macOS** (Apple Silicon + Intel).

## Quick start

```bash
# Run once (no install)
nix run github:ghawk/claude-science-nix

# Install permanently
nix profile install github:ghawk/claude-science-nix
```

## Home Manager

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    claude-science-nix.url = "github:ghawk/claude-science-nix";
  };

  outputs = { nixpkgs, home-manager, claude-science-nix, ... }:
    let system = "x86_64-linux"; in   # or aarch64-darwin / x86_64-darwin
    {
      homeConfigurations."your-user" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        modules = [{
          home.packages = [ claude-science-nix.packages.${system}.default ];
        }];
      };
    };
}
```

## Dev shell

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    claude-science-nix.url = "github:ghawk/claude-science-nix";
  };
  outputs = { nixpkgs, claude-science-nix, ... }:
    let system = "x86_64-linux"; in
    {
      devShells.${system}.default = nixpkgs.legacyPackages.${system}.mkShell {
        packages = [ claude-science-nix.packages.${system}.default ];
      };
    };
}
```

## Auto-updates

A [GitHub Actions workflow](.github/workflows/update.yml) checks for new upstream releases every 30 minutes. When a new version is detected it opens a PR with updated hashes. Merging the PR is all you need to stay current.

## Manual update

```bash
# Check if an update is available
./scripts/update.sh --check

# Apply the update
./scripts/update.sh
```

## Supported platforms

| Platform          | Architecture | Format             |
| ----------------- | ------------ | ------------------ |
| Linux             | x86_64       | ELF binary         |
| macOS (Apple Silicon) | aarch64 | DMG → .app bundle  |
| macOS (Intel)     | x86_64       | DMG → .app bundle  |

## License

The packaging code in this repository is MIT. Claude Science itself is proprietary software; see [claude.com/product/claude-science](https://claude.com/product/claude-science) for its license terms.
