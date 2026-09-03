# Vendor definitions

One JSON file per vendor. Every file here is merged into the app's bundled
default list at build time by `Scripts/merge-vendors.sh`, in filename order.

To add a vendor, copy an existing file, change the fields, and open a pull
request. Run `Scripts/merge-vendors.sh vendors /tmp/vendors.json` to check that
your file validates.

Fields:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Lowercase identifier, unique, no spaces. |
| `name` | yes | Display name. |
| `platform` | yes | `statuspage`, `incidentio` or `feed`. |
| `baseURL` | yes | The status page origin, no trailing slash. |
| `incidentURL` | no | Where to send the user for details. Defaults to `baseURL`. |
| `feedURL` | for `feed` | The RSS or Atom URL. Ignored for other platforms. |
| `enabled` | no | Defaults to `true`. |
| `probes` | no | Array of probe objects, see below. |
| `notes` | no | Free text shown nowhere, for maintainers. |

Probe objects:

- `{ "type": "https_head", "url": "https://api.example.com/" }`
- `{ "type": "tcp", "host": "example.com", "port": 443 }`
- `{ "type": "dns", "host": "example.com", "resolver": "1.1.1.1" }` (resolver is optional)
