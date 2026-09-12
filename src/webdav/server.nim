# WebDAV Class 1 request router (RFC 4918) as a powpow `OnRequestCallback`.
#
# Current scope and known limits (see module docs per item):
# - `Depth: infinity` is honored as depth 1 (capped, documented).
# - `HEAD` returns GET headers with an empty body (`Content-Length: 0`);
#   powpow's `send()` always frames `Content-Length` from the body length.
# - PROPPATCH applies best-effort in order (no atomic all-or-nothing yet).
# - `Destination` accepts absolute URIs and absolute paths; the host part
#   is ignored (single-origin deployment assumed).
# - No locking yet (Class 2): `If` / `Lock-Token` are ignored.
# - `GET` on a collection is `403` (no listing view yet).
#
# CalDAV core (RFC 4791, see `caldav.nim` for the documented subset):
# `MKCALENDAR` creates calendar collections; REPORT serves
# `calendar-query` (comp-filter + time-range with recurrence expansion)
# and `calendar-multiget`. PUT into a calendar requires iCalendar object
# data. `OPTIONS` advertises `calendar-access`.

import ./davmethod # stage verb extensions before powpow compiles
export davmethod
import std/httpcore except HttpMethod
import std/[strutils, uri]
import powpow
import ./backend
import ./props
import ./caldav

export backend
export props
export caldav

const
  DavAllow* = "OPTIONS, GET, HEAD, POST, PUT, DELETE, MKCOL, MKCALENDAR, " &
    "PROPFIND, PROPPATCH, COPY, MOVE, LOCK, UNLOCK, REPORT"

type
  DavServer* = ref object
    backend*: DavBackend

proc newDavServer*(driver: StorageDriver): DavServer =
  DavServer(backend: newDavBackend(driver))

proc serve*(srv: DavServer, req: HttpRequest, res: HttpResponse)

proc davHandler*(srv: DavServer): OnRequestCallback =
  ## Build the request callback. Capture-safe for powpow's single-loop use.
  result = proc(req: HttpRequest, res: HttpResponse) {.gcsafe.} =
    {.gcsafe.}:
      srv.serve(req, res)

# ── Small helpers ────────────────────────────────────────────────────────────

proc reqHeader(req: HttpRequest, name: string): string =
  let h = req.getHeaders()
  if h.hasKey(name): $h[name] else: ""

proc normPath(raw: string): string =
  ## Decode + normalize a request target. Returns "" when the path escapes
  ## the root or is malformed.
  var decoded: string
  try:
    decoded = decodeUrl(raw)
  except CatchableError:
    return ""
  if not decoded.startsWith("/"):
    return ""
  var parts: seq[string]
  for seg in decoded.split('/'):
    case seg
    of "", ".": discard
    of "..":
      if parts.len == 0:
        return ""
      discard parts.pop()
    else:
      parts.add(seg)
  "/" & parts.join("/")

proc parentOf(urlPath: string): string =
  let i = urlPath.rfind('/')
  if i <= 0: "/" else: urlPath[0 ..< i]

proc collHref(urlPath: string): string {.inline.} =
  ## Collection hrefs end with `/` per RFC 4918 (root already does).
  if urlPath.endsWith("/"): urlPath else: urlPath & "/"

proc parseDepthHeader(s: string): int =
  ## 0, 1, 2 (= infinity), or -1 when invalid.
  case s.strip().toLowerAscii()
  of "0": 0
  of "1": 1
  of "infinity": 2
  else: -1

proc destUrlPath(req: HttpRequest): string =
  let raw = reqHeader(req, "Destination")
  if raw.len == 0:
    return ""
  var path: string
  try:
    path = parseUri(raw).path
  except CatchableError:
    return ""
  normPath(path)

proc overwriteFlag(req: HttpRequest): bool =
  reqHeader(req, "Overwrite").strip().toUpperAscii() != "F"

proc lockedOut(b: DavBackend, urlPath: string, req: HttpRequest): bool =
  ## True when covering locks exist and the request presents no matching
  ## token via `If` or `Lock-Token`. Callers answer `423 Locked`.
  not b.locks.ifSatisfied(urlPath, reqHeader(req, "If"),
    parseLockTokens(reqHeader(req, "Lock-Token")))

# ── Backend queries ──────────────────────────────────────────────────────────

proc exists(b: DavBackend, urlPath: string): bool =
  b.driver.exists(toDriverPath(urlPath))

