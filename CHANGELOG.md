# Changelog

## 0.1.0

First release.

- Atlassian Statuspage, incident.io and generic RSS or Atom adapters.
- Bundled vendors: Anthropic, Cloudflare, GitHub, Microsoft 365, OpenAI.
- HTTPS HEAD, TCP and DNS probes per vendor, plus gateway, DNS and internet
  baseline checks, combined into a "them, me, or the internet" verdict.
- Notifications on incident start, escalation and resolution only, with a two
  poll debounce, immediate for major outages, and quiet hours.
- Adaptive polling: 2 minutes during an incident, three times the interval on
  battery, paused during sleep.
- Conditional requests with ETags, Retry-After and exponential backoff.
- Settings window with vendor management, platform detection and probes.
