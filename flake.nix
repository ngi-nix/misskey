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

            installPhase = ''
              mkdir -p $out/bin
              cp -R * $out/
              cp -R .config $out/
              makeWrapper "${nodejs}/bin/node" "$out/bin/misskey" \
                --add-flags "--experimental-json-modules" \
                --add-flags "$out/built/index.js"
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

      nixosModules = {
        misskey = { lib, pkgs, config, ... }:
          with lib;
          let
            cfg = config.services.misskey;
            yaml = pkgs.formats.yaml { };
            configFile =
              yaml.generate "default.yml" cfg.settings;
            # finalPackage is a variable which takes the user defined package for
            # misskey, such as 'services.misskey.package = pkgs.myCustomPackage'
            # and applies the user defined misskey config to it. This means
            # that no matter what package the user provides, it will be processed
            # and contain the default.yml (config file) in its output.
            finalPackage = pkgs.runCommandNoCC "misskey-with-config" { } ''
              cp -rs ${cfg.package} $out
              chmod +w -R $out
              ln -sf ${configFile} $out/.config/default.yml
            '';
            misskeyDefaultYml =
              # misskeyDefaultYml is a variable which writes and merges the default
              # config.json from the misskey package with the user defined config
              # from the nixosModule. In the case of a collision, the user
              # defined configuration takes precedence, since it is passed as the
              # second argument in lib.recursiveUpdate.
              pkgs.writeText "default.yml" (
                builtins.toJSON (
                  lib.recursiveUpdate
                    (builtins.fromJSON
                      (builtins.readFile "${pkgs.misskey}/.config/example.yml")
                    )
                    (builtins.fromJSON
                      (builtins.readFile (yaml.generate "default.yml" cfg.settings))
                    )
                )
              );
          in
          {
            options.services.misskey = {
              enable = mkEnableOption "Misskey";

              dataDir = mkOption {
                type = types.str;
                default = "/var/lib/misskey";
                description = ''
                  The directory where Misskey stores its data files. If left as the default value this directory will automatically be created before the Misskey server starts, otherwise the sysadmin is responsible for ensuring the directory exists with appropriate ownership and permissions.
                '';
              };

              package = mkOption {
                type = types.pkg;
                default = pkgs.misskey;
                description = ''
                  Package for Misskey.
                '';
              };

              extraConfig = mkOption {
                type = types.str;
                default = ''
                  arstneio
                '';
                description = "Misskey configuration.";
              };

              settings = mkOption {
                type = with types; submodule { freeformType = yaml.type; };
                description = "Misskey configuration, in submodule form.";
              };

              user = mkOption {
                type = types.str;
                default = "misskey";
                description = "User account under which Misskey runs.";
              };

              group = mkOption {
                type = types.str;
                default = "misskey";
                description = "Group under which Misskey runs.";
              };
            };

            config = mkIf cfg.enable {
              nixpkgs.overlays = [ self.overlay ];

              #assertions = [
              #  {
              #    assertion = cfg.extraConfig != "" && cfg.settings != { };
              #    message = "The option `extraOptions` conflicts with `settings`. Use only one of them";
              #  }
              #];

              systemd.services.misskey = {
                description = "Misskey social platform";
                wantedBy = [ "multi-user.target" ];

                serviceConfig = mkMerge [
                  {
                    User = cfg.user;
                    Group = cfg.group;
                    WorkingDirectory = cfg.dataDir;
                    ExecStart = "${finalPackage}/bin/misskey";
                    Restart = "on-failure";
                  }
                  (mkIf (cfg.dataDir == "/var/lib/misskey") { StateDirectory = "misskey"; })
                ];
              };

              users.users = mkIf (cfg.user == "misskey") {
                misskey = {
                  isSystemUser = true;
                  group = cfg.group;
                  description = "Misskey system user";
                };
              };

              users.groups = mkIf (cfg.group == "misskey") { misskey = { }; };
            };
          };
      };

      checks = forAllSystems (system:
        with nixpkgsFor.${system};
        lib.optionalAttrs stdenv.isLinux {
          # A VM test of the NixOS module.
          vmTest = with import (nixpkgs + "/nixos/lib/testing-python.nix")
            {
              inherit system;
            };

            let
              test = makeTest {
                nodes = {
                  client = { config, pkgs, ... }: {
                    environment.systemPackages = [ pkgs.curl ];
                  };
                  misskey = { config, pkgs, ... }: {
                    imports = [ self.nixosModules.misskey ];
                    services.misskey.enable = true;
                    networking.firewall.allowedTCPPorts = [ 8000 ];
                  };
                };

                testScript = ''
                  start_all()
                  misskey.wait_for_unit("misskey.service")
                  misskey.wait_for_open_port("8000")
                  client.wait_for_unit("multi-user.target")
                  client.succeed("curl -sSf http:/misskey:8000/static/config.json")
                  misskey.succeed("cat ${test.nodes.misskey.config.services.misskey.configFile} >&2")
                  misskey.succeed("cat ${test.nodes.misskey.config.services.misskey.webircgateway.configFile} >&2")
                '';
              };
            in
            test;
        });
    };
}
