{
  description = "Banka-3-Infrastructure — kustomize + kubeconform + kubectl dev shell.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = {pkgs, ...}: {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # k8s + manifest tooling
            kubectl
            kustomize
            kubeconform

            # Argo CD CLI — for `argocd app sync raf-banka --core` etc.
            argocd

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
