## CalDAV core: REPORT parsing, recurrence expansion, matching units +
## loopback MKCALENDAR / PUT gate / calendar-query / calendar-multiget.
import std/unittest
import std/strutils
import std/sets
import std/httpcore except HttpMethod

import webdav

const
  Ev1 = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Cal//EN
BEGIN:VEVENT
UID:ev1@test
DTSTAMP:20260101T000000Z
DTSTART:20260105T100000Z
DTEND:20260105T110000Z
SUMMARY:One-off
END:VEVENT
END:VCALENDAR
"""
  EvDaily = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Cal//EN
BEGIN:VEVENT
UID:daily@test
DTSTAMP:20260101T000000Z
DTSTART:20260101T090000Z
DTEND:20260101T100000Z
RRULE:FREQ=DAILY;COUNT=10
SUMMARY:Standup
END:VEVENT
END:VCALENDAR
"""
  Todo1 = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Cal//EN
BEGIN:VTODO
UID:td1@test
DTSTAMP:20260101T000000Z
DUE:20260201T120000Z
SUMMARY:Taxes
END:VTODO
END:VCALENDAR
"""

  QueryJan5 = """<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:prop><D:getetag/><C:calendar-data/></D:prop>
<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
<C:time-range start="20260105T000000Z" end="20260106T000000Z"/>
</C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>"""

  QueryFeb = """<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
<D:prop><D:getetag/><C:calendar-data/></D:prop>
<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
<C:time-range start="20260201T000000Z" end="20260202T000000Z"/>
</C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>"""

proc unix(s: string): int64 =
  icalToUnix(parseIcalDateTime(s))

suite "report parsing":
  test "multiget hrefs and prop selector":
    let r = parseCalReport(
      """<C:calendar-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
      """<D:prop><D:getetag/><C:calendar-data/><D:displayname/></D:prop>""" &
      """<D:href>/cal/a.ics</D:href><D:href>/cal/b.ics</D:href>""" &
      """</C:calendar-multiget>""")
    check r.kind == rkMultiget
    check r.hrefs == @["/cal/a.ics", "/cal/b.ics"]
    check r.wantEtag == true
    check r.wantCalData == true
    check r.extraProps == @["displayname"]

  test "query comp-filter and time-range":
    let r = parseCalReport(QueryJan5)
    check r.kind == rkQuery
    check r.compName == "VEVENT"
    check r.hasTimeRange == true
    check r.timeRange.hasStart and r.timeRange.hasEnd
    check r.timeRange.startUnix == unix("20260105T000000Z")
    check r.timeRange.endUnix == unix("20260106T000000Z")

  test "query without filter matches all":
    let r = parseCalReport(
      """<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
      """<D:prop><D:getetag/></D:prop></C:calendar-query>""")
    check r.compName == ""
    check r.hasTimeRange == false

  test "report errors are DavXmlError":
    expect DavXmlError:
      discard parseCalReport("")
    expect DavXmlError:
      discard parseCalReport("""<D:propfind xmlns:D="DAV:"/>""")
    expect DavXmlError:
      discard parseCalReport(
        """<C:calendar-multiget xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
        """<D:prop xmlns:D="DAV:"><D:getetag/></D:prop>""" &
        """</C:calendar-multiget>""")
    expect DavXmlError:
      discard parseCalReport(
        """<C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
        """<D:prop xmlns:D="DAV:"><D:getetag/></D:prop>""" &
        """<C:filter><C:comp-filter name="VCALENDAR">""" &
        """<C:comp-filter name="VEVENT"><C:time-range start="nope"/>""" &
        """</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>""")

  test "mkcalendar body props":
    check parseMkcalendarProps("").len == 0
    check parseMkcalendarProps("  ").len == 0
    let ps = parseMkcalendarProps(
      """<C:mkcalendar xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
      """<D:set xmlns:D="DAV:"><D:prop>""" &
      """<D:displayname>Work</D:displayname>""" &
      """</D:prop></D:set></C:mkcalendar>""")
    check ps.len == 1
    check ps[0].name == "displayname"
    check ps[0].value == "Work"
    expect DavXmlError:
      discard parseMkcalendarProps("""<D:mkcol xmlns:D="DAV:"/>""")

