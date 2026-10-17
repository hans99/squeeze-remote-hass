#### Version 0.12
##### Changed
- Prefer Home Assistant `entity_picture` for menu images via authenticated ImageProxy (Bearer token)
- Render HA `mdi:…` icons fully offline: bundled MDI path DB (`share/mdi-paths.json`) + local SVG-path→PNG rasterizer (`Mdi.pm`); optional system `rsvg-convert`/`magick`/`convert` if present; fall back to domain/state PNGs
- Tint MDI icons by entity state (HA-style amber active / blue-gray inactive / gray unavailable)
- Pass decoded Home Assistant payloads as Perl structures (no double JSON encode)
- Single `subscribe_entities` for all entities after menu build
- Expand groups when resolving area entities (`expand_group` as JSON bool)
- Register as LMS app (`is_app`)
- Default to disabled until configured (`install.xml` + prefs)
- Hide empty areas; sort areas and entities
- Update entity display names when Home Assistant renames them
- Unsubscribe HA entity subscriptions on stop
- Settings validate URL/token and show connection status
- Split image/ImageProxy helpers into `Images.pm` (Plugin.pm stays lifecycle + OPML)
- Logger default level `ERROR` (stock plugin practice)
- `install.xml` targetApplication id set to `Lyrion Music Server`

##### Fixed
- Localized status messages in the Apps menu feed
- Robust WebSocket JSON decode (UTF-8 octets vs Unicode strings)
- Avoid "Token not set or no connection" race on LMS start (keep connecting until auth finishes; ignore stale auth_required; require token before opening the socket)
- Assign WebSocket object before handshake so HA `auth_required` is answered in time (prevents ~10s remote close on LMS start)
- Harden WebSocket close/error path (no write-on-closed disconnect; no cascaded read-error logs)
- Apply cleared HA `icon` / removed-entity image updates correctly

#### Version 0.11
##### Fixed
- WebSocket connect failures no longer continue on a dead socket
- Proper cleanup and reconnect after remote disconnect / read errors
- Safe start/stop without re-registering the app menu
- Plugin disable/uninstall cleans timers, pending callbacks, and websocket
- Cover opening/closing mapped to open/closed icons and actions
- Auth starts menu build after `auth_ok`; invalid token does not loop reconnect
- On disable/uninstall, remove SqueezePlay/Jive and Material Skin "pin to home screen" entries if present
- Saving settings always fully restarts the plugin (stop WebSocket/menu, then start again if enabled)

##### Changed
- Settings copy refers to long-lived access token

#### Version 0.10
##### Changed
- Now using websocket to Home Assistant
- Only handles Entities assigned to Areas, first menu is select Area

#### Version 0.9
##### Update
- Failed fix to handle auth

#### Version 0.8
##### Added
- Add entity to handle group with common domain

#### Version 0.7
##### Fixed
- Settings info example proper url

#### Version 0.6
##### Added
- Support for switch
- Support for cover open/close

#### Version 0.5
##### Added
- Group status pics
##### Changed
- From toggle light to on/off
- New pics
##### Fixed
- Menu ordering
