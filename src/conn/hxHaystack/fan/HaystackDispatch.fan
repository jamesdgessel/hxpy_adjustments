//
// Copyright (c) 2012, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   10 Jan 2012  Brian Frank  Creation
//   17 Jul 2012  Brian Frank  Move to connExt framework
//   02 Oct 2012  Brian Frank  New Haystack 2.0 REST API
//   29 Dec 2021  Brian Frank  Redesign for Haxall
//

using concurrent
using haystack
using folio
using hx
using hxConn

**
** Dispatch callbacks for the Haystack connector
**
class HaystackDispatch : ConnDispatch
{
  new make(Obj arg)  : super(arg) {}

//////////////////////////////////////////////////////////////////////////
// Receive
//////////////////////////////////////////////////////////////////////////

  override Obj? onReceive(HxMsg msg)
  {
    msgId := msg.id
    if (msgId === "call")         return onCall(msg.a, ((Unsafe)msg.b).val, msg.c)
    if (msgId === "readById")     return onReadById(msg.a, msg.b)
    if (msgId === "readByIds")    return onReadByIds(msg.a, msg.b)
    if (msgId === "read")         return onRead(msg.a, msg.b)
    if (msgId === "readAll")      return onReadAll(msg.a)
    if (msgId === "eval")         return onEval(msg.a, msg.b)
//    if (msgId === "hisRead")      return onHisRead(msg.a, msg.b)
    if (msgId === "invokeAction") return onInvokeAction(msg.a, msg.b, msg.c)
    return super.onReceive(msg)
  }

//////////////////////////////////////////////////////////////////////////
// Open/Ping/Close
//////////////////////////////////////////////////////////////////////////

  override Void onOpen()
  {
    // gather configuration
    uriVal := rec["uri"] ?: throw FaultErr("Missing 'uri' tag")
    uri    := uriVal as Uri ?: throw FaultErr("Type of 'uri' must be Uri, not $uriVal.typeof.name")
    user   := rec["username"] as Str ?: ""
    pass   := db.passwords.get(id.toStr) ?: ""

    // open client
    opts := ["log":trace.asLog, "timeout":conn.timeout]
    client = Client.open(uri, user, pass, opts)
  }

  override Void onClose()
  {
    client = null
    // TODO
    //watchClear
  }

  override Dict onPing()
  {
    // call "about" operation
    about := client.about

    // update tags
    tags := Str:Obj[:]
    if (about["productName"]    is Str) tags["productName"]    = about->productName
    if (about["productVersion"] is Str) tags["productVersion"] = about->productVersion
    if (about["vendorName"]     is Str) tags["vendorName"]     = about->vendorName
    about.each |v, n| { if (n.startsWith("host")) tags[n] = v }

    // update tz
    tzStr := about["tz"] as Str
    if (tzStr != null)
    {
      tz := TimeZone.fromStr(tzStr, false)
      if (tz != null) tags["tz"] = tz.name
    }

    return Etc.makeDict(tags)
  }

//////////////////////////////////////////////////////////////////////////
// Call
//////////////////////////////////////////////////////////////////////////

  Unsafe onCall(Str op, Grid req, Bool checked)
  {
    Unsafe(call(op, req, checked))
  }

  Grid call(Str op, Grid req, Bool checked := true)
  {
    openClient.call(op, req, checked)
  }

  Client openClient()
  {
    open
    return client
  }

//////////////////////////////////////////////////////////////////////////
// Client Axon Functions
//////////////////////////////////////////////////////////////////////////

  Obj? onReadById(Obj id, Bool checked)
  {
    try
      return openClient.readById(id, checked)
    catch (Err err)
      return err
  }

  Obj? onReadByIds(Obj[] ids, Bool checked)
  {
    try
      return Unsafe(openClient.readByIds(ids, checked))
    catch (Err err)
      return err
  }

  Obj? onRead(Str filter, Bool checked)
  {
    try
      return openClient.read(filter, checked)
    catch (Err err)
      return err
  }

  Obj? onReadAll(Str filter)
  {
    try
      return Unsafe(openClient.readAll(filter))
    catch (Err err)
      return err
  }

  Obj? onEval(Str expr, Dict opts)
  {
    try
    {
      req := Etc.makeListGrid(opts, "expr", null, [expr])
      return Unsafe(openClient.call("eval", req))
    }
    catch (Err err) return err
  }

  Obj? onInvokeAction(Obj id, Str action, Dict args)
  {
    req := Etc.makeDictGrid(["id":id, "action":action], args)
    try
      return Unsafe(openClient.call("invokeAction", req))
    catch (Err err)
      return err
  }

//////////////////////////////////////////////////////////////////////////
// Learn
//////////////////////////////////////////////////////////////////////////

  override Grid onLearn(Obj? arg)
  {
    // lazily build and cache noLearnTags using FolioUtil
    noLearnTags := noLearnTagsRef.val as Dict
    if (noLearnTags == null)
    {
      noLearnTagsRef.val = noLearnTags = Etc.makeDict(FolioUtil.tagsToNeverLearn)
    }

    client := openClient
    req := arg == null ? Etc.makeEmptyGrid : Etc.makeListGrid(null, "navId", null, [arg])
    res := client.call("nav", req)

    learnRows := Str:Obj?[,]
    res.each |row|
    {
      // map tags
      map := Str:Obj[:]
      row.each |val, name|
      {
        if (val == null) return
        if (val is Bin) return
        if (val is Ref) return
        if (noLearnTags.has(name)) return
        map[name] = val
      }

      // make sure we have dis column
      id := row["id"] as Ref
      if (map["dis"] == null)
      {
        if (row.has("navName"))
          map["dis"] = row["navName"].toStr
        else if (id != null)
          map["dis"] = id.dis
      }

      // map addresses as either point leaf or nav node
      if (row.has("point"))
      {
        if (id != null)
        {
          if (row.has("cur"))      map["haystackCur"]   = id.toStr
          if (row.has("writable")) map["haystackWrite"] = id.toStr
          if (row.has("his"))      map["haystackHis"]   = id.toStr
        }
      }
      else
      {
        navId := row["navId"]
        if (navId != null) map["learn"] = navId
      }

      // learn row
      learnRows.add(map)
    }
    return Etc.makeMapsGrid(null, learnRows)
  }

  private static const AtomicRef noLearnTagsRef := AtomicRef()

//////////////////////////////////////////////////////////////////////////
// Fields
//////////////////////////////////////////////////////////////////////////

  private Client? client
}

