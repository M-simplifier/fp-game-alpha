{
  description = "The tested Afterlight browser compiler (Linux / WSL2)";
  inputs.ghc-wasm.url = "git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git?rev=8079eb96bbc63823d99ad8acaff0765532625474";
  inputs.nixpkgs.follows = "ghc-wasm/nixpkgs";

  outputs = { self, ghc-wasm, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      # The SDK's driver understands this cross compiler's host/target units.
      # Native projects use Cabal 3.18.2; do not substitute it into this SDK.
      cabal = ghc-wasm.packages.${system}.cabal;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          ghc-wasm.packages.${system}.wasm32-wasi-ghc-9_14
          cabal pkgs.nodejs_24 pkgs.python3 pkgs.curl pkgs.gnutar pkgs.patch pkgs.gnumake
        ];
        shellHook = ''
          export CABAL=${cabal}/bin/cabal
          wasi_cc=$(wasm32-wasi-ghc --info | ${pkgs.python3}/bin/python3 -c 'import ast,sys; print(dict(ast.literal_eval(sys.stdin.read()))["C compiler command"])')
          export PATH="$(dirname "$wasi_cc"):$PATH"
        '';
      };
    };
}
