# HPE demo brand assets

`setup-demo.sh` reads these files and stores them in the theme record as base64
data URIs. The theme backend has no upload endpoint, so the bytes are the
payload; keep the files small.

| File | Theme field | Notes |
| --- | --- | --- |
| `hpe-logo-navbar.png` | `logoNavbar` | White wordmark. The chat navbar paints `color-secondary` behind it, so the dark original is unreadable there. |
| `hpe-logo-header.png` | `logoHeader` | Original dark wordmark for light surfaces. |
| `hpe-favicon.png` | `favicon` | 64×64 HPE green element mark, rendered from `hpe-mark.svg`. |
| `hpe-logo.svg` | — | Source wordmark, from Wikimedia Commons. |
| `hpe-mark.svg` | — | Source for the favicon. |

Regenerate the raster files after changing a source SVG:

```bash
rsvg-convert -w 800 -o hpe-logo-header.png hpe-logo.svg
sed 's/fill:#040404/fill:#ffffff/g' hpe-logo.svg | rsvg-convert -w 480 -o hpe-logo-navbar.png
rsvg-convert -w 64 -h 64 -o hpe-favicon.png hpe-mark.svg
```

The HPE wordmark is a Hewlett Packard Enterprise trademark and is used here for
an HPE-hosted trial of Unique. Confirm brand-usage terms before reusing these
files in another deployment.
