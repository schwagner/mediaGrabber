{
  description = "mediaGrabber — insert a CD or DVD, get it in the Jellyfin library";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.default = pkgs.callPackage ./package.nix { };
      nixosModules.default = import ./module.nix self;
    };
}
