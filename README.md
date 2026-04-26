# multiplayer-fabric-meta

Meta XR Simulator OpenXR runtime configuration for the multiplayer-fabric Quest 3 macOS smoke test.

## Goal

Minimum smoke test pass condition: Godot player scene initialises an OpenXR
session via Meta XR Simulator on macOS, connects to the zone server, and sends
one CH_PLAYER datagram (server ACKs).

## What is Meta XR Simulator

[Meta XR Simulator](https://developers.meta.com/horizon/documentation/unity/xrsim-intro/)
is Meta's official OpenXR runtime for desktop development. It registers itself
as the active OpenXR runtime on macOS, presenting a simulated Quest 3 headset
and controllers — no headset required. Tracking, hand input, and passthrough
are approximated.

## Setup on macOS

### Install

Download from the Meta Developer portal:
<https://developers.meta.com/horizon/downloads/package/meta-xr-simulator/>

Run the installer — it registers itself as the system OpenXR runtime
automatically (writes `~/Library/Application Support/...openxr_meta...json`).

### Verify the runtime is active

```sh
cat "$HOME/Library/Application Support/openxr/1/active_runtime.json"
```

Should point to the Meta XR Simulator manifest.

### Run the Godot player scene

```sh
godot --path /path/to/multiplayer-fabric-godot \
  --scene scenes/observer.tscn
```

Confirm in the Godot console:

- Meta XR runtime appears in the XR server list
- `XRServer.find_interface("OpenXR")` returns non-null
- `send_player_input()` fires and the zone server ACKs

## Zone server

Start the zone server before running the player scene:

```sh
godot --headless --path /path/to/multiplayer-fabric-godot \
  scenes/zone_server.tscn
```

Default: `127.0.0.1:7443` (WebTransport / UDP).

## Compared to Monado

| | Meta XR Simulator | Monado |
|---|---|---|
| Source | Proprietary (Meta) | Open source |
| Quest 3 fidelity | High — same vendor | Low — generic simulated HMD |
| macOS install | Installer from Meta portal | `brew install monado` |
| Hand tracking sim | Yes | Partial |
| Recommended for | Quest 3 target testing | Generic OpenXR API smoke tests |

See also: [multiplayer-fabric-monado](https://github.com/V-Sekai-fire/multiplayer-fabric-monado)

## References

- [20260425-godot-player.md](https://github.com/V-Sekai-fire/multiplayer-fabric/blob/main/manuals/decisions/20260425-godot-player.md) — player design
- [SOMEDAY.md](https://github.com/V-Sekai-fire/multiplayer-fabric/blob/main/SOMEDAY.md) — smoke test pass condition
- Meta XR Simulator docs: <https://developers.meta.com/horizon/documentation/unity/xrsim-intro/>
