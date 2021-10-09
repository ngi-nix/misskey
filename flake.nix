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
      overlay = final: prev: with prev;
        let
          nodeModules = mkYarnModules {
            pname = "misskey-node_modules";
            version = "12.91.0";
            packageJSON = ./package.json;
            yarnLock = ./yarn.lock;
          };
        in
        {
          misskey = stdenv.mkDerivation {
            pname = "misskey";
            version = "12.91.0";

            src = ./.;

            buildInputs = [ yarn nodejs ];
            nativeBuildInputs = [ makeWrapper ];

            configurePhase = ''
              mkdir node_modules
              for dep in ${nodeModules}/node_modules/* ${nodeModules}/deps/misskey-node_modules/node_modules/*; do
                basename=$(basename $dep)
                if [[ ! -d node_modules/$basename ]]; then
                  cp -R $dep node_modules/
                fi
              done
              chmod -R 755 node_modules/three/examples/fonts
              export PATH="${nodeModules}/deps/misskey-node_modules/node_modules/.bin:$PATH"
            '';

            buildPhase = ''
              npm run build
            '';

            installPhase =
              let
                misskey-bin = writeScript "misskey" ''
                '';
              in
              ''
                mkdir -p $out/bin
                cp -R * $out/
                makeWrapper "${nodejs}/bin/node" "$out/bin/misskey" \
                  --add-flags "--experimental-json-modules" \
                  --add-flags "$out/index.js"
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

      devShell = forAllSystems (system:
        let
          pkgs = nixpkgsFor."${system}";
        in
        pkgs.mkShell {
          # TODO: add python3 and libc.dev
          buildInputs = with pkgs; [ yarn2nix yarn nodejs gcc libtool nasm pkgconfig zlib.dev git ];
        });
    };
}
