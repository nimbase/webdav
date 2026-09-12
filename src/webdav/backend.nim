# WebDAV storage backend on top of `pkg/flysystem`.
#
# `DavBackend` pairs any flysystem `StorageDriver` (e.g. `LocalDriver` for
# disk, `MemoryDriver` below for tests) with the WebDAV-side state that
# drivers don't own: dead (custom) properties per resource.
#
# Path convention: server-side URL paths (`/a/b`, decoded, normalized);
# driver-side relative paths (`a/b`). The root collection is `/` (driver
# path "") and always exists.

import std/[tables, times, strutils, options, sequtils, os]
import pkg/flysystem
import pkg/mimedb
import ./locks

export flysystem
export locks

type
  DeadProp* = object
    ns*: string    ## Namespace URI of the dead property.
    value*: string ## Text content (when the stored prop was pure text).
    xml*: string   ## Verbatim inner XML (when structural), round-tripped.

  DavBackend* = ref object
    driver*: StorageDriver
    locks*: LockManager
    deadProps*: Table[string, Table[string, DeadProp]] ## urlPath -> key -> prop
    calendars*: Table[string, bool] ## urlPath of a collection -> is calendar

  MemNode = ref object
    isDir: bool
    data: string
    mtime: Time
    vis: Visibility

  MemoryDriver* = ref object of StorageDriver
    ## In-memory `StorageDriver` for tests. Unimplemented surface
    ## (`readStream`, `checksum`, `search`, ...) raises `StorageError`
    ## via the abstract base — the DAV server only uses the implemented
    ## subset. `GET` serves via `read()`, so very large files cost RAM;
    ## disk-backed deployments should use `LocalDriver`.
    nodes: Table[string, MemNode]

func memKey(path: string): string =
  path.strip(chars = {'/'})

proc ensureParents(d: MemoryDriver, key: string, now: Time) =
  var parts = key.split('/')
  for i in 0 ..< parts.len - 1:
    let p = parts[0 .. i].join("/")
    if p notin d.nodes:
      d.nodes[p] = MemNode(isDir: true, mtime: now, vis: visPrivate)

proc newMemoryDriver*(): MemoryDriver =
  MemoryDriver(nodes: {"": MemNode(isDir: true, mtime: getTime(),
    vis: visPrivate)}.toTable)

method write*(d: MemoryDriver, path, content: string,
    visibility = visPrivate) =
  let key = memKey(path)
  if key.len == 0:
    raise newException(StorageError, "cannot write root collection")
  let now = getTime()
  d.ensureParents(key, now)
  d.nodes[key] = MemNode(isDir: false, data: content, mtime: now,
    vis: visibility)

method read*(d: MemoryDriver, path: string): string =
  let key = memKey(path)
  if key notin d.nodes or d.nodes[key].isDir:
    raise newException(StorageError, "not a file: " & path)
  d.nodes[key].data

method delete*(d: MemoryDriver, path: string) =
  let key = memKey(path)
  if key.len == 0:
    raise newException(StorageError, "cannot delete root collection")
  if key notin d.nodes:
    raise newException(StorageError, "not found: " & path)
  if d.nodes[key].isDir:
    for k in toSeq(d.nodes.keys):
      if k != key and k.startsWith(key & "/"):
        raise newException(StorageError, "directory not empty: " & path)
  d.nodes.del(key)

method exists*(d: MemoryDriver, path: string): bool =
  memKey(path) in d.nodes

proc memMeta(d: MemoryDriver, key: string): FileMetadata =
  let n = d.nodes[key]
  FileMetadata(path: key, size: (if n.isDir: 0 else: n.data.len).int64,
    lastModified: n.mtime, visibility: n.vis, isDir: n.isDir)

method metadata*(d: MemoryDriver, path: string): FileMetadata =
  let key = memKey(path)
  if key notin d.nodes:
    raise newException(StorageError, "not found: " & path)
  d.memMeta(key)

