{
  description = "Development environment for jira-oil.nvim demos";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import nixpkgs { inherit system; };
          }
        );
    in
    {
      devShells = forAllSystems (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              neovim
              vhs
              ffmpeg
              asciinema
              jq
              git
              bashInteractive
              coreutils
            ];

            shellHook = ''
              echo "Demo shell ready. Run: vhs demo/record.tape"
            '';
          };
        }
      );

      apps = forAllSystems (
        { pkgs }:
        {
          record-demo = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "record-demo";
                runtimeInputs = [ pkgs.vhs ];
                text = ''
                  exec vhs demo/record.tape
                '';
              }
            }/bin/record-demo";
          };
        }
      );
    };
}
