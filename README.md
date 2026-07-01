# claude-science-nix

Nix flake for [Claude Science](https://claude.com/product/claude-science), the AI-powered scientific workbench from Anthropic. Supports Linux x86_64 and macOS (Apple Silicon and Intel).

## Quick start

```bash
# Run once without installing
nix run github:ghawk/claude-science-nix

# Install permanently
nix profile install github:ghawk/claude-science-nix
```

The first launch downloads ~156 MB. On Linux, the wrapper sets up a bubblewrap overlay so that Claude Science's own sandboxing (micromamba, MCP connectors) can resolve bash, the dynamic linker, and CA certificates on NixOS.

## NixOS

Claude Science uses bubblewrap internally to create isolated conda environments. The inner sandbox binds `/lib64`, `/bin`, and `/etc/ssl` from the outer namespace but _never_ binds `/run`. On NixOS this means:

- `/run/current-system/sw/bin/bash` is unreachable
- `/run/current-system/sw/share/nix-ld/lib/ld.so` (nix-ld's compile-time default) is unreachable
- `/bin` only contains `sh`, not `bash`
- `/etc/ssl/certs/ca-certificates.crt` is a symlink chain that breaks inside the sandbox's tmpfs `/etc`

The wrapper handles all of these with an outer bubblewrap that overlays a patched nix-ld, a shell shim at `/bin`, and the real CA bundle at `/etc/ssl/certs` before Claude Science's own inner bwrap binds them through. No host configuration is needed.

## Flake usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    claude-science-nix.url = "github:ghawk/claude-science-nix";
  };

  outputs = { nixpkgs, claude-science-nix, ... }: {
    # Home Manager
    homeConfigurations."your-user" = ...;  # add claude-science-nix.packages.x86_64-linux.default to home.packages

    # Dev shell
    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
      packages = [ claude-science-nix.packages.x86_64-linux.default ];
    };
  };
}
```

See the [Home Manager example](#home-manager) below if you need the full boilerplate.

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

## Auto-updates

A GitHub Actions workflow checks for new upstream releases every 30 minutes. When a new version is detected it opens a PR with updated hashes. Merge the PR to update.

To check or apply updates manually:

```bash
./scripts/update.sh --check   # see if an update is available
./scripts/update.sh           # apply it
```

## Supported platforms

| Platform              | Architecture | Format           |
| --------------------- | ------------ | ---------------- |
| Linux                 | x86_64       | ELF binary       |
| macOS (Apple Silicon) | aarch64      | DMG, .app bundle |
| macOS (Intel)         | x86_64       | DMG, .app bundle |

## License

The packaging code in this repository is MIT. Claude Science itself is proprietary software; see [claude.com/product/claude-science](https://claude.com/product/claude-science) for its license terms.