suite "recurrence expansion":
  test "daily count":
    let s = unix("20260101T090000Z")
    let occ = expandStarts(s, parseRrule("FREQ=DAILY;COUNT=3"),
      initHashSet[int64](), (false, 0'i64), (false, 0'i64))
    check occ == @[s, s + 86400, s + 2 * 86400]

  test "weekly byday across weeks":
    # 2026-01-05 is a Monday.
    check weekdayMon1(unix("20260105T000000Z")) == 1
    let s = unix("20260105T090000Z")
    let occ = expandStarts(s, parseRrule("FREQ=WEEKLY;COUNT=4;BYDAY=MO,WE"),
      initHashSet[int64](), (false, 0'i64), (false, 0'i64))
    check occ.len == 4
    check occ[0] == s
    check occ[1] == unix("20260107T090000Z")
    check occ[2] == unix("20260112T090000Z")
    check occ[3] == unix("20260114T090000Z")

  test "until stops, exdate consumes count":
    let s = unix("20260101T090000Z")
    let u = expandStarts(s, parseRrule("FREQ=DAILY;UNTIL=20260103T090000Z"),
      initHashSet[int64](), (false, 0'i64), (false, 0'i64))
    check u == @[s, s + 86400, s + 2 * 86400]
    var ex = initHashSet[int64]()
    ex.incl(s + 86400)
    let e = expandStarts(s, parseRrule("FREQ=DAILY;COUNT=2"), ex,
      (false, 0'i64), (false, 0'i64))
    check e == @[s]

  test "monthly clamps day overflow, yearly steps":
    let s = unix("20260131T120000Z")
    let m = expandStarts(s, parseRrule("FREQ=MONTHLY;COUNT=2"),
      initHashSet[int64](), (false, 0'i64), (false, 0'i64))
    check m.len == 2
    check m[1] == unix("20260228T120000Z")
    let y = expandStarts(s, parseRrule("FREQ=YEARLY;COUNT=2"),
      initHashSet[int64](), (false, 0'i64), (false, 0'i64))
    check y[1] == unix("20270131T120000Z")

  test "range end stops unbounded rules, unknown freq is base-only":
    let s = unix("20260101T090000Z")
    let r = expandStarts(s, parseRrule("FREQ=DAILY"),
      initHashSet[int64](), (false, 0'i64), (true, s + 86400 * 5 div 2))
    check r == @[s, s + 86400, s + 2 * 86400]
    let h = expandStarts(s, parseRrule("FREQ=HOURLY"),
      initHashSet[int64](), (false, 0'i64), (false, 0'i64))
    check h == @[s]

suite "matching":
  test "plain event in and out of range":
    var tr = CalTimeRange(hasStart: true, hasEnd: true,
      startUnix: unix("20260105T000000Z"), endUnix: unix("20260106T000000Z"))
    check resourceMatches(Ev1, "VEVENT", tr, true) == true
    var feb = CalTimeRange(hasStart: true, hasEnd: true,
      startUnix: unix("20260201T000000Z"), endUnix: unix("20260202T000000Z"))
    check resourceMatches(Ev1, "VEVENT", feb, true) == false
    check resourceMatches(Ev1, "VTODO", tr, true) == false
    check resourceMatches(Ev1, "", tr, false) == true

  test "recurring daily matches a later window only":
    var jan5 = CalTimeRange(hasStart: true, hasEnd: true,
      startUnix: unix("20260105T000000Z"), endUnix: unix("20260106T000000Z"))
    check resourceMatches(EvDaily, "VEVENT", jan5, true) == true
    var feb = CalTimeRange(hasStart: true, hasEnd: true,
      startUnix: unix("20260201T000000Z"), endUnix: unix("20260202T000000Z"))
    check resourceMatches(EvDaily, "VEVENT", feb, true) == false

  test "vtodo due containment":
    var wide = CalTimeRange(hasStart: true, hasEnd: true,
      startUnix: unix("20260101T000000Z"), endUnix: unix("20260301T000000Z"))
    check resourceMatches(Todo1, "VTODO", wide, true) == true
    var after = CalTimeRange(hasStart: true, hasEnd: true,
      startUnix: unix("20260301T000000Z"), endUnix: unix("20260401T000000Z"))
    check resourceMatches(Todo1, "VTODO", after, true) == false

  test "garbage never matches, content gate":
    var tr = CalTimeRange(hasStart: true, hasEnd: true,
      startUnix: unix("20260101T000000Z"), endUnix: unix("20260301T000000Z"))
    check resourceMatches("not ical at all", "VEVENT", tr, true) == false
    check resourceMatches("not ical at all", "", tr, false) == false
    check isCalendarContent(Ev1) == true
    check isCalendarContent(Todo1) == true
    check isCalendarContent("junk") == false
    check isCalendarContent(
      "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n") == false

template withCal(port: int, body: untyped) =
  block:
    let client {.inject.} = newHttpClient()
    let srv {.inject.} = newDavServer(newMemoryDriver())
    let calServer = newHttpServer(client.getLoop())
    calServer.handler = srv.davHandler()
    calServer.listen("127.0.0.1", port)
    let base {.inject.} = "http://127.0.0.1:" & $port
    try:
      body
    finally:
      calServer.close()
      client.close()

suite "mkcalendar loopback":
  test "create, duplicate, parent missing, propfind shows calendar":
    withCal(20956):
      check client.request(HttpMkcalendar, base & "/cal").getStatusCode() == Http201
      check client.request(HttpMkcalendar, base & "/cal").getStatusCode() == Http405
      check client.request(HttpMkcalendar, base & "/no/such").getStatusCode() == Http409
      let f = client.request(HttpPropfind, base & "/cal", "",
        [("Depth", "0")])
      check f.getStatusCode() == Http207
      let fb = f.getBodyString()
      check "calendar" in fb
      check "getctag" in fb
      check "calendar-multiget" in fb

  test "protected body prop is 403, displayname sticks":
    withCal(20957):
      let bad = """<C:mkcalendar xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
        """<D:set xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:set>""" &
        """</C:mkcalendar>"""
      check client.request(HttpMkcalendar, base & "/bad", bad).getStatusCode() == Http403
      check client.request(HttpPropfind, base & "/bad", "",
        [("Depth", "0")]).getStatusCode() == Http404
      let good = """<C:mkcalendar xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
        """<D:set xmlns:D="DAV:"><D:prop>""" &
        """<D:displayname>Work</D:displayname>""" &
        """</D:prop></D:set></C:mkcalendar>"""
      check client.request(HttpMkcalendar, base & "/good", good).getStatusCode() == Http201
      let f = client.request(HttpPropfind, base & "/good",
        """<D:propfind xmlns:D="DAV:"><D:prop><D:displayname/>""" &
        """</D:prop></D:propfind>""", [("Depth", "0")])
      check f.getStatusCode() == Http207
      check "Work" in f.getBodyString()

suite "put gate loopback":
  test "calendar takes ics, rejects junk; plain dirs unaffected":
    withCal(20958):
      check client.request(HttpMkcalendar, base & "/cal").getStatusCode() == Http201
      check client.request(HttpPut, base & "/cal/ev1.ics", Ev1).getStatusCode() == Http201
      check client.request(HttpPut, base & "/cal/junk.ics",
        "hello").getStatusCode() == Http400
      check client.request(HttpPut, base & "/plain.txt",
        "hello").getStatusCode() == Http201

suite "calendar-query loopback":
  test "time-range selects matching events incl. recurrences":
    withCal(20959):
      discard client.request(HttpMkcalendar, base & "/cal")
      discard client.request(HttpPut, base & "/cal/ev1.ics", Ev1)
      discard client.request(HttpPut, base & "/cal/daily.ics", EvDaily)
      discard client.request(HttpPut, base & "/cal/todo.ics", Todo1)
      let q = client.request(HttpReport, base & "/cal", QueryJan5,
        [("Depth", "1")])
      check q.getStatusCode() == Http207
      let qb = q.getBodyString()
      check "ev1.ics" in qb
      check "daily.ics" in qb
      check "todo.ics" notin qb
      check "BEGIN:VCALENDAR" in qb
      let qf = client.request(HttpReport, base & "/cal", QueryFeb,
        [("Depth", "1")])
      check qf.getStatusCode() == Http207
      check "D:response" notin qf.getBodyString()

  test "non-calendar target is 403, infinity depth is 400":
    withCal(20960):
      discard client.request(HttpMkcol, base & "/plain")
      check client.request(HttpReport, base & "/plain", QueryJan5,
        [("Depth", "1")]).getStatusCode() == Http403
      discard client.request(HttpMkcalendar, base & "/cal")
      check client.request(HttpReport, base & "/cal", QueryJan5,
        [("Depth", "infinity")]).getStatusCode() == Http400
      check client.request(HttpReport, base & "/cal",
        """<D:propfind xmlns:D="DAV:"/>""").getStatusCode() == Http501

suite "calendar-multiget loopback":
  test "href list with data, etag, and 404 entry":
    withCal(20961):
      discard client.request(HttpMkcalendar, base & "/cal")
      discard client.request(HttpPut, base & "/cal/ev1.ics", Ev1)
      discard client.request(HttpPut, base & "/cal/daily.ics", EvDaily)
      let mg = """<C:calendar-multiget xmlns:D="DAV:" """ &
        """xmlns:C="urn:ietf:params:xml:ns:caldav">""" &
        """<D:prop><D:getetag/><C:calendar-data/></D:prop>""" &
        """<D:href>/cal/ev1.ics</D:href>""" &
        """<D:href>/cal/missing.ics</D:href>""" &
        """</C:calendar-multiget>"""
      let m = client.request(HttpReport, base & "/cal", mg)
      check m.getStatusCode() == Http207
      let mb = m.getBodyString()
      check "ev1.ics" in mb
      check "BEGIN:VCALENDAR" in mb
      check "getetag" in mb
      check "404 Not Found" in mb

suite "ctag and marker lifetime":
  test "ctag moves on put, copy carries the calendar flag":
    withCal(20962):
      discard client.request(HttpMkcalendar, base & "/cal")
      let tagBody = """<D:propfind xmlns:D="DAV:"><D:prop><D:getctag/>""" &
        """</D:prop></D:propfind>"""
      let t1 = client.request(HttpPropfind, base & "/cal", tagBody,
        [("Depth", "0")]).getBodyString()
      discard client.request(HttpPut, base & "/cal/ev1.ics", Ev1)
      let t2 = client.request(HttpPropfind, base & "/cal", tagBody,
        [("Depth", "0")]).getBodyString()
      check t1 != t2
      check client.request(HttpCopy, base & "/cal", "",
        [("Destination", base & "/cal2")]).getStatusCode() == Http201
      let q = client.request(HttpReport, base & "/cal2", QueryFeb,
        [("Depth", "1")])
      check q.getStatusCode() == Http207
