{
  description = "Fluid Onchain";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    aiken.url = "github:aiken-lang/aiken";
  };
  outputs = { self, nixpkgs, aiken, flake-utils }:
    let
      
    in flake-utils.lib.eachSystem ["x86_64-linux"] (system: 
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [];
        };
      in rec {
        devShell = pkgs.haskellPackages.shellFor {
          packages=  p: [];
          buildInputs = [
            aiken.packages.${system}.aiken
          ];
        };
      }
    );
}
