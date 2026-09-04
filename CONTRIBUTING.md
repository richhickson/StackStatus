# Contributing

Thanks for helping. The most useful contribution is a vendor definition.

## Adding a vendor

1. Find the vendor's public status page and work out its platform. In the app,
   Settings, Vendors, Add vendor, paste the URL and press Detect: it tries
   incident.io, then Atlassian Statuspage, then common feed paths.
2. Copy an existing file in `vendors/` (the closest platform) to
   `vendors/<id>.json`, where `<id>` is lowercase with no spaces. The schema is
   in `vendors/README.md`.
3. Add one or two probes that prove the service itself is up: an HTTPS HEAD
   against the API host is ideal, since any response below 500 counts.
4. Check it validates:

   ```sh
   Scripts/merge-vendors.sh vendors /tmp/vendors.json
   ```

5. Run the app once from Xcode and confirm the vendor shows a sensible state,
   or use `StackStatus.app/Contents/MacOS/StackStatus --once` from a terminal.
6. Open a pull request. Say which platform you found and paste the output of
   `curl -sI <base>/api/v2/status.json` or the equivalent so the reviewer can
   see the endpoint really exists.

Bundled vendors are merged in filename order at build time. Users who already
have a vendors.json keep their list; new bundled vendors appear under
Settings, Vendors, Add bundled.

## Code changes

- macOS 14, Swift 5.9 or later, Xcode 15 or later. No third party dependencies.
- The Xcode project is generated from `project.yml` with XcodeGen. If you add
  files, run `xcodegen generate` and commit the regenerated project.
- `xcodebuild test` must pass. CI runs it on every push and pull request.
- No em dashes anywhere in the README, the app copy, or code comments. CI
  checks this.
- Nothing may send anything off the machine except GET and HEAD requests to
  status pages and probe targets. Keep it that way.

## Simulating an incident

`Scripts/fixture-server.py` serves a fake Atlassian Statuspage on
`http://127.0.0.1:8099`. Add it as a vendor, then:

```sh
curl http://127.0.0.1:8099/_set/minor      # two polls later: one notification
curl http://127.0.0.1:8099/_set/none       # two polls later: one resolved notification
curl http://127.0.0.1:8099/_set/critical   # notifies on the next poll
```

Set the poll interval to 2 minutes while you do this, or use Refresh now in the
popover to drive polls by hand.
