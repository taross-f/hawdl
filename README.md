# hawdl

Keep macOS's `awdl0` interface down, and keep it that way.

*[日本語版 README](README.ja.md)*

`awdl0` (Apple Wireless Direct Link) time-shares the same radio as Wi-Fi. Leaving
it up costs you throughput and adds latency spikes. `sudo ifconfig awdl0 down`
takes it down, but macOS puts it straight back up whenever AirDrop, Handoff or
Sidecar wants it — and again on every wake from sleep.

hawdl doesn't take it down once. It **holds it down**.

```
┌─────────────┐     ┌──────────┐
│ HawdlBar.app│     │ hawdl CLI│   ← user
└──────┬──────┘     └────┬─────┘
       └────────┬────────┘
         Unix domain socket
         /var/run/hawdl.sock
                │
         ┌──────▼──────┐
         │   hawdld    │              ← root (LaunchDaemon)
         │  PF_ROUTE watch             │
         │  SIOCSIFFLAGS to drop it    │
         │  desired state persisted    │
         └─────────────┘
```

Everything needing root lives in the daemon, so the GUI and the CLI never ask
you for a password.

---

## ⚠️ What this breaks — read first

While AWDL is held down, these **stop working**:

- AirDrop
- Handoff / Universal Clipboard
- Sidecar
- Universal Control
- Continuity Camera / Continuity Markup
- Peer-to-peer AirPlay

Need one of them back? `hawdl release`, or *AWDL を再開* from the menu bar.
Stopping `hawdld` also restores the interface automatically.

### Disclaimer

Poking at `awdl0` directly is **not supported by Apple**. A macOS update could
change the behaviour or break this outright. MIT licensed, **no warranty**. Use
at your own risk.

---

## Screenshots

<!-- TODO: replace with a shot of the open menu bar item at docs/menu.png -->
![The HawdlBar menu](docs/menu.png)

<!-- TODO: replace with a shot or asciinema of `hawdl watch` at docs/watch.png -->
![hawdl watch](docs/watch.png)

---

## Install

### From a release build

