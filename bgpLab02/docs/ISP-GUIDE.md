# Provider Service Guide (ispA AS 65010, ispB AS 65020)

Both providers run the same policy. Replace `<asn>` with 65010 (ispA) or 65020 (ispB).

| Item | Behavior |
|---|---|
| Sessions | One eBGP session per VRF per border, on 802.1Q subinterfaces (101 RED, 102 BLUE) |
| Sent to you | Default route (`default-originate`) plus 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24 |
| Accepted from you | 10.10.0.0/16 and 10.30.0.0/16, prefixes up to /24 |
| Customer local-pref | 200 (beats routes from inet at 100) |
| `<asn>:80` | Sets your route to local-pref 80 inside the provider (below inet). Use to make a provider your backup. |
| `<asn>:903` | Provider prepends its own ASN 3x toward inet |
| `<asn>:666` | RTBH. Accepted on /32 only. Next hop set to a discard route, tagged no-export. |
| Max prefixes | 100 per session |
| MED | Honored between your two borders (same neighbor AS, default comparison) |
| BFD | Enabled on provider side at 300 ms x 3. Comes up when you enable it. |
| Communities | You must send them. The provider does nothing with what it never receives. |
