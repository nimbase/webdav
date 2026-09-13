# WebDAV client (RFC 4918 + the CalDAV report subset in `caldav.nim`) on
# top of powpow's sync `HttpClient`.
#
# Sync only: one blocking request at a time per client. Responses are backed
# by the client's pooled parser, so extract headers and bodies before the
# next request on the same client.
#
# Paths are server-rooted (`/cal/ev.ics`); a full URL is accepted only where
# a `dest` argument allows it (`COPY`/`MOVE` `Destination`, passed through
# untouched for single-origin servers).

import ./davmethod # stage verb extensions before powpow compiles
export davmethod
import std/httpcore except HttpMethod
import std/strutils
import powpow
import ./davxml

export davxml

type
  DavClientError* = object of CatchableError

  DavClient* = ref object
    http*: HttpClient
    base*: string ## Origin + optional prefix, no trailing slash.

proc wrapDavClient*(http: HttpClient, base: string): DavClient =
  ## Use a prebuilt client (custom TLS, pool tuning, or a loopback test
  ## client sharing its loop with a test server).
  DavClient(http: http, base: base.strip(leading = false, trailing = true,
    chars = {'/'}))

proc newDavClient*(base: string, timeoutMs = 0): DavClient =
  DavClient(http: newHttpClient(timeoutMs = timeoutMs),
    base: base.strip(leading = false, trailing = true, chars = {'/'}))

proc closeClient*(c: DavClient) =
  ## Close the wrapped HTTP client. Named apart from powpow's `close` so
  ## both overloads stay unambiguous in one scope.
  c.http.close()

proc urlFor*(c: DavClient, path: string): string =
  if path.startsWith("/"): c.base & path
  else: c.base & "/" & path

proc destValue(c: DavClient, dest: string): string =
  if dest.startsWith("http://") or dest.startsWith("https://"): dest
  else: c.urlFor(dest)

proc tokenValue(token: string): string =
  let t = token.strip()
  if t.startsWith("<"): t else: "<" & t & ">"

proc raw*(c: DavClient, meth: HttpMethod, path: string; body = "",
    headers: openArray[(string, string)] = []): HttpClientResponse {.discardable.} =
  c.http.request(meth, c.urlFor(path), body, headers)

# ── Request builders ─────────────────────────────────────────────────────

proc serializeProp(p: DavProp): XmlNode =
  let elem =
    if p.ns == DavNs: newDavElement(p.name)
    elif p.ns == CalNs: newCalElement(p.name)
    else: newXmlElement(p.name)
  if p.xml.len > 0:
    for n in parseFragment(p.xml):
      elem.addChild(n)
  elif p.value.len > 0:
    elem.addChild(newXmlText(p.value))
  elem

proc buildPropfindAllprop*(): string =
  let root = newDavElement("propfind")
  root.addAttr("xmlns:D", DavNs)
  root.addChild(newDavElement("allprop"))
  davDoc(root)

proc buildPropfindProp*(names: seq[string]): string =
  let root = newDavElement("propfind")
  root.addAttr("xmlns:D", DavNs)
  let prop = newDavElement("prop")
  for n in names:
    prop.addChild(newDavElement(n))
  root.addChild(prop)
  davDoc(root)

proc buildPropertyupdate*(sets, removes: seq[DavProp]): string =
  ## PROPPATCH body from dead-prop values. Raises `DavClientError` when both
  ## lists are empty (the server would reject it as `422` anyway).
  if sets.len == 0 and removes.len == 0:
    raise newException(DavClientError, "propertyupdate needs set or remove")
  let root = newDavElement("propertyupdate")
  root.addAttr("xmlns:D", DavNs)
  if sets.len > 0:
    let set = newDavElement("set")
    let prop = newDavElement("prop")
    for p in sets:
      prop.addChild(serializeProp(p))
    set.addChild(prop)
    root.addChild(set)
  if removes.len > 0:
    let remove = newDavElement("remove")
    let prop = newDavElement("prop")
    for p in removes:
      prop.addChild(serializeProp(p))
    remove.addChild(prop)
    root.addChild(remove)
  davDoc(root)

proc buildLockinfo*(scope = "exclusive", owner = ""): string =
  if scope != "exclusive" and scope != "shared":
    raise newException(DavClientError,
      "lock scope must be exclusive or shared")
  let root = newDavElement("lockinfo")
  root.addAttr("xmlns:D", DavNs)
  let ls = newDavElement("lockscope")
  ls.addChild(newDavElement(scope))
  root.addChild(ls)
  let lt = newDavElement("locktype")
  lt.addChild(newDavElement("write"))
  root.addChild(lt)
  if owner.len > 0:
    let own = newDavElement("owner")
    own.addChild(newXmlText(owner))
    root.addChild(own)
  davDoc(root)

proc buildCalendarQuery*(compName = "VEVENT", rangeStart = "",
    rangeEnd = "", wantEtag = true, wantCalData = true,
    extra: seq[string] = @[]): string =
  ## `calendar-query` REPORT body. Empty `compName` omits the filter
  ## (matches everything); empty bounds omit that side of `time-range`.
  let root = newXmlElement("C:calendar-query")
  root.addAttr("xmlns:D", DavNs)
  root.addAttr("xmlns:C", CalNs)
  let prop = newDavElement("prop")
  if wantEtag:
    prop.addChild(newDavElement("getetag"))
  if wantCalData:
    prop.addChild(newCalElement("calendar-data"))
  for n in extra:
    prop.addChild(newDavElement(n))
  root.addChild(prop)
  if compName.len > 0 or rangeStart.len > 0 or rangeEnd.len > 0:
    let filter = newCalElement("filter")
    let outer = newCalElement("comp-filter")
    outer.addAttr("name", "VCALENDAR")
    if compName.len > 0:
      let inner = newCalElement("comp-filter")
      inner.addAttr("name", compName)
      if rangeStart.len > 0 or rangeEnd.len > 0:
        let tr = newCalElement("time-range")
        if rangeStart.len > 0:
          tr.addAttr("start", rangeStart)
        if rangeEnd.len > 0:
          tr.addAttr("end", rangeEnd)
        inner.addChild(tr)
      outer.addChild(inner)
    filter.addChild(outer)
    root.addChild(filter)
  davDoc(root)