proc isCollection(b: DavBackend, urlPath: string): bool =
  b.driver.metadata(toDriverPath(urlPath)).isDir

proc parentIsCollection(b: DavBackend, urlPath: string): bool =
  let p = parentOf(urlPath)
  if p == "/":
    return true
  if not b.exists(p):
    return false
  b.isCollection(p)

# ── Method handlers ──────────────────────────────────────────────────────────

proc serveOptions(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  res.status(Http200)
    .header("Allow", DavAllow)
    .header("DAV", "1, 2, calendar-access")
    .header("Content-Length", "0")
    .send("")

proc serveGet(srv: DavServer, req: HttpRequest, res: HttpResponse,
    headOnly: bool) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or not b.exists(path):
    res.sendError(Http404, "Not Found")
    return
  if b.isCollection(path):
    res.sendError(Http403, "GET on collections is not supported")
    return
  var content: string
  try:
    content = b.driver.read(toDriverPath(path))
  except CatchableError:
    res.sendError(Http500, "Read failed")
    return
  let meta = b.driver.metadata(toDriverPath(path))
  var ctype = "application/octet-stream"
  try:
    ctype = b.driver.mimeType(toDriverPath(path))
  except CatchableError:
    discard
  res.status(Http200)
    .header("Content-Type", ctype)
    .header("ETag", davEtag(meta.size, meta.lastModified))
    .header("Last-Modified", httpDate(meta.lastModified))
  if headOnly:
    res.send("")
  else:
    res.send(content)

proc servePut(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or path == "/":
    res.sendError(Http409, "Conflict")
    return
  if not b.parentIsCollection(path):
    res.sendError(Http409, "Parent collection does not exist")
    return
  if b.exists(path) and b.isCollection(path):
    res.sendError(Http409, "Cannot PUT over a collection")
    return
  if b.lockedOut(path, req):
    res.sendError(Http423, "Locked")
    return
  # CalDAV gate: resources inside a calendar must hold iCalendar object
  # data (at least one VEVENT/VTODO/VJOURNAL).
  if b.isCalendarCollection(parentOf(path)) and
      not isCalendarContent(req.getBodyString()):
    res.sendError(Http400, "Calendar resources must contain iCalendar data")
    return
  let created = not b.exists(path)
  try:
    b.driver.write(toDriverPath(path), req.getBodyString())
  except CatchableError:
    res.sendError(Http500, "Write failed")
    return
  res.status(if created: Http201 else: Http204).send("")

proc serveDelete(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or not b.exists(path):
    res.sendError(Http404, "Not Found")
    return
  if path == "/":
    res.sendError(Http403, "Cannot DELETE the root collection")
    return
  if b.lockedOut(path, req):
    res.sendError(Http423, "Locked")
    return
  try:
    if b.isCollection(path):
      b.driver.deleteDir(toDriverPath(path), force = true)
    else:
      b.driver.delete(toDriverPath(path))
  except CatchableError:
    res.sendError(Http500, "Delete failed")
    return
  b.forgetDead(path)
  res.status(Http204).send("")

proc serveMkcol(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or path == "/":
    res.sendError(Http405, "Collection already exists")
    return
  if req.getBodyString().len > 0:
    res.sendError(Http415, "MKCOL with a body is not supported")
    return
  if b.exists(path):
    res.sendError(Http405, "Resource already exists")
    return
  if not b.parentIsCollection(path):
    res.sendError(Http409, "Parent collection does not exist")
    return
  if b.lockedOut(path, req):
    res.sendError(Http423, "Locked")
    return
  try:
    b.driver.makeDir(toDriverPath(path))
  except CatchableError:
    res.sendError(Http500, "MKCOL failed")
    return
  res.status(Http201).send("")

proc serveMkcalendar(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  ## CalDAV MKCALENDAR (RFC 4791 §5.3.1): like MKCOL, plus the calendar
  ## marker. An XML body may carry `<set><prop>` defaults, stored as dead
  ## props; protected live props are rejected with `403` before anything
  ## is created. Calendars may nest (lenient, documented).
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or path == "/":
    res.sendError(Http405, "Collection already exists")
    return
  if b.exists(path):
    res.sendError(Http405, "Resource already exists")
    return
  if not b.parentIsCollection(path):
    res.sendError(Http409, "Parent collection does not exist")
    return
  if b.lockedOut(path, req):
    res.sendError(Http423, "Locked")
    return
  var bodyProps: seq[DavProp]
  if req.getBodyString().strip().len > 0:
    try:
      bodyProps = parseMkcalendarProps(req.getBodyString())
    except DavXmlError as e:
      res.sendError(Http422, e.msg)
      return
  for p in bodyProps:
    if p.ns == DavNs and isProtectedLive(p.name):
      res.sendError(Http403, "Protected live property: " & p.name)
      return
  try:
    b.driver.makeDir(toDriverPath(path))
  except CatchableError:
    res.sendError(Http500, "MKCALENDAR failed")
    return
  b.markCalendar(path)
  for p in bodyProps:
    if p.xml.len > 0:
      b.setDead(path, p.ns, p.name, "", p.xml)
    else:
      b.setDead(path, p.ns, p.name, p.value, "")
  res.status(Http201).send("")

proc hrefToPath(href: string): string =
  ## Absolute URI or absolute path to a normalized URL path ("" when bad).
  var raw: string
  try:
    raw = parseUri(href.strip()).path
  except CatchableError:
    return ""
  if raw.len == 0:
    return ""
  normPath(raw)

proc calPropstats(b: DavBackend, urlPath, content: string,
    rep: CalReportRequest): seq[DavPropstat] =
  ## 200/404 propstat groups for one matched calendar object resource.
  var ok, missing: seq[DavProp]
  if rep.wantEtag:
    try:
      let meta = b.driver.metadata(toDriverPath(urlPath))
      ok.add(DavProp(ns: DavNs, name: "getetag",
        value: davEtag(meta.size, meta.lastModified)))
    except CatchableError:
      missing.add(DavProp(ns: DavNs, name: "getetag"))
  if rep.wantCalData:
    ok.add(calDataProp(content))
  if rep.extraProps.len > 0:
    let live = b.liveProps(urlPath)
    let dead = b.deadPropsList(urlPath)
    for name in rep.extraProps:
      let li = live.findLive(name)
      if li >= 0:
        ok.add(live[li])
        continue
      var found = false
      for pr in dead:
        if pr.name == name:
          ok.add(pr)
          found = true
          break
      if not found:
        missing.add(DavProp(ns: DavNs, name: name))
  if ok.len > 0:
    result.add(DavPropstat(props: ok, status: "HTTP/1.1 200 OK"))
  if missing.len > 0:
    result.add(DavPropstat(props: missing,
      status: "HTTP/1.1 404 Not Found"))

proc serveReport(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  ## CalDAV `calendar-query` / `calendar-multiget` (RFC 4791 §7).
  ## Anything else REPORT-shaped answers `501`. Calendar reports against
  ## a non-calendar target answer `403`.
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or not b.exists(path):
    res.sendError(Http404, "Not Found")
    return
  var rep: CalReportRequest
  try:
    rep = parseCalReport(req.getBodyString())
  except DavXmlError as e:
    # Non-CalDAV REPORT roots (e.g. DAV-only bodies) are unimplemented.
    if "unsupported REPORT" in e.msg or "not a CalDAV element" in e.msg:
      res.sendError(Http501, "Not Implemented: " & e.msg)
    else:
      res.sendError(Http422, e.msg)
    return
  if rep.kind == rkMultiget:
    if not b.isCalendarCollection(path):
      res.sendError(Http403, "calendar-multiget needs a calendar collection")
      return
    var responses: seq[DavResponse]
    for href in rep.hrefs:
      let rp = hrefToPath(href)
      if rp.len == 0 or not b.exists(rp) or b.isCollection(rp) or
          (rp != path and not rp.startsWith(collHref(path))):
        responses.add(DavResponse(href: href,
          propstats: @[DavPropstat(props: @[],
            status: "HTTP/1.1 404 Not Found")]))
        continue
      var content = ""
      try:
        content = b.driver.read(toDriverPath(rp))
      except CatchableError:
        responses.add(DavResponse(href: href,
          propstats: @[DavPropstat(props: @[],
            status: "HTTP/1.1 404 Not Found")]))
        continue
      responses.add(DavResponse(href: rp,
        propstats: b.calPropstats(rp, content, rep)))
    res.status(Http207)
      .header("Content-Type", "application/xml; charset=utf-8")
      .send(buildMultistatus(responses))
    return
  # calendar-query: Depth 0 or 1 (default 1); infinity is rejected.
  let rawDepth = reqHeader(req, "Depth")
  var depth = 1
  if rawDepth.len > 0:
    depth = parseDepthHeader(rawDepth)
    if depth != 0 and depth != 1:
      res.sendError(Http400, "REPORT Depth must be 0 or 1")
      return
  var candidates: seq[string]
  if b.isCollection(path):
    if not b.isCalendarCollection(path):
      res.sendError(Http403, "calendar-query needs a calendar collection")
      return
    if depth == 1:
      try:
        for m in b.driver.list(toDriverPath(path), recursive = false):
          let cp = "/" & m.path
          if not b.isCollection(cp):
            candidates.add(cp)
      except CatchableError:
        res.sendError(Http500, "REPORT failed")
        return
  else:
    if not b.isCalendarCollection(parentOf(path)):
      res.sendError(Http403, "calendar-query needs a calendar resource")
      return
    candidates.add(path)
  var responses: seq[DavResponse]
  for cp in candidates:
    var content = ""
    try:
      content = b.driver.read(toDriverPath(cp))
    except CatchableError:
      continue
    if resourceMatches(content, rep.compName, rep.timeRange,
        rep.hasTimeRange):
      responses.add(DavResponse(href: cp,
        propstats: b.calPropstats(cp, content, rep)))
  res.status(Http207)
    .header("Content-Type", "application/xml; charset=utf-8")
    .send(buildMultistatus(responses))

proc resourceResponses(b: DavBackend, urlPath: string, depth: int,
    pf: PropfindRequest): seq[DavResponse] =
  ## Response list for PROPFIND: self plus direct children at depth >= 1.
  ## `depth == 2` (infinity) is capped to 1.
  var paths = @[urlPath]
  if depth >= 1 and b.isCollection(urlPath):
    # Driver listings are root-relative already (`col/f.txt`).
    for m in b.driver.list(toDriverPath(urlPath), recursive = false):
      paths.add("/" & m.path)
  for p in paths:
    let live = b.liveProps(p)
    let dead = b.deadPropsList(p)
    var propstats: seq[DavPropstat]
    case pf.kind
    of pfAllprop:
      propstats.add(DavPropstat(props: live & dead,
        status: "HTTP/1.1 200 OK"))
    of pfPropname:
      var names: seq[DavProp]
      for pr in live:
        names.add(DavProp(ns: pr.ns, name: pr.name))
      for pr in dead:
        names.add(DavProp(ns: pr.ns, name: pr.name))
      propstats.add(DavPropstat(props: names, status: "HTTP/1.1 200 OK"))
    of pfProp:
      var ok, missing: seq[DavProp]
      for name in pf.props:
        let li = live.findLive(name)
        if li >= 0:
          ok.add(live[li])
          continue
        var found = false
        for pr in dead:
          if pr.ns == DavNs and pr.name == name:
            ok.add(pr)
            found = true
            break
        if not found:
          missing.add(DavProp(ns: DavNs, name: name))
      if ok.len > 0:
        propstats.add(DavPropstat(props: ok, status: "HTTP/1.1 200 OK"))
      if missing.len > 0:
        propstats.add(DavPropstat(props: missing,
          status: "HTTP/1.1 404 Not Found"))
    let href =
      if b.isCollection(p): collHref(p)
      else: p
    result.add(DavResponse(href: href, propstats: propstats))

proc servePropfind(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or not b.exists(path):
    res.sendError(Http404, "Not Found")
    return
  let rawDepth = reqHeader(req, "Depth")
  var depth: int
  if rawDepth.len == 0:
    depth = if b.isCollection(path): 2 else: 0
  else:
    depth = parseDepthHeader(rawDepth)
    if depth < 0:
      res.sendError(Http400, "Invalid Depth header")
      return
  var pf = PropfindRequest(kind: pfAllprop)
  if req.getBodyString().len > 0:
    try:
      pf = parsePropfind(req.getBodyString())
    except DavXmlError as e:
      res.sendError(Http422, e.msg)
      return
  var responses: seq[DavResponse]
  try:
    responses = b.resourceResponses(path, depth, pf)
  except CatchableError:
    res.sendError(Http500, "PROPFIND failed")
    return
  res.status(Http207)
    .header("Content-Type", "application/xml; charset=utf-8")
    .send(buildMultistatus(responses))

proc serveProppatch(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0 or not b.exists(path):
    res.sendError(Http404, "Not Found")
    return
  if b.lockedOut(path, req):
    res.sendError(Http423, "Locked")
    return
  var pu: PropertyupdateRequest
  try:
    pu = parsePropertyupdate(req.getBodyString())
  except DavXmlError as e:
    res.sendError(Http422, e.msg)
    return
  var ok, forbidden, missing: seq[DavProp]
  for op in pu.ops:
    case op.op
    of poSet:
      for p in op.props:
        if p.ns == DavNs and isProtectedLive(p.name):
          forbidden.add(DavProp(ns: p.ns, name: p.name))
        else:
          b.setDead(path, p.ns, p.name, p.value, p.xml)
          if p.xml.len > 0:
            ok.add(DavProp(ns: p.ns, name: p.name, xml: p.xml))
          else:
            ok.add(DavProp(ns: p.ns, name: p.name, value: p.value))
    of poRemove:
      for p in op.props:
        if p.ns == DavNs and isProtectedLive(p.name):
          forbidden.add(DavProp(ns: p.ns, name: p.name))
        elif b.delDead(path, p.ns, p.name):
          ok.add(DavProp(ns: p.ns, name: p.name))
        else:
          missing.add(DavProp(ns: p.ns, name: p.name))
  var propstats: seq[DavPropstat]
  if ok.len > 0:
    propstats.add(DavPropstat(props: ok, status: "HTTP/1.1 200 OK"))
  if forbidden.len > 0:
    propstats.add(DavPropstat(props: forbidden,
      status: "HTTP/1.1 403 Forbidden"))
  if missing.len > 0:
    propstats.add(DavPropstat(props: missing,
      status: "HTTP/1.1 404 Not Found"))
  res.status(Http207)
    .header("Content-Type", "application/xml; charset=utf-8")
    .send(buildMultistatus(@[DavResponse(href: path, propstats: propstats)]))

proc serveCopyMove(srv: DavServer, req: HttpRequest, res: HttpResponse,
    isMove: bool) =
  let b = srv.backend
  let src = normPath(req.getPath())
  if src.len == 0 or not b.exists(src):
    res.sendError(Http404, "Not Found")
    return
  let dest = destUrlPath(req)
  if dest.len == 0:
    res.sendError(Http400, "Destination header required")
    return
  if dest == src or dest.startsWith(src & "/"):
    res.sendError(Http403, "Cannot copy onto itself or into itself")
    return
  if not b.parentIsCollection(dest):
    res.sendError(Http409, "Destination parent does not exist")
    return
  if b.lockedOut(src, req) or b.lockedOut(dest, req):
    res.sendError(Http423, "Locked")
    return
  let overwrite = overwriteFlag(req)
  let destExisted = b.exists(dest)
  if destExisted and not overwrite:
    res.sendError(Http412, "Destination exists and Overwrite is F")
    return
  let srcIsDir = b.isCollection(src)
  if not isMove:
    let rawDepth = reqHeader(req, "Depth")
    var depth = 2
    if rawDepth.len > 0:
      depth = parseDepthHeader(rawDepth)
      if depth != 0 and depth != 2:
        res.sendError(Http400, "COPY Depth must be 0 or infinity")
        return
  try:
    if destExisted:
      if b.isCollection(dest):
        b.driver.deleteDir(toDriverPath(dest), force = true)
      else:
        b.driver.delete(toDriverPath(dest))
      b.forgetDead(dest)
    if srcIsDir:
      let rawDepth = reqHeader(req, "Depth")
      let shallow = not isMove and rawDepth.len > 0 and
        parseDepthHeader(rawDepth) == 0
      if shallow:
        b.driver.makeDir(toDriverPath(dest))
      elif isMove:
        b.driver.moveDir(toDriverPath(src), toDriverPath(dest))
      else:
        b.driver.copyDir(toDriverPath(src), toDriverPath(dest))
    else:
      if isMove:
        b.driver.move(toDriverPath(src), toDriverPath(dest))
      else:
        b.driver.copy(toDriverPath(src), toDriverPath(dest))
  except CatchableError:
    res.sendError(Http500, (if isMove: "MOVE failed" else: "COPY failed"))
    return
  # Carry dead props to the destination (clearing a replaced destination
  # first). COPY duplicates, MOVE relocates.
  if isMove:
    b.moveDead(src, dest, destExisted)
  else:
    b.copyDead(src, dest, destExisted)
  res.status(if destExisted: Http204 else: Http201).send("")

proc lockPropBody(lock: DavLock, href: string): string =
  let prop = newDavElement("prop")
  let ld = newDavElement("lockdiscovery")
  for n in parseFragment(activeLockXml(lock, href)):
    ld.addChild(n)
  prop.addChild(ld)
  davDoc(prop)

proc serveLock(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0:
    res.sendError(Http400, "Bad path")
    return
  let rawDepth = reqHeader(req, "Depth")
  let depth =
    if rawDepth.len == 0: 2
    else: parseDepthLock(rawDepth)
  if depth < 0:
    res.sendError(Http400, "LOCK Depth must be 0 or infinity")
    return
  let timeout = parseTimeout(reqHeader(req, "Timeout"))
  let tokens = parseLockTokens(reqHeader(req, "Lock-Token"))
  let body = req.getBodyString()
  if body.len == 0:
    if tokens.len == 0:
      # Fresh lock with server defaults (exclusive/write).
      if not b.exists(path):
        if not b.parentIsCollection(path):
          res.sendError(Http409, "Parent collection does not exist")
          return
        try:
          b.driver.write(toDriverPath(path), "")
        except CatchableError:
          res.sendError(Http500, "Write failed")
          return
      var lock: DavLock
      try:
        lock = b.locks.acquire(path, lsExclusive, depth, "", timeout)
      except DavLockConflict:
        res.sendError(Http423, "Locked")
        return
      let href =
        if b.isCollection(path): collHref(path) else: path
      res.status(Http200)
        .header("Lock-Token", "<" & lock.token & ">")
        .header("Content-Type", "application/xml; charset=utf-8")
        .send(lockPropBody(lock, href))
      return
    for tok in tokens:
      if b.locks.refresh(tok, timeout):
        let lock = b.locks.getToken(tok)
        let href =
          if b.exists(path) and b.isCollection(path): collHref(path)
          else: path
        res.status(Http200)
          .header("Lock-Token", "<" & tok & ">")
          .header("Content-Type", "application/xml; charset=utf-8")
          .send(lockPropBody(lock, href))
        return
    res.sendError(Http400, "Unknown lock token")
    return
  var info: LockinfoRequest
  try:
    info = parseLockinfo(body)
  except DavXmlError as e:
    res.sendError(Http422, e.msg)
    return
  if not b.exists(path):
    if not b.parentIsCollection(path):
      res.sendError(Http409, "Parent collection does not exist")
      return
    try:
      b.driver.write(toDriverPath(path), "")
    except CatchableError:
      res.sendError(Http500, "Write failed")
      return
  let scope =
    if info.scope == "shared": lsShared else: lsExclusive
  var lock: DavLock
  try:
    lock = b.locks.acquire(path, scope, depth, info.owner, timeout)
  except DavLockConflict:
    res.sendError(Http423, "Locked")
    return
  let href =
    if b.isCollection(path): collHref(path) else: path
  res.status(Http200)
    .header("Lock-Token", "<" & lock.token & ">")
    .header("Content-Type", "application/xml; charset=utf-8")
    .send(lockPropBody(lock, href))

proc serveUnlock(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let b = srv.backend
  let path = normPath(req.getPath())
  if path.len == 0:
    res.sendError(Http400, "Bad path")
    return
  let tokens = parseLockTokens(reqHeader(req, "Lock-Token"))
  if tokens.len == 0:
    res.sendError(Http400, "Lock-Token header required")
    return
  for tok in tokens:
    if b.locks.release(tok, path):
      res.status(Http204).send("")
      return
  res.sendError(Http409, "Lock token does not match")

proc serve*(srv: DavServer, req: HttpRequest, res: HttpResponse) =
  let meth = req.getMethod()
  case meth
  of HttpOptions:
    srv.serveOptions(req, res)
  of HttpGet:
    srv.serveGet(req, res, headOnly = false)
  of HttpHead:
    srv.serveGet(req, res, headOnly = true)
  of HttpPut:
    srv.servePut(req, res)
  of HttpDelete:
    srv.serveDelete(req, res)
  of HttpMkcol:
    srv.serveMkcol(req, res)
  of HttpMkcalendar:
    srv.serveMkcalendar(req, res)
  of HttpReport:
    srv.serveReport(req, res)
  of HttpPropfind:
    srv.servePropfind(req, res)
  of HttpProppatch:
    srv.serveProppatch(req, res)
  of HttpCopy:
    srv.serveCopyMove(req, res, isMove = false)
  of HttpMove:
    srv.serveCopyMove(req, res, isMove = true)
  of HttpLock:
    srv.serveLock(req, res)
  of HttpUnlock:
    srv.serveUnlock(req, res)
  else:
    # POST, PATCH and anything extended later.
    res.sendError(Http501, "Not Implemented: " & $meth)
