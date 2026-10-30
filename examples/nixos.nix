# Include this in your NixOS modules, with inputs passed via specialArgs.
{ inputs, pkgs, ... }:
{
  programs.direnv = {
    enable = true;
    package = inputs.direnv-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
    nix-direnv.enable = false;
    enableXonshIntegration = false;
    # The standard NixOS module handles Bash, Zsh and Fish hooks.
  };

  environment.variables = {
    DIRENV_NIX_ALLOW_DIRS = "/home/rok/src/git.internal:/home/rok/src/github.com/aca";
    # Set to "1" to allow every project instead.
    DIRENV_NIX_ALLOW_ALL = "0";
  };
}
