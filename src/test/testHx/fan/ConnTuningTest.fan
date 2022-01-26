//
// Copyright (c) 2014, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   18 Aug 2014  Brian Frank  Creation
//   25 Jan 2022  Brian Frank  Refactor for Haxall
//

using concurrent
using haystack
using folio
using hx
using hxConn


**
** ConnTuningTest
**
class ConnTuningTest : HxTest
{

//////////////////////////////////////////////////////////////////////////
// Parse
//////////////////////////////////////////////////////////////////////////

  Void testParse()
  {
    r := Etc.makeDict([
        "id": Ref("a", "Test"),
        "pollTime": n(30, "ms"),
        "staleTime": n(1, "hour"),
        "writeMinTime": n(2, "sec"),
        "writeMaxTime": n(3, "sec"),
        "writeOnStart":m,
        "writeOnOpen":m,
        ])

    t := ConnTuning(r)
    verifyEq(t.id, r.id)
    verifyEq(t.dis, "Test")
    verifyEq(t.pollTime, 30ms)
    verifyEq(t.staleTime, 1hr)
    verifyEq(t.writeMinTime, 2sec)
    verifyEq(t.writeOnStart, true)
    verifyEq(t.writeOnOpen, true)
  }

//////////////////////////////////////////////////////////////////////////
// Roster
//////////////////////////////////////////////////////////////////////////

  @HxRuntimeTest
  Void testRoster()
  {
    // initial setup
    t1  := addRec(["connTuning":m, "dis":"T-1", "staleTime":n(1, "sec")])
    t2  := addRec(["connTuning":m, "dis":"T-2", "staleTime":n(2, "sec")])
    t3  := addRec(["connTuning":m, "dis":"T-3", "staleTime":n(3, "sec")])
    c   := addRec(["dis":"C", "haystackConn":m])
    pt  := addRec(["dis":"Pt", "point":m, "haystackConnRef":c.id, "kind":"Number"])
    fw  := (ConnFwLib)addLib("conn")
    lib := (ConnLib)addLib("haystack")

    // verify tuning registry in ConnFwLib
    verifyTunings(fw, [t1, t2, t3])
    t4 := addRec(["connTuning":m, "dis":"T-4", "staleTime":n(4, "sec")])
    verifyTunings(fw, [t1, t2, t3, t4])
    t4Old := fw.tunings.get(t4.id)
    t4 = commit(t4, ["dis":"T-4 New", "staleTime":n(44, "sec")])
    verifyTunings(fw, [t1, t2, t3, t4])
    verifySame(fw.tunings.get(t4.id), t4Old)
    t4 = commit(t4, ["connTuning":Remove.val])
    verifyTunings(fw, [t1, t2, t3])

    // verify ConnLib, Conn, ConnPoint tuning....

    // starting off we are using lib defaults
    verifyEq(lib.tuning.id.toStr, "haystack-default")
    verifyEq(lib.tuning.staleTime, 5min)
    verifySame(lib.tuning, lib.conn(c.id).tuning)
    verifySame(lib.tuning, lib.point(pt.id).tuning)

    // add tuning for library
    commit(lib.rec, ["connTuningRef":t1.id])
    rt.sync
    verifyEq(lib.tuning.id, t1.id)
    verifyEq(lib.conn(c.id).tuning.id, t1.id)
    verifyEq(lib.point(pt.id).tuning.id, t1.id)
    verifyEq(lib.tuning.staleTime, 1sec)
    verifySame(lib.tuning, lib.conn(c.id).tuning)
    verifySame(lib.tuning, lib.point(pt.id).tuning)
    verifyTuning(fw, lib, pt, t1, 1sec)

    // add tuning for conn
    commit(c, ["connTuningRef":t2.id])
    sync(c)
    verifyEq(lib.tuning.id, t1.id)
    verifyEq(lib.conn(c.id).tuning.id, t2.id)
    verifyEq(lib.point(pt.id).tuning.id, t2.id)
    verifyNotSame(lib.tuning, lib.conn(c.id).tuning)
    verifySame(lib.conn(c.id).tuning, lib.point(pt.id).tuning)
    verifyTuning(fw, lib, pt, t2, 2sec)

    // add tuning on point
    pt = commit(pt, ["connTuningRef":t3.id])
    sync(c)
    verifyEq(lib.tuning.id, t1.id)
    verifyEq(lib.conn(c.id).tuning.id, t2.id)
    verifyEq(lib.point(pt.id).tuning.id, t3.id)
    verifyNotSame(lib.tuning, lib.conn(c.id).tuning)
    verifyNotSame(lib.conn(c.id).tuning, lib.point(pt.id).tuning)
    verifyTuning(fw, lib, pt, t3, 3sec)

    // restart and verify everything gets wired up correctly
    rt.libs.remove("haystack")
    rt.libs.remove("conn")
    fw = addLib("conn")
    lib = addLib("haystack", ["connTuningRef":t1.id])
    sync(c)
    verifyEq(lib.tuning.id, t1.id)
    verifyEq(lib.conn(c.id).tuning.id, t2.id)
    verifyEq(lib.point(pt.id).tuning.id, t3.id)
    verifyNotSame(lib.tuning, lib.conn(c.id).tuning)
    verifyNotSame(lib.conn(c.id).tuning, lib.point(pt.id).tuning)
    verifyTuning(fw, lib, pt, t3, 3sec)

    // map pt to tuning which doesn't exist yet
    t5id := genRef("t5")
    pt = commit(pt, ["connTuningRef":t5id])
    sync(c)
    verifyEq(lib.point(pt.id).tuning.id, t5id)
    verifyEq(lib.point(pt.id).tuning.staleTime, 5min)
    verifyDictEq(lib.point(pt.id).tuning.rec, Etc.makeDict1("id", t5id))

    // now fill in t5
    t5 := addRec(["id":t5id, "dis":"T-5", "connTuning":m, "staleTime":n(123, "sec")])
    sync(c)
    verifyEq(fw.tunings.get(t5id).staleTime, 123sec)
    verifyEq(lib.point(pt.id).tuning.id, t5.id)
    verifyEq(lib.point(pt.id).tuning.staleTime, 123sec)
    verifySame(lib.point(pt.id).tuning.rec, t5)
  }

