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

  Void start()
  {
    // initialize conns (which in turn initializes points)
    initConns

    // subscribe to connector recs
    lib.observe("obsCommits",
      Etc.makeDict([
        "obsAdds":    Marker.val,
        "obsUpdates": Marker.val,
        "obsRemoves": Marker.val,
        "syncable":   Marker.val,
        "obsFilter":  lib.model.connTag
      ]), ConnLib#onConnEvent)

    // subscribe to connector points
    lib.observe("obsCommits",
      Etc.makeDict([
        "obsAdds":    Marker.val,
        "obsUpdates": Marker.val,
        "obsRemoves": Marker.val,
        "syncable":   Marker.val,
        "obsFilter":  "point and $lib.model.connRefTag"
      ]), ConnLib#onPointEvent)
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
      onConnUpdated(conn(e.id), e.newRec)
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

  private Void onConnUpdated(Conn conn, Dict rec)
  {
    conn.updateRec(rec)
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
      onPointUpdated(e.id, e.newRec)
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

  private Void onPointUpdated(Ref id, Dict rec)
  {
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
  }

  private Ref pointConnRef(Dict rec)
  {
    rec[lib.model.connRefTag] as Ref ?: Ref.nullRef
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
  private const ConcurrentMap connsById := ConcurrentMap()
  private const ConcurrentMap pointsById := ConcurrentMap()

}