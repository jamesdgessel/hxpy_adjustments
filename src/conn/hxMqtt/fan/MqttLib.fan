//
// Copyright (c) 2022, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   03 Jan 2022  Matthew Giannini  Creation
//

using haystack
using hx
using hxd
using hxConn
using obs
using mqtt

**
** MQTT connector library
**
const class MqttLib : ConnLib
{
  static MqttLib? cur(Bool checked := true)
  {
    HxContext.curHx.rt.lib("mqtt", checked)
  }

  internal const MqttObservable mqtt := MqttObservable(this)

  const override Observable[] observables := [mqtt]
}

**************************************************************************
** MqttObservable
**************************************************************************

internal const class MqttObservable : Observable
{
  new make(MqttLib lib) { this.lib = lib }

  const MqttLib lib

  override Str name() { "obsMqtt" }

  protected override Subscription onSubscribe(Observer observer, Dict config)
  {
    connRef := config["obsMqttConnRef"] as Ref ?: throw Err("obsMqttConnRef not configured")
    conn    := lib.conn(connRef)
    try
    {
      msg := HxMsg("mqtt.sub", config)
      ack := conn.send(msg).get
    }
    catch (Err err)
    {
      conn.trace.asLog.err("Failed to subscribe to observable ${config}", err)
    }
    return MqttSubscription(this, observer, config)
  }

  protected override Void onUnsubscribe(Subscription s)
  {
    sub  := (MqttSubscription)s
    conn := lib.conn(sub.connRef, false)
    if (conn == null) return
    try
    {
      msg := HxMsg("mqtt.unsub", sub)
      ack := conn.send(msg).get
    }
    catch (Err err)
    {
      conn.trace.asLog.err("Failed to unsubscribe ${sub.config}", err)
    }
  }

  ** Deliver the message on the given topic to all matching subscribers
  Void deliver(Ref connRef, Str topic, Message msg)
  {
    obs := MqttObservation(this, topic, msg)
    subscriptions.each |MqttSubscription sub|
    {
      if (sub.connRef != connRef) return
      if (!sub.accept(topic)) return
      sub.send(obs)
    }
  }

  ** Return true if there are any subscriptions active for the given conn ref
  Bool connHasSubscriptions(Ref connRef)
  {
    subscriptions.any |MqttSubscription sub->Bool| { sub.connRef == connRef }
  }
}

**************************************************************************
** MqttSubscription
**************************************************************************

internal const class MqttSubscription : Subscription
{
  new make(MqttObservable observable, Observer observer, Dict config)
    : super(observable, observer, config)
  {
    this.connRef = config["obsMqttConnRef"]
    this.filter  = config["obsMqttTopic"]
  }

  ** MQTT connector ref
  const Ref connRef

  ** Configured topic filter
  const Str filter

  ** Does this subscription match the given topic
  Bool accept(Str topic) { Topic.matches(topic, filter) }
}