  Void verifyTunings(ConnFwLib fw, Dict[] expected)
  {
    rt.sync
    actual := fw.tunings.list.dup.sort |a, b| { a.dis <=> b.dis }
    verifyEq(actual.size, expected.size)
    actual.each |a, i|
    {
      e := expected[i]
      verifySame(a.rec, e)
      verifyEq(a.id, e.id)
      verifyEq(a.dis, e.dis)
      verifySame(fw.tunings.get(e.id), a)
    }
  }

  Void verifyTuning(ConnFwLib fw, ConnLib lib, Dict ptRec, Dict tuningRec, Duration staleTime)
  {
    pt := lib.point(ptRec.id)
    t  := fw.tunings.get(tuningRec.id)
    verifySame(pt.tuning, t)
    verifyEq(pt.tuning.staleTime, staleTime)
  }


//////////////////////////////////////////////////////////////////////////
// Times
//////////////////////////////////////////////////////////////////////////

  @HxRuntimeTest { meta = "steadyState: 10ms" }
  Void testTimes()
  {
    lib := (ConnTestLib)addLib("connTest")
    t := addRec(["connTuning":m, "dis":"T"])
    cr := addRec(["dis":"C1", "connTestConn":m])
    pt := addRec(["dis":"Pt", "point":m, "writable":m, "connTestWrite":"a", "connTestConnRef":cr.id, "connTuningRef":t.id, "kind":"Number", "writeConvert":"*10"])

    rt.sync
    c  := lib.conn(cr.id)
    sync(c)
    waitForSteadyState

    verifyWriteMinTime(c, t, pt)
    verifyWriteMaxTime(c, t, pt)
  }

  Void verifyWriteMinTime(Conn c, Dict t, Dict pt)
  {
    // initial state (first write short circuited without writeOnStart)
    verifyWrite(pt, "unknown", null, null, null, null)

    // verify two immediate writes with no min time
    write(c, pt, n(1), 16)
    pt = verifyWrite(pt, "ok", n(1), 16, n(1*10), 16)
    write(c, pt, n(2), 16)
    pt = verifyWrite(pt, "ok", n(2), 16, n(2*10), 16)
    verifyWriteDebug(pt, false, "2 @ 16 [test]")

    // now add a minWriteTime
    verifyEq(c.point(pt.id).tuning.writeMinTime, null)
    t = commit(t, ["writeMinTime":n(100, "ms")])
    sync(c)
    verifyEq(c.point(pt.id).tuning.writeMinTime, 100ms)
    write(c, pt, n(3), 15)
    pt = verifyWrite(pt, "ok", n(3), 15, n(2*10), 16)  // no change
    write(c, pt, n(4), 14)
    pt = verifyWrite(pt, "ok", n(4), 14, n(2*10), 16)  // no change
    wait(80ms)
    pt = verifyWrite(pt, "ok", n(4), 14, n(2*10), 16)  // no change

    // last write wins after minWriteTime expires
    verifyWriteDebug(pt, true, "4 @ 14 [test]")
    wait(80ms)
    forceHouseKeeping(c)
    pt = verifyWrite(pt, "ok", n(4), 14, n(4*10), 14)
    verifyWriteDebug(pt, false, "4 @ 14 [test] minTime")

    // now wait until min write time has passed
    wait(120ms)
    write(c, pt, n(5), 16)
    write(c, pt, null, 15)
    write(c, pt, null, 14)
    pt = verifyWrite(pt, "ok", n(5), 16, n(5*10), 16)  // immediate write

    // another write
    write(c, pt, n(6), 12)
    pt = verifyWrite(pt, "ok", n(6), 12, n(5*10), 16)  // no change
    wait(80ms)
    pt = verifyWrite(pt, "ok", n(6), 12, n(5*10), 16)  // no change

    // last write wins after minWriteTime expires
    verifyWriteDebug(pt, true, "6 @ 12 [test]")
    wait(80ms)
    forceHouseKeeping(c)
    pt = verifyWrite(pt, "ok", n(6), 12, n(6*10), 12)
    verifyWriteDebug(pt, false, "6 @ 12 [test] minTime")

    // cleanup
    write(c, pt, null, 12)
    t = commit(t, ["writeMinTime":Remove.val])
    sync(c)
  }

