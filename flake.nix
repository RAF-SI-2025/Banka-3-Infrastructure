{
  description = "Banka-3-Infrastructure — kustomize + kubeconform + kubectl dev shell.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    flake-parts,
    nixpkgs,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = {system, ...}: let
        # vault is BUSL-1.1 → marked unfree; whitelist it explicitly.
        pkgs = import inputs.nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) ["vault"];
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # k8s + manifest tooling
            kubectl
            kustomize
            kubeconform

            # Argo CD CLI — for `argocd app sync raf-banka --core` etc.
            argocd

            # Supply-chain — sign + verify image signatures
            cosign
            vault

            # YAML / JSON
            yq-go
            jq

            # Misc
            git
            curl
            go-task
          ];
        };
      };
    };
}
