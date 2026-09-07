# tower

Vim/tmux-style fleet management TUI for Podman/Docker, k0s/Kubernetes, Hermes, and SSH.

Built with [Zig](https://ziglang.org/) 0.16 and [ZigZag](https://github.com/meszmate/zigzag).

## Build

```sh
mise install   # pins Zig 0.16.0
zig build
./zig-out/bin/tower
```

## Config

On first launch, tower writes `~/.config/tower/config.yaml` with a `local` host.

```yaml
hosts:
  - name: local
    kind: local
    container:
      engine: auto   # auto | podman | docker
      rootless: true
    kubeconfig: ~/.kube/config
    hermes:
      base_url: http://127.0.0.1:8642/v1
      api_key_env: HERMES_API_KEY
  - name: edge-1
    kind: ssh
    ssh:
      host: edge-1.example
      user: robin
      port: 22
    container:
      engine: podman
    hermes:
      base_url: http://127.0.0.1:8642/v1
      api_key_env: HERMES_API_KEY
```

## Keys

| Key | Action |
|-----|--------|
| `hjkl` / arrows | Navigate hosts / table |
| `g` / `G` | Top / bottom |
| `/` | Filter |
| `:` | Command (`:host`, `:ctx`, `:pods`, `:ssh`, `:hermes`, `:k0s`, …) |
| `Ctrl-b` `%` | SSH / local shell split |
| `Ctrl-b` `"` | Hermes chat split |
| `Ctrl-b` `d` | Close split |
| `i` | Inspect / logs |
| `d` / `x` | Stop / delete (confirm) |
| `r` | Refresh |
| `1`–`5` | Containers / images / volumes / networks / pods |
| `6`–`9` | k8s pods / nodes / deployments / k0s |
| `?` | Help |
| `q` | Quit |

## Layout

```
HOSTS │ resource table │ optional SSH / Hermes / detail pane
------+----------------+------------------------------------
status bar · :command / filter
```
