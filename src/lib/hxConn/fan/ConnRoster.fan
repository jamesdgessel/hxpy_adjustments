//
// Copyright (c) 2021, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   27 Dec 2021  Brian Frank  Creation
//

using concurrent
using haystack
using obs
using hx

**
** ConnRoster manages the data structures for conn and point lookups
** for a given connector type.  It handles the observable events.
**
internal const final class ConnRoster
{

//////////////////////////////////////////////////////////////////////////
// Construction
//////////////////////////////////////////////////////////////////////////

  new make(ConnLib lib) { this.lib = lib }

//////////////////////////////////////////////////////////////////////////
// Lookups
//////////////////////////////////////////////////////////////////////////

  Int numConns()
  {
    connsById.size
  }

  Conn[] conns()
  {
    connsById.vals(Conn#)
  }

  Conn? conn(Ref id, Bool checked := true)
  {
    conn := connsById.get(id)
    if (conn != null) return conn
    if (checked) throw UnknownConnErr("Connector not found: $id.toZinc")
    return null
  }

  ConnPoint[] points()
  {
    pointsById.vals(ConnPoint#)
  }

  ConnPoint? point(Ref id, Bool checked := true)
  {
    pt := pointsById.get(id)
    if (pt != null) return pt
    if (checked) throw UnknownConnPointErr("Connector point not found: $id.toZinc")
    return null
  }

//////////////////////////////////////////////////////////////////////////
// Lifecycle
//////////////////////////////////////////////////////////////////////////

  Void start(ConnModel model)
  {
    // model init
    hasBuckets.val = model.pollMode === ConnPollMode.buckets

    // initialize conns (which in turn initializes points)
    initConns

    // subscribe to connector rec commits
    lib.observe("obsCommits",
      Etc.makeDict([
        "obsAdds":    Marker.val,
        "obsUpdates": Marker.val,
        "obsRemoves": Marker.val,
        "syncable":   Marker.val,
        "obsFilter":  lib.model.connTag
      ]), ConnLib#onConnEvent)

    // subscribe to connector point commits
    lib.observe("obsCommits",
      Etc.makeDict([
        "obsAdds":    Marker.val,
        "obsUpdates": Marker.val,
        "obsRemoves": Marker.val,
        "syncable":   Marker.val,
        "obsFilter":  "point and $lib.model.connRefTag"
      ]), ConnLib#onPointEvent)

    // subscribe to connector point watches
    lib.observe("obsWatches",
      Etc.makeDict([
        "obsFilter":  "point and $lib.model.connRefTag"
      ]), ConnLib#onPointWatch)
  }

  private Void initConns()
  {
    filter := Filter.has(lib.model.connTag)
    lib.rt.db.readAllEach(filter, Etc.emptyDict) |rec|
    {
      onConnAdded(rec)
    }
  }

//////////////////////////////////////////////////////////////////////////
// Conn Rec Events
//////////////////////////////////////////////////////////////////////////

  internal Void onConnEvent(CommitObservation e)
  {
    if (e.isAdded)
    {
      onConnAdded(e.newRec)
    }
    else if (e.isUpdated)
    {
      onConnUpdated(conn(e.id), e)
    }
    else if (e.isRemoved)
    {
      onConnRemoved(conn(e.id))
    }
  }

  private Void onConnAdded(Dict rec)
  {
    // create connector instance
    conn := Conn(lib, rec)

    // add it to my lookup tables
    service := lib.fw.service
    connsById.add(conn.id, conn)
    service.addConn(conn)

    // find any points already created bound to this connector
    filter := Filter.has("point").and(Filter.eq(lib.model.connRefTag, conn.id))
    pointsList := ConnPoint[,]
    lib.rt.db.readAllEach(filter, Etc.emptyDict) |pointRec|
    {
      point := ConnPoint(conn, pointRec)
      pointsList.add(point)
      pointsById.add(point.id, point)
      service.addPoint(point)
    }
    conn.updatePointsList(pointsList)
  }

  private Void onConnUpdated(Conn conn, CommitObservation e)
  {
    conn.updateRec(e.newRec)
    if (e.tagUpdated("connTuningRef")) updateBuckets(conn)
    conn.send(HxMsg("connUpdated"))
  }

  private Void onConnRemoved(Conn conn)
  {
    // mark this connector as not alive anymore
    conn.kill

    // remove all its points from lookup tables
    service := lib.fw.service
    conn.points.each |pt|
    {
      service.removePoint(pt)
      pointsById.remove(pt.id)
    }

    // remove conn from lookup tables
    service.removeConn(conn)
    connsById.remove(conn.id)
  }

//////////////////////////////////////////////////////////////////////////
// Point Events
//////////////////////////////////////////////////////////////////////////

  internal Void onPointEvent(CommitObservation e)
  {
    if (e.isAdded)
    {
      onPointAdded(e.newRec)
    }
    else if (e.isUpdated)
    {
      onPointUpdated(e)
    }
    else if (e.isRemoved)
    {
      onPointRemoved(e.id)
    }
  }

  private Void onPointAdded(Dict rec)
  {
    // lookup conn, if not found ignore it
    connRef := pointConnRef(rec)
    conn := conn(connRef, false)
    if (conn == null) return

    // create instance
    point := ConnPoint(conn, rec)

    // add to lookup tables
    pointsById.add(point.id, point)
    updateConnPoints(conn)
    lib.fw.service.addPoint(point)
    conn.send(HxMsg("pointAdded", point))
  }

  private Void onPointUpdated(CommitObservation e)
  {
    id := e.id
    rec := e.newRec

    // lookup existing point
    point := point(id, false)

    // if point doesn't exist it previously didn't map to a
    // connector, but now it might so give it another go
    if (point == null)
    {
      onPointAdded(rec)
      return
    }

    // if the conn ref has changed, then we consider this remove/add
    connRef := pointConnRef(rec)
    if (point.conn.id != connRef)
    {
      onPointRemoved(id)
      onPointAdded(rec)
      return
    }

    // normal update
    point.onUpdated(rec)
    if (e.tagUpdated("connTuningRef")) updateBuckets(point.conn)
    point.conn.send(HxMsg("pointUpdated", point))
  }

  private Void onPointRemoved(Ref id)
  {
    // lookup point, if not found we can ignore
    point := point(id, false)
    if (point == null) return

    // remove from lookup tables
    pointsById.remove(id)
    updateConnPoints(point.conn)
    lib.fw.service.removePoint(point)
    point.conn.send(HxMsg("pointRemoved", point))
  }

  private Void updateConnPoints(Conn conn)
  {
    acc := ConnPoint[,]
    acc.capacity = conn.points.size + 4
    pointsById.each |ConnPoint pt|
    {
      if (pt.conn === conn) acc.add(pt)
    }
    conn.updatePointsList(acc)
    updateBuckets(conn)
  }

  private Ref pointConnRef(Dict rec)
  {
    rec[lib.model.connRefTag] as Ref ?: Ref.nullRef
  }

//////////////////////////////////////////////////////////////////////////
// Watch Events
//////////////////////////////////////////////////////////////////////////

  internal Void onPointWatch(Observation e)
  {
    // parse event
    isWatch := e.subType == "watch"
    type := isWatch ? "watch" : "unwatch"
    recs := (Dict[])e["recs"]

    // walk thru the records grouping the points by connector
    groupsByConn := Ref:ConnPoint[][:]
    recs.each |rec|
    {
      // lookup point
      pt := point(rec.id, false)
      if (pt == null) return

      // add to groups keyed by connector id
      group := groupsByConn[pt.conn.id]
      if (group == null) groupsByConn[pt.conn.id] = group = ConnPoint[,] { it.capacity = recs.size }
      group.add(pt)
    }

    // fire msg to connectors
    groupsByConn.each |group|
    {
      group.first.conn.send(HxMsg(type, group))
    }
  }

//////////////////////////////////////////////////////////////////////////
// Buckets
//////////////////////////////////////////////////////////////////////////

  private Void updateBuckets(Conn conn)
  {
    if (!hasBuckets.val) return

    // group by tuning id
    byTuningId := Ref:ConnPoint[][:]
    conn.points.each |pt|
    {
      tuningId := pt.tuning.id
      bucket := byTuningId[tuningId]
      if (bucket == null) byTuningId[tuningId] = bucket = ConnPoint[,]
      bucket.add(pt)
    }

    // flatten to list
    acc := ConnPollBucket[,]
    byTuningId.each |points|
    {
      tuning := points.first.tuning
      acc.add(ConnPollBucket(conn, tuning, points))
    }

    // sort by poll time; this could potentially get out of
    // order if ConnTuning have their pollTime changed - but
    // that is ok because sort order is for display, not logic
    conn.pollBucketsRef.val = acc.sort.toImmutable
  }

//////////////////////////////////////////////////////////////////////////
// Utiils
//////////////////////////////////////////////////////////////////////////

  Void removeAll()
  {
    service := lib.fw.service
    pointsById.each |pt| { service.removePoint(pt) }
    connsById.each |c| { service.removeConn(c) }
  }

  Void dump()
  {
    echo("--- $lib.name roster [$connsById.size conns, $pointsById.size points] ---")
    conns := conns.dup.sort |a, b| { a.dis <=> b.dis }
    conns.each |c|
    {
      echo("  - $c.id.toZinc [$c.points.size]")
      c.points.each |pt| { echo("    - $pt.id.toZinc") }
    }
  }

//////////////////////////////////////////////////////////////////////////
// Fields
//////////////////////////////////////////////////////////////////////////

  private const ConnLib lib
  private const AtomicBool hasBuckets := AtomicBool()
  private const ConcurrentMap connsById := ConcurrentMap()
  private const ConcurrentMap pointsById := ConcurrentMap()

}