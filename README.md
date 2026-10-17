# Squeezebox Remote control Home Assistant

Plugin for Lyrion Music Server that controls Home Assistant entities from the Apps menu.

## Requirements

- Lyrion Music Server **9.1+**
- Home Assistant with WebSocket API support for `extract_from_target` and `subscribe_entities` (HA **2025.x+** / tested with **2026.10**)

## Supports

- Lights on/off
- Switch on/off
- Cover open/close

## Tested on

- WEB
- Squeezebox DUET Controller
- Squeezebox Radio

## Known limitations

- Only handles Areas and the entities assigned to those Areas (light, switch, cover).
- Uses a bundled WebSocket client (`SimpleAsyncWS`); handshake is briefly blocking.
- Menu images priority: `entity_picture` → MDI `icon` (offline: bundled path data in `share/mdi-paths.json` from [Material Design Icons](https://pictogrammers.com/library/mdi/) Apache-2.0 + local PNG rasterizer, tinted by state; uses system `rsvg-convert`/`ImageMagick` when available for sharper results) → plugin domain/state PNGs. No outbound calls for MDI icons.
- Layout follows LMS 9.1 plugin practice: `Plugin.pm` (OPML lifecycle), `API.pm` (HA WebSocket), `Images.pm` / `Mdi.pm` (ImageProxy + offline icons), `Handlers.pm`, `Settings.pm`, hardened `SimpleAsyncWS.pm` fork (stock `SimpleWS` calls `exit` on error).


## Configuration

1. Set the Home Assistant URL (same as web UI), e.g. `http://homeassistant.local:8123/`
2. Create a long-lived access token in Home Assistant (Profile → Long-Lived Access Tokens)
3. Enable the plugin (saving settings fully restarts the connection)

## Installation

Server plugin repository URL `https://hans99.github.io/slim/repo.xml`

### Build plugin zip

```bash
./build.sh
```

Creates `dist/Assistant-<version>.zip` (version from `install.xml`) with an `Assistant/` root folder for LMS Plugins, and prints the SHA1 for `repo.xml`.

License information is found in the LICENSE file.
