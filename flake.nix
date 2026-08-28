{
  description = "Backend - Personal accounting system backend with CQRS and Event Sourcing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Use GHC 9.10.3 to match eventium
        hPkgs = pkgs.haskell.packages.ghc9103;

        # Build the backend package
        backendPackage = hPkgs.callCabal2nix "backend" ./. {
          # Reference local eventium packages
          eventium-core = hPkgs.callCabal2nix "eventium-core" ../lib/eventium/eventium-core { };
          eventium-memory = hPkgs.callCabal2nix "eventium-memory" ../lib/eventium/eventium-memory { };
          eventium-postgresql =
            hPkgs.callCabal2nix "eventium-postgresql" ../lib/eventium/eventium-postgresql
              { };
          eventium-sql-common =
            hPkgs.callCabal2nix "eventium-sql-common" ../lib/eventium/eventium-sql-common
              { };
        };

        # Development dependencies
        devDependencies = with pkgs; [
          # Haskell toolchain
          hPkgs.ghc
          hPkgs.cabal-install
          hPkgs.hpack

          # Database libraries/headers for building
          postgresql.lib
          postgresql.dev
          libpq
          libpq.dev

          # Development tools
          hPkgs.haskell-language-server
          hPkgs.hlint
          hPkgs.ormolu
          hPkgs.ghcid
          hPkgs.hspec-discover

          # Command runner
          just

          # System dependencies
          pkg-config
          zlib

          # PostgreSQL client tools (optional)
          postgresql
        ];

      in
      {
        # Export the package
        packages = {
          default = backendPackage;
          backend = backendPackage;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = devDependencies;

          # Set up environment for development
          shellHook = ''
            echo "💰 Accounting Backend Development Environment"
            echo "📦 GHC version: $(ghc --version)"
            echo "🔧 Quick Commands (using just):"
            echo "  • just --list          - Show all available commands"
            echo "  • just build           - Build the project"
            echo "  • just run             - Run the server"
            echo "  • just test            - Run tests"
            echo "  • just check           - Format and lint code"
            echo "  • just docker-up       - Start PostgreSQL"
            echo "  • just watch           - Continuous compilation"
            echo ""
            echo "📚 Or use Cabal directly:"
            echo "  • cabal build          - Build"
            echo "  • cabal run backend - Run"
            echo "  • cabal test           - Test"
            echo ""

            # Generate cabal file from package.yaml
            if [ -f package.yaml ]; then
              echo "📝 Generating backend.cabal from package.yaml..."
              hpack
              echo "✅ backend.cabal generated"
            fi

            echo ""
            echo "🚀 Get started: just dev-setup"
          '';

          # Environment variables
          # macOS uses DYLD_LIBRARY_PATH (LD_LIBRARY_PATH is ignored by dyld)
          DYLD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.postgresql.lib
            pkgs.libpq
            pkgs.zlib
          ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.postgresql.lib
            pkgs.libpq
            pkgs.zlib
          ];

          # Database connection defaults (consumed by config/*.yaml)
          DB_HOST = "127.0.0.1";
          DB_PORT = "5432";
          DB_USER = "postgres";
          DB_PASSWORD = "password";
          DB_NAME = "accounting";
        };

        # Apps for easy running
        apps = {
          default = flake-utils.lib.mkApp {
            drv = backendPackage;
            exePath = "/bin/backend";
          };
        };
      }
    );
}
