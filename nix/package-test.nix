{
  self,
  nixpkgs,
  pkgs,
  system,
}:
let
  lib = nixpkgs.lib;
  eval =
    extra:
    (lib.nixosSystem {
      inherit system;
      specialArgs.inputs.direnv-nix = self;
      modules = [
        ../examples/nixos.nix
        { system.stateVersion = "26.05"; }
        extra
      ];
    }).config;
  cfg = eval { };
  bashOff = eval { programs.direnv.enableBashIntegration = false; };
  package = self.packages.${system}.default;
  executable = builtins.unsafeDiscardStringContext (lib.getExe package);
in
assert executable == "${package}/bin/direnv";
assert cfg.programs.direnv.package == package;
assert lib.elem package cfg.environment.systemPackages;
assert cfg.environment.variables.DIRENV_NIX_ALLOW_ALL == "0";
assert
  cfg.environment.variables.DIRENV_NIX_ALLOW_DIRS
  == "/home/rok/src/git.internal:/home/rok/src/github.com/aca";
assert !cfg.programs.direnv.nix-direnv.enable;
assert !cfg.programs.direnv.enableXonshIntegration;
assert lib.hasInfix "${executable} hook bash" cfg.programs.bash.interactiveShellInit;
assert lib.hasInfix "${executable} hook zsh" cfg.programs.zsh.interactiveShellInit;
assert lib.hasInfix "${executable} hook fish" cfg.programs.fish.interactiveShellInit;
assert !(lib.hasInfix "${executable} hook bash" bashOff.programs.bash.interactiveShellInit);
pkgs.runCommand "direnv-nix-nixos-package-check" { } ''
  touch "$out"
''
