# Installing hawdl from a release tarball

This build is **unsigned and not notarized**. macOS attaches a quarantine
attribute to anything downloaded through a browser, and Gatekeeper will refuse
to run it until that attribute is cleared. From the unpacked directory:

```sh
xattr -dr com.apple.quarantine .
```

## 1. The command line tools

```sh
sudo install -m 755 hawdl hawdld /usr/local/bin/
```

## 2. The daemon

`hawdld` must run as root, because changing interface flags requires it.

To try it in the foreground:

```sh
sudo hawdld --verbose
```

To keep it running across reboots, install it as a LaunchDaemon. Write
`/Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.github.taross-f.hawdl.hawdld</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/hawdld</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/var/log/hawdld.log</string>
	<key>StandardErrorPath</key>
	<string>/var/log/hawdld.err.log</string>
</dict>
</plist>
```

Then:

```sh
sudo chown root:wheel /Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist
sudo chmod 644 /Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist
sudo launchctl load -w /Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist
```

## 3. The menu bar app

```sh
cp -R HawdlBar.app /Applications/
open /Applications/HawdlBar.app
```

`LSUIElement` is set, so it has no Dock icon and lives only in the menu bar.

The bundle in this tarball is already ad-hoc signed. If it does not appear in
the menu bar, check whether the signature survived the copy:

```sh
codesign --verify --deep --strict /Applications/HawdlBar.app
```

If that fails, re-sign it — macOS refuses to launch a bundle whose contents no
longer match its signature, and does so silently:

```sh
codesign --force --deep --sign - /Applications/HawdlBar.app
```

## Using it

```sh
hawdl status     # current state
hawdl hold       # keep awdl0 down
hawdl release    # stop holding, bring it back up
hawdl watch      # stream state changes
```

## Before you hold it down

While AWDL is held down, **AirDrop, Handoff, Sidecar, Universal Control and
Continuity Camera stop working**. `hawdl release` puts it back, and so does
stopping the daemon — `hawdld` always restores the interface before it exits.

## Uninstalling

```sh
sudo launchctl unload -w /Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist
sudo rm -f /Library/LaunchDaemons/com.github.taross-f.hawdl.hawdld.plist
sudo rm -f /usr/local/bin/hawdl /usr/local/bin/hawdld
rm -rf /Applications/HawdlBar.app
sudo rm -rf "/Library/Application Support/hawdl"
```

Confirm the interface came back:

```sh
ifconfig awdl0 | head -1   # the flags should include UP
```