  Void verifyWriteMaxTime(Conn c, Dict t, Dict pt)
  {
    t = commit(readById(t.id), ["writeMaxTime":n(100, "ms")])

    // first write
    write(c, pt, n(77), 16)
    pt = verifyWrite(pt, "ok", n(77), 16, n(77*10), 16)
    num := numWrites(c)

    // wait and check before/after 100ms
    left := 100ms - (Duration.now - lastWriteTime(pt))
    wait(left - 20ms)
    verifyEq(numWrites(c), num)
    wait(80ms)
    forceHouseKeeping(c)
    verifyEq(numWrites(c), num+1)
    pt = verifyWrite(pt, "ok", n(77), 16, n(77*10), 16)

    // again: wait and check before/after 100ms
    left = 100ms - (Duration.now - lastWriteTime(pt))
    wait(left - 20ms)
    verifyEq(numWrites(c), num+1)
    wait(80ms)
    forceHouseKeeping(c)
    verifyEq(numWrites(c), num+2)
    pt = verifyWrite(pt, "ok", n(77), 16, n(77*10), 16)

    // immediate write
    write(c, pt, n(88), 15)
    pt = verifyWrite(pt, "ok", n(88), 15, n(88*10), 15)
    verifyEq(numWrites(c), num+3)
    verifyWriteDebug(pt, false, "88 @ 15 [test]")

    // wait and check before/after 100ms
    left = 100ms - (Duration.now - lastWriteTime(pt))
    wait(left - 20ms)
    verifyEq(numWrites(c), num+3)
    wait(80ms)
    forceHouseKeeping(c)
    verifyEq(numWrites(c), num+4)
    pt = verifyWrite(pt, "ok", n(88), 15, n(88*10), 15)
    verifyWriteDebug(pt, false, "88 @ 15 [test] maxTime")
  }

  Dict verifyWrite(Dict rec, Str status, Obj? tagVal, Int? tagLevel, Obj? lastVal, Int? lastLevel)
  {
    Conn c := rt.conn.point(rec.id).conn
    rec = readById(rec.id)
    last := c.send(HxMsg("lastWrite")).get(1sec)
    // echo("-- $rec.dis " + rec["writeStatus"] + " " + rec["writeVal"] + " @ " + rec["writeLevel"] + " | last=$last | " + rec["writeErr"])
    verifyEq(rec["writeStatus"], status)
    verifyEq(rec["writeVal"],    tagVal)
    verifyEq(rec["writeLevel"], n(tagLevel))
    if (lastVal != null) verifyEq(last, "$lastVal @ $lastLevel")
    return rec
  }

  Void verifyWriteDebug(Dict rec, Bool writePending, Str writeLastInfo)
  {
    lines       := rt.conn.point(rec.id).details.splitLines
    linePending := lines.find |x| { x.contains("writePending:") }
    lineLastInfo:= lines.find |x| { x.contains("writeLastInfo:") }
    // echo("-- $rec.dis $linePending | $lineLastInfo")
    verifyEq(linePending.split(':').last, writePending.toStr)
    verifyEq(lineLastInfo.split(':').last, writeLastInfo)
  }

//////////////////////////////////////////////////////////////////////////
// Utils
//////////////////////////////////////////////////////////////////////////


  Duration lastWriteTime(Dict pt)
  {
    Duration.make(rt.conn.point(pt.id)->writeState->lastUpdate)
  }

  Int numWrites(Conn c)
  {
    c.send(HxMsg("numWrites")).get(1sec)
  }

  Void write(Conn c, Dict rec, Obj? val, Int level)
  {
    rt.pointWrite.write(rec, val, level, "test").get
    sync(c)
  }

  Void waitForSteadyState()
  {
    while (!rt.isSteadyState) Actor.sleep(10ms)
  }

  Void wait(Duration dur)
  {
    echo("   Waiting $dur.toLocale ...")
    Actor.sleep(dur)
  }

  Void sync(Obj? c)
  {
    rt.sync
    if (c == null) return
    if (c is Conn)
      ((Conn)c).sync
    else
      ((Conn)rt.conn.conn(Etc.toId(c))).sync
  }

  Void forceHouseKeeping(Conn c)
  {
    c.forceHouseKeeping.get(1sec)
    rt.sync
  }
}