Each tag publishes a universal tarball (Apple Silicon and Intel) containing
`hawdl`, `hawdld` and `HawdlBar.app`. Download it from
[Releases](https://github.com/taross-f/hawdl/releases), then:

```sh
tar xzf hawdl-<version>-macos-universal.tar.gz
cd hawdl-<version>-macos-universal
xattr -dr com.apple.quarantine .
```

**These builds are unsigned and not notarized**, so macOS quarantines them on
download and Gatekeeper blocks them until that attribute is cleared. The
tarball's `INSTALL.md` covers the rest, including the LaunchDaemon plist.

### From a personal tap

```sh
brew tap taross-f/hawdl
brew install --HEAD taross-f/hawdl/hawdl
```

> The formula is head-only for now, so `--HEAD` is required; it becomes
> unnecessary once there is a tagged release. It lives in
> [taross-f/homebrew-hawdl](https://github.com/taross-f/homebrew-hawdl), not in
> this repository, so there is only one copy to keep current.

**Starting the daemon is mandatory.** Without it, neither `hawdl` nor HawdlBar
has anything to talk to:

```sh
sudo brew services start hawdl
```

`sudo` is required because changing interface flags needs root. Homebrew
registers it as a LaunchDaemon under `/Library/LaunchDaemons`, so it comes back
on reboot.

### The menu bar app

The formula assembles `HawdlBar.app` inside the Homebrew prefix. **The required
step is launching it** — nothing launches it for you, and until it is running
there is no menu bar item, which looks exactly like the app failing to install:

```sh
open "$(brew --prefix hawdl)/HawdlBar.app"
```

A bundle runs from wherever it lives, so that is enough on its own. Linking it
into `/Applications` is optional convenience — it puts the app in Spotlight and
Launchpad and gives it a sane entry under System Settings -> General -> Login
Items — but it is not what makes it launch:

```sh
ln -sfn "$(brew --prefix hawdl)/HawdlBar.app" /Applications/HawdlBar.app
```

Homebrew formulae cannot write to `/Applications` themselves: `brew install`
runs sandboxed and may only write inside its own prefix. Shipping the app as a
Cask instead would put it there, but a Cask installs a *downloaded* artifact,
which macOS quarantines — and this app is unsigned, so Gatekeeper would then
refuse to open it. Building locally is what keeps the quarantine attribute off.

`LSUIElement` is set, so there is no Dock icon — it lives only in the menu bar.

### From source

```sh
git clone https://github.com/taross-f/hawdl.git
cd hawdl
swift build -c release
swift test
```

Requires macOS 14 (Sonoma) or later and Swift 5.9+. Zero external package
dependencies.

`hawdl` and `hawdld` can be run straight out of `.build/release`. The menu bar
app cannot: SwiftPM only emits a bare executable, and `MenuBarExtra` needs a
real bundle for `LSUIElement` to apply. Assemble one:

```sh
mkdir -p HawdlBar.app/Contents/MacOS
cp .build/release/HawdlBar HawdlBar.app/Contents/MacOS/
cp Sources/HawdlBar/Resources/Info.plist HawdlBar.app/Contents/
codesign --force --deep --sign - HawdlBar.app
open HawdlBar.app
```

**The `codesign` step is not optional.** `swift build` ad-hoc signs the bare
executable; adding `Info.plist` afterwards changes the bundle out from under
that signature, and macOS then refuses to launch it — with no error and no menu
bar item, which looks exactly like the app doing nothing. `codesign --verify
--deep --strict HawdlBar.app` tells you whether a bundle is in that state.

---

## Updating

### From the tap

`brew upgrade` on its own will **never** update this. The formula is head-only,
and Homebrew does not check upstream for a HEAD install unless asked to — it
reports the package as up to date indefinitely:

```sh
brew update                                     # pull the latest formula
brew upgrade --fetch-HEAD taross-f/hawdl/hawdl  # --fetch-HEAD is not optional
```

`brew reinstall taross-f/hawdl/hawdl` is the blunter equivalent: it always
rebuilds from current HEAD, changed or not.

Neither of them restarts anything. Until you do, the daemon and the menu bar
app are both still running the previous binaries:

```sh
sudo brew services restart hawdl
pkill -x HawdlBar && open "$(brew --prefix hawdl)/HawdlBar.app"
```

**Restarting the daemon brings awdl0 back up for a moment.** That is deliberate,
not a bug: `hawdld` always restores the interface before exiting, and the new
process then reads `state.json` and re-applies the hold. A hold survives the
upgrade — AirDrop and friends just work for a second or two in the gap.

A `/Applications/HawdlBar.app` made with `ln -sfn` points at the opt prefix,
which is stable across versions, so it keeps working. One made with `cp -R`
does not: it still holds the old build.

### From a release build

The tarball has no updater. Replace the pieces and reload:

```sh
tar xzf hawdl-<version>-macos-universal.tar.gz
cd hawdl-<version>-macos-universal
xattr -dr com.apple.quarantine .

sudo launchctl unload -w /Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist
sudo install -m 755 hawdl hawdld /usr/local/bin/
sudo launchctl load -w /Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist

pkill -x HawdlBar
rm -rf /Applications/HawdlBar.app
cp -R HawdlBar.app /Applications/
open /Applications/HawdlBar.app
```

`/Library/Application Support/hawdl/state.json` is left alone, so a hold
survives. Re-check the plist in the tarball's `INSTALL.md` if the daemon's
arguments changed between versions.

### Checking what is actually running

```sh
hawdl --version    # the CLI you just installed
hawdl status       # reports the running daemon's version
```

If `hawdl status` shows an older `daemon=` than `hawdl --version`, the daemon
was not restarted. The menu bar app has no version display; if in doubt, quit
and relaunch it.

---

## Usage

```
hawdl status     print the current state and exit
hawdl hold       keep awdl0 down until released
hawdl release    stop holding and bring awdl0 back up
hawdl watch      stream state changes until interrupted

  --socket <path>   control socket (default: /var/run/hawdl.sock)
  --json            print raw protocol JSON instead of prose
  --version / --help
```

```console
$ hawdl hold
AWDL: held down  blocked=0  daemon=0.1.0

$ hawdl status
AWDL: held down  blocked=12  last=2025-09-07T10:23:45Z  daemon=0.1.0

$ hawdl watch
AWDL: held down  blocked=12  last=2025-09-07T10:23:45Z  daemon=0.1.0
AWDL: held down  blocked=13  last=2025-09-07T10:24:02Z  daemon=0.1.0
```

Exit codes: `0` ok, `1` error, `2` bad arguments, `3` cannot reach `hawdld`.

### Menu bar

| Icon | Meaning |
| --- | --- |
| `antenna.radiowaves.left.and.right.slash` | Holding (awdl0 is down) |
| `antenna.radiowaves.left.and.right` | Released (awdl0 is up) |
| `exclamationmark.triangle` | Not connected to `hawdld`, or awdl0 is absent |

Deliberately not the `wifi` family. `wifi.slash` is the glyph macOS uses for
*Wi-Fi is off*, and holding awdl0 down does not turn Wi-Fi off — the icon must
not imply it does. Plain `wifi` is the same glyph as the system Wi-Fi menu item
a few pixels away. If a symbol turns out to be unavailable, the app logs it and
falls back to the `wifi` glyph it replaces, because an invisible menu bar item
is worse than a misleading one.

The menu shows the current state and offers a hold/release toggle, a *launch at
login* switch (`SMAppService`), and the daemon's status. With the daemon not
running it does not crash: it retries every 3 seconds and tells you what to run.

> The menu bar UI is in Japanese. Interface language is tracked as a separate
> concern from this README.

---

## How it works

- **PF_ROUTE is the primary signal.** The daemon subscribes to `RTM_IFINFO`, so
  it reacts the instant AirDrop raises the interface. It does not poll.
- **A 30 second reconcile timer** runs as a safety net. If an event is ever
  missed, the worst case is 30 seconds of drift.
- **Interface changes go through ioctl**, not a subprocess: `SIOCGIFFLAGS` /
  `SIOCSIFFLAGS` flip `IFF_UP` directly. Spawning `ifconfig` per event is both
  slow and fragile to parse, and the flap loop can fire many times a second
  while AirDrop is opening.
- **Flap protection.** Five unwanted `up` events inside 10 seconds trigger
  exponential backoff (1s → 2s → 4s … capped at 30s), so the daemon never burns
  a core losing a fight with the OS. A storm only ends once the interface has
  been quiet for a full window *plus* the last delay imposed — a plain sliding
  window is not enough, because once the delay outgrows the window the counter
  empties and the daemon drops straight back into fast retries.
- **The desired state is persisted** to
  `/Library/Application Support/hawdl/state.json` and restored on start, so a
  hold survives a reboot.
- **Exit always restores the interface.** On SIGTERM or SIGINT the daemon brings
  `awdl0` back up before exiting, so a dead daemon never leaves you without
  AirDrop.
- **No `awdl0`, no problem.** On a machine without the interface the daemon
  reports `unavailable` and idles instead of failing.

---

## Security note

**`/var/run/hawdl.sock` is mode 0666**, which means **any local user on this
machine can toggle `awdl0`**. Nothing is reachable remotely, but on a shared Mac
or one with guest accounts, another user can disable your AirDrop — or release
your hold.

This is a deliberate trade-off so the menu bar app never has to ask for `sudo`.
A TODO to restrict the socket to the `admin` group (`root:admin`, 0660) is left
in `Sources/HawdlCore/IPCServer.swift`.

The daemon itself runs as root, but the only thing it exposes is a single
operation: read and write `IFF_UP` on one interface. There is no arbitrary
command execution and no way to name a different interface over the socket.

---

## IPC protocol

Newline-delimited JSON over `/var/run/hawdl.sock`. One message per line.

Requests:

```json
{"cmd": "status"}
{"cmd": "hold"}
{"cmd": "release"}
{"cmd": "subscribe"}
```

Response / push:

```json
{"actual":"down","available":true,"daemonVersion":"0.1.0","desired":"hold","flapCount":12,"lastFlapAt":"2025-09-07T10:23:45Z"}
```

| Field | Meaning |
| --- | --- |
| `desired` | `hold` / `release` — what the user asked for |
| `actual` | `up` / `down` / `unavailable` / `unknown` — what `awdl0` is doing |
| `available` | Whether `awdl0` exists on this machine (`actual != "unavailable"`) |
| `flapCount` | How many times the OS raised the interface while holding |
| `lastFlapAt` | Most recent flap (ISO 8601, UTC). Omitted entirely if there has never been one |
| `daemonVersion` | `hawdld`'s version |

`subscribe` keeps the connection open and pushes a new line on every change.

```sh
# nc speaks it too
echo '{"cmd":"status"}' | nc -U /var/run/hawdl.sock
```

---

## Uninstall

```sh
# 1. Stop the daemon (this brings awdl0 back up)
sudo brew services stop hawdl

# 2. Confirm it actually came back
ifconfig awdl0 | head -1
#   awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1484
#                  ^^ UP should be present

# 3. Quit HawdlBar, and remove the symlink if you made one
rm -f /Applications/HawdlBar.app

# 4. Uninstall
brew uninstall hawdl
brew untap taross-f/hawdl

# 5. Remove the leftover state file
sudo rm -rf "/Library/Application Support/hawdl"
```

If `UP` is missing, `sudo ifconfig awdl0 up` restores it by hand. If you added
HawdlBar as a login item, remove it under System Settings → General → Login
Items.

---

## Development

```sh
swift test                    # HawdlCore unit tests plus the IPC integration tests
swift build -c release
```

The tests need neither root nor a real `awdl0`. Interface access sits behind the
`InterfaceController` protocol, and the tests inject `FakeInterfaceController`.

To exercise the daemon's logic without root:

```sh
.build/debug/hawdld --dry-run --socket /tmp/hawdl.sock --state /tmp/hawdl-state.json --verbose
.build/debug/hawdl status --socket /tmp/hawdl.sock
```

To verify against real hardware — watch it drop the interface the moment AirDrop
opens:

```sh
sudo .build/debug/hawdld --verbose
# in another terminal
.build/debug/hawdl hold
.build/debug/hawdl watch
# → open AirDrop: flapCount climbs and awdl0 goes straight back down
```

### Layout

| Target | Contents |
| --- | --- |
| `HawdlCore` | State machine, backoff, IPC protocol and sockets, state persistence, interface abstraction |
| `CHawdlSys` | C shim. `SIOCGIFFLAGS` / `SIOCSIFFLAGS` come from the `_IOWR()` macros and cannot be imported into Swift, `ioctl(2)` is C-variadic, and `struct ifreq`'s anonymous union does not import reliably. Not an external dependency — part of this package |
| `hawdld` | The LaunchDaemon: PF_ROUTE watching, timers, signals, socket server wiring |
| `hawdl` | The CLI |
| `HawdlBar` | SwiftUI `MenuBarExtra` menu bar app |

**A process hosting an `IPCServer` must ignore SIGPIPE**, as `hawdld` does in
`run()`. Sockets get `SO_NOSIGPIPE` where possible, but that call itself fails
when the peer has already hung up before `accept` returns — which is exactly the
connection whose reply then raises the signal. Darwin has no per-write
`MSG_NOSIGNAL`, so process-level disposition is the only complete answer.

---

## License

MIT. See [LICENSE](LICENSE).
