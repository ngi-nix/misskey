{
  description = "Misskey";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      nixpkgsFor = forAllSystems (system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlay ];
        });
    in
    {
      overlay = final: prev: with prev; {
        misskey = mkYarnPackage {
          pname = "misskey";
          version = "12.91.0";

          src = ./.;

          packageJSON = ./package.json;
          yarnLock = ./yarn.lock;

          buildInputs = [ elasticsearch-oss ffmpeg ];

          buildPhase = ''
            yarn
          '';

          meta = {
            description = "An interplanetary communication platform";
            homepage = "https://misskey.io";
            license = lib.licenses.agpl3Plus;
          };
        };
      };

      packages = forAllSystems (system: {
        inherit (nixpkgsFor.${system}) misskey;
      });

      defaultPackage = forAllSystems (system:
        self.packages.${system}.misskey);

      devShell = self.defaultPackage;
    };
}