proc buildCalendarMultiget*(hrefs: seq[string], wantEtag = true,
    wantCalData = true, extra: seq[string] = @[]): string =
  if hrefs.len == 0:
    raise newException(DavClientError, "calendar-multiget needs hrefs")
  let root = newXmlElement("C:calendar-multiget")
  root.addAttr("xmlns:D", DavNs)
  root.addAttr("xmlns:C", CalNs)
  let prop = newDavElement("prop")
  if wantEtag:
    prop.addChild(newDavElement("getetag"))
  if wantCalData:
    prop.addChild(newCalElement("calendar-data"))
  for n in extra:
    prop.addChild(newDavElement(n))
  root.addChild(prop)
  for h in hrefs:
    let href = newDavElement("href")
    href.addChild(newXmlText(h))
    root.addChild(href)
  davDoc(root)

# ── Verb helpers ─────────────────────────────────────────────────────────

proc options*(c: DavClient, path = "/"): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpOptions, path)

proc get*(c: DavClient, path: string,
    headers: openArray[(string, string)] = []): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpGet, path, "", headers)

proc head*(c: DavClient, path: string,
    headers: openArray[(string, string)] = []): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpHead, path, "", headers)

proc put*(c: DavClient, path, body: string,
    headers: openArray[(string, string)] = []): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpPut, path, body, headers)

proc delete*(c: DavClient, path: string,
    headers: openArray[(string, string)] = []): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpDelete, path, "", headers)

proc mkcol*(c: DavClient, path: string): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpMkcol, path)

proc mkcalendar*(c: DavClient, path: string; body = ""): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpMkcalendar, path, body)

proc propfind*(c: DavClient, path: string, depth = "1",
    body = ""): HttpClientResponse {.inline, discardable.} =
  ## Empty `body` asks for the server default (`allprop`).
  c.raw(HttpPropfind, path, body, [("Depth", depth)])

proc proppatch*(c: DavClient, path: string, sets: seq[DavProp] = @[],
    removes: seq[DavProp] = @[]): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpProppatch, path, buildPropertyupdate(sets, removes))

proc copy*(c: DavClient, path, dest: string, overwrite = true,
    depth = "infinity"): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpCopy, path, "", [("Destination", c.destValue(dest)),
    ("Overwrite", if overwrite: "T" else: "F"), ("Depth", depth)])

proc move*(c: DavClient, path, dest: string,
    overwrite = true): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpMove, path, "", [("Destination", c.destValue(dest)),
    ("Overwrite", if overwrite: "T" else: "F")])

proc lock*(c: DavClient, path: string, scope = "exclusive",
    depth = "infinity", timeout = "",
    owner = ""): HttpClientResponse {.discardable.} =
  var headers = @[("Depth", depth)]
  if timeout.len > 0:
    headers.add(("Timeout", timeout))
  c.raw(HttpLock, path, buildLockinfo(scope, owner), headers)

proc unlock*(c: DavClient, path, token: string): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpUnlock, path, "", [("Lock-Token", tokenValue(token))])

proc report*(c: DavClient, path, body: string,
    depth = "1"): HttpClientResponse {.inline, discardable.} =
  c.raw(HttpReport, path, body, [("Depth", depth)])

# ── Response helpers ─────────────────────────────────────────────────────

proc ensure*(res: HttpClientResponse,
    expected: varargs[HttpCode]): HttpClientResponse {.discardable.} =
  ## Return `res` when its status is expected, else raise `DavClientError`
  ## carrying the status plus a body excerpt.
  for e in expected:
    if res.getStatusCode() == e:
      return res
  let body = res.getBodyString()
  raise newException(DavClientError, "unexpected status " &
    $res.getStatusCode() & ": " & body[0 ..< min(body.len, 200)])

proc multistatus*(res: HttpClientResponse): seq[DavResponse] =
  ## Parse a `207` body into responses. Raises `DavClientError` on any other
  ## status or on a malformed body.
  if res.getStatusCode() != Http207:
    raise newException(DavClientError, "expected 207 multistatus, got " &
      $res.getStatusCode())
  try:
    parseMultistatus(res.getBodyString())
  except DavXmlError as e:
    raise newException(DavClientError, "bad multistatus: " & e.msg)

proc lockTokenOf*(res: HttpClientResponse): string =
  ## The `Lock-Token` response header without angle brackets.
  try:
    ($res.getHeaders()["Lock-Token"]).strip(chars = {'<', '>'})
  except KeyError:
    raise newException(DavClientError, "response lacks Lock-Token")

proc findResponse*(rs: seq[DavResponse], href: string): int =
  ## Index of the response for `href`, or -1.
  for i, r in rs:
    if r.href == href:
      return i
  -1

proc okProps*(r: DavResponse): seq[DavProp] =
  ## Props from the `200` propstat groups of one response.
  for ps in r.propstats:
    if propstatCode(ps.status) div 100 == 2:
      for p in ps.props:
        result.add(p)
