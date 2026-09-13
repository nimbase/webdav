<p align="center">
  <strong>webdav</strong><br>
  WebDAV Class 1 + 2 and CalDAV/CardDAV core for Nim<br>
  Made with the PowPow event library
</p>

<p align="center">
  <code>nimble install webdav</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/webdav/">API reference</a><br>
  <img src="https://github.com/nimbase/webdav/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/webdav/workflows/docs/badge.svg" alt="Github Actions">
</p>

WebDAV file sharing plus calendar and contact hosting in one embeddable server.
It runs on [PowPow](https://github.com/openpeeps/powpow) (async event loop,
HTTP/1 + HTTP/2), stores data through any
[flysystem](https://github.com/openpeeps/flysystem) driver, and parses
iCalendar and vCard via [openparser](https://github.com/openpeeps/openparser).
The extra HTTP verbs (`PROPFIND`, `LOCK`, `REPORT`, ...) are registered at
compile time through [voodoo](https://github.com/nimbase/voodoo) extensible
enums, so `powpow` itself stays generic.

> Import rule: `import webdav` must come before any direct `import powpow`,
> so the DAV verbs are staged before powPow compiles.

## Features

**WebDAV Class 1 (RFC 4918)**

- `OPTIONS` (advertises `DAV: 1, 2`), `GET`, `HEAD`, `PUT`, `DELETE`
- `MKCOL`, `PROPFIND` (`allprop`/`propname`/`prop`), best-effort `PROPPATCH`
- `COPY` / `MOVE` with `Destination` + `Overwrite` handling
- Live properties (`resourcetype`, `getetag`, `getcontentlength`,
  `displayname`, `getlastmodified`, ...) and namespaced dead properties
  that round-trip and travel across `COPY`/`MOVE`
- Hardened XML input (depth and node caps, `422` on malformed bodies)

**WebDAV Class 2 locking (RFC 4918)**

- `LOCK` / `UNLOCK` with exclusive and shared scopes, depth `0`/`infinity`
- `Timeout`, `Lock-Token`, and an `If` header subset (untagged + tagged
  groups, `Not`)
- `423 Locked` enforcement on modifying methods, live `lockdiscovery`

**CalDAV core (RFC 4791)**

- `MKCALENDAR` with optional `<set><prop>` defaults
- `REPORT` `calendar-query` (comp-filter + `time-range`) and
  `calendar-multiget`, returning `getetag` + `calendar-data`
- Recurrence expansion subset (`DAILY`/`WEEKLY`/`MONTHLY`/`YEARLY`,
  `INTERVAL`, `COUNT`, `UNTIL`, weekly `BYDAY`, `EXDATE`)
- `PUT` gate: resources inside a calendar must hold iCalendar object data
- `getctag` change tags and `supported-report-set` on calendars

**CardDAV core (RFC 6352)**

- Extended `MKCOL` with `<resourcetype><collection/><addressbook/></resourcetype>`
  creates addressbook collections (plain `MKCOL` unchanged, `415` for other bodies)
- `REPORT` `addressbook-query` (`prop-filter` + `param-filter` + `text-match` +
  `is-not-defined`, `test="anyof|allof"`, `negate-condition`, `limit/nresults`),
  `addressbook-multiget`, and `sync-collection` (RFC 6578, ctag-based tokens),
  returning `getetag` + `address-data`
- `address-data` negotiation: `version="3.0"` downgrades via openparser,
  other `content-type` than `text/vcard` answers `415`
- `PUT`/`COPY`/`MOVE` gates: exactly one vCard per resource, UID uniqueness
  (`409` on reuse or UID change)
- `getctag` change tags, `supported-report-set` and `supported-address-data`
  on addressbooks, `addressbook-description` dead-prop default via extended `MKCOL`
- `GET` on `.vcf` serves `text/vcard`

**Plumbing**

- Any flysystem `StorageDriver` backend (`LocalDriver` on disk,
  `MemoryDriver` for tests)
- Single-loop friendly: lazy lock expiry, no background threads

**Client (RFC 4918 + CalDAV/CardDAV reports)**

- `DavClient` over powpow's sync `HttpClient`: one helper per verb
  (`propfind`, `proppatch`, `mkcol`, `mkcolAddressbook`, `mkcalendar`, `copy`,
  `move`, `lock`, `unlock`, `report`, plus plain `get`/`put`/`delete`)
- Request builders (`buildPropertyupdate`, `buildLockinfo`,
  `buildCalendarQuery`, `buildCalendarMultiget`, `buildAddressbookQuery`,
  `buildAddressbookMultiget`, `buildMkcolAddressbook`, `buildSyncCollection`)
  that round-trip through the server parsers
- Response helpers: `multistatus` parsing into `DavResponse`s,
  `syncTokenOf`, `propstatCode`, `lockTokenOf`, `ensure` for status assertions

## Examples

### Run the example server

```sh
clue build examples/dav_server.nim --out:bin/dav_server
./bin/dav_server ./davroot 9001   # args optional, these are the defaults
```

### Talk to it with curl

```sh
# Class 1: upload and inspect
curl -X PUT http://localhost:9001/hello.txt -d 'hi' -i
curl -X PROPFIND http://localhost:9001/ -H 'Depth: 1' -i

# Locking: lock, fail without a token, succeed with one
TOK=$(curl -s -i -X LOCK http://localhost:9001/hello.txt \
  -H 'Depth: 0' -H 'Content-Type: application/xml' \
  -d '<D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>' \
  | grep -o 'Lock-Token: <[^>]*>')
curl -X PUT http://localhost:9001/hello.txt -d 'no' -i            # 423
curl -X PUT http://localhost:9001/hello.txt -d 'yes' -H "If: (<${TOK#Lock-Token: <})" -i

# CalDAV: calendar, event, time-range query
curl -X MKCALENDAR http://localhost:9001/cal -i
curl -X PUT http://localhost:9001/cal/ev.ics -H 'Content-Type: text/calendar' \
  -d 'BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Example//EN
BEGIN:VEVENT
UID:ev1
DTSTAMP:20260101T000000Z
DTSTART:20260105T100000Z
DTEND:20260105T110000Z
SUMMARY:Hi
END:VEVENT
END:VCALENDAR' -i
curl -X REPORT http://localhost:9001/cal -H 'Depth: 1' \
  -H 'Content-Type: application/xml' \
  -d '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260105T000000Z" end="20260106T000000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>' -i

# CardDAV: addressbook, contact, FN query
curl -X MKCOL http://localhost:9001/ab -H 'Content-Type: application/xml' \
  -d '<D:mkcol xmlns:D="DAV:" xmlns:CR="urn:ietf:params:xml:ns:carddav"><D:set><D:prop><D:resourcetype><D:collection/><CR:addressbook/></D:resourcetype><D:displayname>Contacts</D:displayname></D:prop></D:set></D:mkcol>' -i
curl -X PUT http://localhost:9001/ab/ada.vcf -H 'Content-Type: text/vcard' \
  -d 'BEGIN:VCARD
VERSION:4.0
FN:Ada Lovelace
N:Lovelace;Ada;;;
END:VCARD' -i
curl -X REPORT http://localhost:9001/ab -H 'Depth: 1' \
  -H 'Content-Type: application/xml' \
  -d '<CR:addressbook-query xmlns:D="DAV:" xmlns:CR="urn:ietf:params:xml:ns:carddav"><D:prop><D:getetag/><CR:address-data/></D:prop><CR:filter><CR:prop-filter name="FN"><CR:text-match collation="i;unicode-casemap" match-type="contains">ada</CR:text-match></CR:prop-filter></CR:filter></CR:addressbook-query>' -i
```

### Embed it in your app

```nim
import webdav  # before powpow, see the import rule above

let srv = newDavServer(newLocalDriver("./davroot"))
newHttpServer().start(srv.davHandler(), Port(9001))
```

Use `newMemoryDriver()` instead of `newLocalDriver()` for tests (see
`tests/t_server_mem.nim` for the loopback pattern).

### Use the client

```nim
import webdav

let dav = newDavClient("http://localhost:9001")
dav.mkcalendar("/cal").ensure(Http201)
dav.put("/cal/ev.ics", readFile("ev.ics")).ensure(Http201)
let found = dav.report("/cal",
  buildCalendarQuery("VEVENT", "20260105T000000Z", "20260106T000000Z"),
  ).multistatus()
for r in found:
  echo r.href
dav.closeClient()
```

## Modules

| Module | Job |
|---|---|
| `webdav/davmethod` | Compile-time verb registration (`PROPFIND` … `REPORT`, `MKCALENDAR`) |
| `webdav/types` | Shared DAV types |
| `webdav/davxml` | Hardened DAV XML parsing + `multistatus` builder |
| `webdav/backend` | flysystem pairing, dead props, calendar/addressbook markers |
| `webdav/props` | Live property computation |
| `webdav/locks` | Lock manager, `Timeout`/`If` parsing |
| `webdav/caldav` | REPORT parsing, time-range + recurrence matching |
| `webdav/carddav` | REPORT parsing, prop/param-filter + text-match matching |
| `webdav/server` | Request router (`DavServer`, `davHandler`) |
| `webdav/client` | Sync client (`DavClient`, builders, response helpers) |

## Tests

```sh
clue build tests/t_davmethod.nim  --out:/tmp/t_davmethod  && /tmp/t_davmethod
clue build tests/t_davxml.nim     --out:/tmp/t_davxml     && /tmp/t_davxml
clue build tests/t_locks.nim      --out:/tmp/t_locks      && /tmp/t_locks
clue build tests/t_server_mem.nim --out:/tmp/t_server_mem && /tmp/t_server_mem
clue build tests/t_caldav.nim     --out:/tmp/t_caldav     && /tmp/t_caldav
clue build tests/t_carddav.nim    --out:/tmp/t_carddav    && /tmp/t_carddav
clue build tests/t_client.nim     --out:/tmp/t_client     && /tmp/t_client
```

440+ checks total across unit suites and loopback servers (in-memory backend
plus live curl runs against the disk-backed example).

## Known limits

- `Depth: infinity` on `PROPFIND` is capped to depth 1
- `PROPPATCH` applies best-effort in order (no atomic all-or-nothing)
- `If` evaluation is a subset (`Not` supported, etag conditions ignored)
- No auth or principal model yet (any valid lock token satisfies a lock)
- `GET` on a collection answers `403` (no HTML listing view)
- Recurrence and timezone handling follow the documented subset in
  `src/webdav/caldav.nim` (clamped month overflow, UTC-normalized times)
- CardDAV handling follows the documented subset in
  `src/webdav/carddav.nim` (UID presence not required but unique when present,
  unknown `address-data` versions fall back to stored bytes,
  `sync-collection` keeps no delete tombstones so deletions surface as a full
  resync, no `principal-property-search`/ACLs yet)

## Roadmap

- [x] WebDAV client to match the server
- [x] CardDAV (requires `openparser >= 0.3.3` for vCard support)
- [ ] CalDAV scheduling and `free-busy-query` REPORTs
- [ ] Auth + principal collections (`calendar-home-set`, `current-user-principal`)
- [ ] Full `Depth: infinity` and atomic `PROPPATCH`
- [ ] Collection listing view for `GET`

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/webdav/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/webdav/fork)

### 🎩 License
MIT license | Nim Community.