method list*(d: MemoryDriver, path: string,
    recursive = false): seq[FileMetadata] =
  let key = memKey(path)
  if key notin d.nodes or not d.nodes[key].isDir:
    raise newException(StorageError, "not a collection: " & path)
  let prefix = if key.len == 0: "" else: key & "/"
  for k in d.nodes.keys:
    if not k.startsWith(prefix) or k == key:
      continue
    let rest = k[prefix.len .. ^1]
    if not recursive and "/" in rest:
      continue
    result.add(d.memMeta(k))

method makeDir*(d: MemoryDriver, path: string) =
  let key = memKey(path)
  if key.len == 0:
    return
  let now = getTime()
  d.ensureParents(key, now)
  if key in d.nodes:
    if not d.nodes[key].isDir:
      raise newException(StorageError, "not a directory: " & path)
  else:
    d.nodes[key] = MemNode(isDir: true, mtime: now, vis: visPrivate)

method deleteDir*(d: MemoryDriver, path: string, force = false) =
  let key = memKey(path)
  if key.len == 0:
    raise newException(StorageError, "cannot delete root collection")
  if key notin d.nodes or not d.nodes[key].isDir:
    raise newException(StorageError, "not a collection: " & path)
  if not force:
    for k in d.nodes.keys:
      if k.startsWith(key & "/"):
        raise newException(StorageError, "directory not empty: " & path)
    d.nodes.del(key)
  else:
    let prefix = if key.len == 0: "" else: key & "/"
    var doomed: seq[string]
    for k in d.nodes.keys:
      if k == key or (key.len > 0 and k.startsWith(prefix)) or
          (key.len == 0 and k != ""):
        doomed.add(k)
    for k in doomed:
      d.nodes.del(k)

proc copyNode(d: MemoryDriver, srcKey, destKey: string, now: Time) =
  let s = d.nodes[srcKey]
  d.nodes[destKey] = MemNode(isDir: s.isDir, data: s.data, mtime: now,
    vis: s.vis)

method copy*(d: MemoryDriver, src, dest: string) =
  let sk = memKey(src)
  let dk = memKey(dest)
  if sk notin d.nodes or d.nodes[sk].isDir:
    raise newException(StorageError, "not a file: " & src)
  if dk.len == 0:
    raise newException(StorageError, "cannot copy over root")
  let now = getTime()
  d.ensureParents(dk, now)
  d.copyNode(sk, dk, now)

method copyDir*(d: MemoryDriver, src, dest: string) =
  let sk = memKey(src)
  let dk = memKey(dest)
  if sk notin d.nodes or not d.nodes[sk].isDir:
    raise newException(StorageError, "not a collection: " & src)
  let now = getTime()
  d.ensureParents(dk, now)
  if dk notin d.nodes:
    d.nodes[dk] = MemNode(isDir: true, mtime: now, vis: visPrivate)
  let prefix = if sk.len == 0: "" else: sk & "/"
  for k in toSeq(d.nodes.keys):
    if sk.len == 0:
      if k == "":
        continue
      d.copyNode(k, (if dk.len == 0: k else: dk & "/" & k), now)
    elif k.startsWith(prefix):
      d.copyNode(k, dk & "/" & k[prefix.len .. ^1], now)

method move*(d: MemoryDriver, src, dest: string) =
  d.copy(src, dest)
  d.nodes.del(memKey(src))

method moveDir*(d: MemoryDriver, src, dest: string) =
  d.copyDir(src, dest)
  d.deleteDir(src, force = true)

method touch*(d: MemoryDriver, path: string) =
  let key = memKey(path)
  if key in d.nodes:
    d.nodes[key].mtime = getTime()
  else:
    d.write(path, "")

method setVisibility*(d: MemoryDriver, path: string,
    visibility: Visibility) =
  let key = memKey(path)
  if key notin d.nodes:
    raise newException(StorageError, "not found: " & path)
  d.nodes[key].vis = visibility

