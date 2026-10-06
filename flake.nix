{
  description = "Omnix: NixOS with the standard Linux library layout";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      appTests = import ./tests/apps-gui.nix {
        inherit pkgs;
        module = self.nixosModules.default;
      };
      desktopTests = import ./tests/apps-desktop.nix {
        inherit pkgs;
        module = self.nixosModules.default;
      };
    in
    {
      nixosModules.default = import ./modules/fhs.nix;
      nixosModules.fhs = self.nixosModules.default;

      checks.${system} = {
        fhs = import ./tests/fhs.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };
        # GUI apps in an X11 session: tests/apps-gui.nix.
        app-filmcraft = appTests.filmcraft;
        app-obs = appTests.obs;
        # Desktop apps: tests/apps-desktop.nix.
        app-brave = desktopTests.brave;
        app-telegram = desktopTests.telegram;
        app-kitty = desktopTests.kitty;
        app-signal = desktopTests.signal;
        app-slack = desktopTests.slack;
      };

      nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs.nixpkgsRev = nixpkgs.rev;
        # The installer runs only NixOS tools, so it is the stock installer
        # without the FHS layer; the installed system gets it from its flake.
        # (envfs on the live ISO also breaks NetworkManager's DNS: Omnix#1.)
        modules = [ ./installer/iso.nix ];
      };
      packages.${system}.iso = self.nixosConfigurations.installer.config.system.build.isoImage;
    };
}
