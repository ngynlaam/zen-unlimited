# steam-warp — optional Steam launcher

`install.sh` copies `bin/steam-warp` when present. It uses the installed
`../lib/state.sh` and `../lib/auto.sh`. Steam must be installed separately.
The installer does not start Steam or change desktop entries.

## Usage

```sh
~/.local/share/warp-rotate/bin/steam-warp [--dry-run|--print-env] [--tcp|--udp] [--] [Steam arguments]
```

In the source tree, use `bin/steam-warp`. For a custom `BIN_DST`, use that
directory instead. `STEAM_BIN` selects the Steam executable (default `steam`).

| Detected mode | Environment and arguments |
|---|---|
| `proxy` | Sets upper- and lower-case HTTP/HTTPS proxy variables to `http://127.0.0.1:44444`, bypasses loopback, and adds `-tcp` by default. |
| `tunnel` | Clears proxy variables. Uses the system route, with no added `-tcp`. |

- `--udp` skips the default `-tcp`; `--tcp` adds it in either mode.
  An existing `-tcp` argument is not duplicated.
- `--dry-run` prints the selected environment and command without starting Steam.
- `--print-env` prints shell-quoted environment lines and a command description.
  Do not evaluate the complete output as a shell script.
- `STEAM_WARP_PROXY` and `STEAM_WARP_NO_PROXY` override the proxy URL and
  bypass list. `PROXY_PROBE_HOST` and `PROXY_PROBE_PORT` select the probe.

## Limits and safety

The launcher selects a mode from the shared cache or a TCP listener probe.
A missing listener is called `tunnel`, but it does **not** prove that WARP is
connected. Check your WARP setup separately. The launcher never calls
`warp-cli`, changes firewall rules, or changes system proxy settings.

The local proxy cannot carry UDP game, voice, or matchmaking traffic.
Setting HTTP proxy variables and `-tcp` does not prove that all Steam
components use the proxy. This repository does not establish tested Steam
versions or guaranteed Store/login support. A system WARP tunnel can carry
UDP only if your system route and WARP configuration allow it.

Do not change WARP mode during active requests. Such changes and automatic
daemon rotations can interrupt Steam and other applications. See the
[setup warning](../README.md#prerequisites-and-safety) before configuring WARP.

## Optional desktop entry

Find the Steam desktop file installed by your distribution or package.
Copy it into `~/.local/share/applications/`; do not edit the system file.
For example, if your system has `/usr/share/applications/steam.desktop`:

```sh
mkdir -p ~/.local/share/applications
cp /usr/share/applications/steam.desktop ~/.local/share/applications/steam.desktop
```

Edit the copy. Replace the executable in its main `Exec=` line with the
absolute path to the installed launcher. Keep the existing URL field code
and any required Steam arguments. Example (replace `YOUR_USER`):

```ini
Exec=/home/YOUR_USER/.local/share/warp-rotate/bin/steam-warp %U
```

Desktop entries do not expand `~` or `$HOME`. Quote the executable path if
it contains spaces. Review any desktop action `Exec=` lines separately.
Close an existing Steam process before checking a new launch environment.

## Inspect without starting Steam

```sh
~/.local/share/warp-rotate/bin/steam-warp --dry-run
```

This does not change WARP, but it can probe the local listener and update
the shared mode cache. It is not an isolated test or a route verification.
