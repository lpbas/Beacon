# Beacon

Beacon is a native macOS menu bar app that re-broadcasts Bonjour/mDNS services on
your local network, so other devices can see services that Docker/OrbStack on
macOS will not relay, such as HomeKit bridges, Home Assistant, and more.

It is a GUI successor to the `homekit-mdns-broadcaster` script, rebuilt in pure
Swift on top of the system `dns_sd` API (the same daemon the `dns-sd` command
talks to). There is no Python and no spawning of `dns-sd` subprocesses, and you
get true per-service control.

## The problem it solves

Docker and OrbStack on macOS do not relay container mDNS advertisements to the
local network. Your Mac can see the services (for example with `dns-sd -B`), but
other devices on the LAN cannot. This breaks setups like Home Assistant running in
a container, where HomeKit and other devices need to discover the bridge over
mDNS.

Beacon resolves each service you whitelist on the host, then re-advertises it
through the host's own mDNSResponder so the whole network can see it. Background
on the underlying issue: https://github.com/orbstack/orbstack/issues/342

## Features

- Menu bar Status screen: see every whitelisted service with its live state, and
  start or stop each one individually or all at once.
- Discovery: browse the local network for services, resolve any of them to inspect
  host, port and TXT records, and add them to your whitelist with one click.
- Whitelist: add services manually or from Discovery, pause and resume them,
  reorder them, and delete them.
- Settings: choose which service groups and custom service types to scan, enable
  launch at login, set a start delay, and turn on periodic auto-refresh.
- Auto-refresh and network awareness: Beacon can periodically re-resolve running
  services and also reacts to network changes, so a container restart or a new IP
  address is picked up automatically.
- Pure native Swift, launch at login via `SMAppService`, and a design that keeps
  the door open to a future Mac App Store build.

## Requirements

- macOS 14 (Sonoma) or later.

## Installation

1. Download `Beacon-x.y.z.dmg` from the Releases page.
2. Open the DMG and drag Beacon into your Applications folder.
3. Launch Beacon. Its icon appears in the menu bar.
4. The first time Beacon uses the network, macOS asks for Local Network access.
   Allow it, otherwise discovery and broadcasting will not work.

Note on Gatekeeper: until a build is notarized, macOS may refuse to open it on
first launch. If that happens, right-click the app and choose Open, then confirm.
Notarized release builds open normally.

## Usage

1. Open the menu bar icon and choose Discover, or open the main window and select
   the Discovery tab.
2. Find the service you want to re-broadcast (for example your HomeKit bridge) and
   click the plus button to add it to the whitelist. Selecting a service shows its
   resolved host, port and TXT records.
3. On the Status screen, press play next to a service to start broadcasting it, or
   press Start All. You can also enable "Start broadcasting on launch" in Settings.
4. Other devices on your LAN can now see the service.

The instance name must match exactly what is on the network, as shown in Discovery
or by `dns-sd -B`. You can pause a service to keep it in the list without
broadcasting, or delete it entirely.

## Service groups

Beacon ships with the same service groups as the original script. The HomeKit
group is selected by default. You can toggle groups and add your own literal
service types in Settings.

| Group        | Description           | Example types                          |
| ------------ | --------------------- | -------------------------------------- |
| homekit      | HomeKit and Matter    | `_hap._tcp`, `_matter._tcp`            |
| web          | Web and remote access | `_http._tcp`, `_ssh._tcp`, `_rfb._tcp` |
| files        | File sharing          | `_smb._tcp`, `_afpovertcp._tcp`        |
| printing     | Printing and scanning | `_ipp._tcp`, `_printer._tcp`           |
| apple        | Apple devices         | `_airplay._tcp`, `_companion-link._tcp`|
| google       | Google and Cast       | `_googlecast._tcp`                     |
| iot          | Smart home / IoT      | `_shelly._tcp`, `_philipshue._tcp`     |
| media        | Media and streaming   | `_spotify-connect._tcp`, `_sonos._tcp` |
| dev          | Developer tools       | `_jenkins._tcp`, `_distcc._tcp`        |
| p2p          | Peer-to-peer          | `_bp2p._tcp`                           |
| enumeration  | Service enumeration   | `_services._dns-sd._udp`               |

## How it works

- Discovery uses `DNSServiceBrowse` for each selected service type.
- Resolving a service uses `DNSServiceResolve`, which returns the host, port and
  raw TXT record.
- Re-broadcasting uses `DNSServiceRegister` with the host set to NULL, so the SRV
  target points at the local machine. This is the key detail that makes the
  container reachable at the host's address, and it mirrors what `dns-sd -R` does.
- TXT records are round-tripped byte for byte, so the re-broadcast carries the same
  metadata as the original service.
- Registrations are withdrawn automatically when Beacon quits.

Settings and the whitelist are stored as JSON in
`~/Library/Application Support/Beacon/` (`settings.json` and `whitelist.json`).

## Importing from the original script

If you used `homekit-mdns-broadcaster` and have a `service_whitelist.txt`, open
Settings and choose "Import service_whitelist.txt". One name per line, and lines
starting with `#` are ignored, just like the script.

## Building from source

The Xcode project is generated from `project.yml` with XcodeGen, so the
`.xcodeproj` is not committed. Generate it first:

```bash
brew install xcodegen
xcodegen generate
open Beacon.xcodeproj
# or build from the command line:
xcodebuild -project Beacon.xcodeproj -scheme Beacon -configuration Debug build
```

### Self-test CLI

`SelfTest/` builds a small command line tool, `beacon-selftest`, that exercises the
dns_sd engine directly. It is useful for debugging and for comparing against the
system `dns-sd`:

```bash
beacon-selftest browse   _hap._tcp
beacon-selftest resolve  "My Service" _hap._tcp
beacon-selftest register "Test Service" _http._tcp 8080
beacon-selftest mirror   "My Service" _hap._tcp
```

## Releasing

```bash
# One-time notarization setup (stores an app-specific password in the keychain):
xcrun notarytool store-credentials "beacon-notary" \
    --apple-id "you@example.com" --team-id "<your-team-id>" \
    --password "<app-specific-password>"

# Build, sign with Developer ID, package a DMG, then notarize and staple:
scripts/release.sh 0.1.0
```

If the notary profile is not present, the script still produces a signed DMG and
skips notarization.

## Project structure

```
Beacon/
  BeaconApp.swift          App entry, menu bar and main window scenes
  LoginItem.swift          Launch at login via SMAppService
  Engine/                  dns_sd wrappers and the BroadcastEngine orchestrator
  Model/                   Service catalog, whitelist, settings, persistence
  UI/                      Status, Discovery, Whitelist, Settings, About
SelfTest/                  Command line harness for the engine
scripts/release.sh         Sign, package, notarize, staple
project.yml                XcodeGen project definition
```

## Roadmap

- App icon (the app currently uses a system symbol).
- Optional Mac App Store build (add the App Sandbox and network entitlements).

## Credit and license

Based on the original `homekit-mdns-broadcaster` script. Released under the MIT
License. See the LICENSE file.