method visibility*(d: MemoryDriver, path: string): Visibility =
  let key = memKey(path)
  if key notin d.nodes:
    raise newException(StorageError, "not found: " & path)
  d.nodes[key].vis

method mimeType*(d: MemoryDriver, path: string): string =
  let ext = splitFile(path).ext
  if ext.len == 0:
    return "application/octet-stream"
  getMimeType(ext[1 .. ^1]).get("application/octet-stream")

method append*(d: MemoryDriver, path, content: string) =
  let key = memKey(path)
  if key in d.nodes and not d.nodes[key].isDir:
    d.nodes[key].data.add(content)
    d.nodes[key].mtime = getTime()
  else:
    d.write(path, content)

# ── DavBackend helpers ───────────────────────────────────────────────────────

proc newDavBackend*(driver: StorageDriver): DavBackend =
  DavBackend(driver: driver, locks: newLockManager(),
    deadProps: initTable[string, Table[string, DeadProp]](),
    calendars: initTable[string, bool]())

proc isCalendarCollection*(b: DavBackend, urlPath: string): bool {.inline.} =
  ## True when `urlPath` was created via MKCALENDAR (CalDAV calendar).
  b.calendars.getOrDefault(urlPath, false)

proc markCalendar*(b: DavBackend, urlPath: string) {.inline.} =
  b.calendars[urlPath] = true

func toDriverPath*(urlPath: string): string {.inline.} =
  ## `/a/b` -> `a/b`; `/` -> `""`.
  urlPath.strip(chars = {'/'})

proc deadKey(ns, name: string): string {.inline.} =
  ns & "\x00" & name

proc getDead*(b: DavBackend, urlPath: string): Table[string, DeadProp] =
  b.deadProps.getOrDefault(urlPath)

proc setDead*(b: DavBackend, urlPath, ns, name, value, xml: string) =
  if urlPath notin b.deadProps:
    b.deadProps[urlPath] = initTable[string, DeadProp]()
  b.deadProps[urlPath][deadKey(ns, name)] = DeadProp(ns: ns, value: value,
    xml: xml)

proc delDead*(b: DavBackend, urlPath, ns, name: string): bool =
  if urlPath notin b.deadProps:
    return false
  if deadKey(ns, name) notin b.deadProps[urlPath]:
    return false
  b.deadProps[urlPath].del(deadKey(ns, name))
  true

proc forgetDead*(b: DavBackend, urlPath: string) =
  ## Drop dead props for a resource and, for collections, its members.
  ## Calendar markers travel with the same lifetime.
  var doomed: seq[string]
  for k in b.deadProps.keys:
    if k == urlPath or k.startsWith(urlPath & "/"):
      doomed.add(k)
  for k in doomed:
    b.deadProps.del(k)
  var doomedCal: seq[string]
  for k in b.calendars.keys:
    if k == urlPath or k.startsWith(urlPath & "/"):
      doomedCal.add(k)
  for k in doomedCal:
    b.calendars.del(k)

proc copyDead*(b: DavBackend, src, dest: string, overwrite: bool) =
  ## Duplicate dead props across COPY. For collections, remap members.
  ## The source entries stay in place. Calendar markers are carried too.
  if overwrite:
    b.forgetDead(dest)
  var carried: seq[(string, Table[string, DeadProp])]
  for k, v in b.deadProps:
    if k == src or k.startsWith(src & "/"):
      carried.add((k, v))
  for (k, v) in carried:
    let nk =
      if k == src: dest
      else: dest & k[src.len .. ^1]
    b.deadProps[nk] = v
  var carriedCal: seq[string]
  for k in b.calendars.keys:
    if k == src or k.startsWith(src & "/"):
      carriedCal.add(k)
  for k in carriedCal:
    let nk =
      if k == src: dest
      else: dest & k[src.len .. ^1]
    b.calendars[nk] = true

proc moveDead*(b: DavBackend, src, dest: string, overwrite: bool) =
  ## Carry dead props across MOVE. For collections, remap members.
  b.copyDead(src, dest, overwrite)
  b.forgetDead(src)
