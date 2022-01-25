//
// Copyright (c) 2016, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   20 Jan 2022  Matthew Giannini  Creation
//

using concurrent
using haystack
using hx

**
** Serial ports management
**
const class SerialLib : HxLib
{

//////////////////////////////////////////////////////////////////////////
// Constructor
//////////////////////////////////////////////////////////////////////////

  new make()
  {
    this.serialSpi = rt.config.makeSpi("serialSpi")
    // learn ports once and cache them for quick lookup
    this.portsMap  = Str:SerialPort[:] { ordered = true }.addList(serialSpi.ports) { it.name }
  }

  private const Duration timeout := 1min
  private const SerialSpi serialSpi
  private const Str:SerialPort portsMap

//////////////////////////////////////////////////////////////////////////
// Serial API
//////////////////////////////////////////////////////////////////////////

  ** List available ports and their current status
  SerialPort[] ports() { portsMap.vals }

  ** Lookup a serial port by its logical name
  SerialPort? port(Str name, Bool checked := true)
  {
    p := portsMap[name]
    if (p != null) return p
    if (checked) throw UnknownSerialPortErr(name)
    return null
  }

  ** Open a serial port with the given configuration.
  ** Raise an error if the port is already bound to another owner.
  SerialSocket open(HxRuntime rt, Dict owner, SerialConfig config)
  {
    ((Unsafe)spi.actor.send(HxMsg("open", rt, owner, config)).get(timeout)).val
  }

  ** Implementation for `SerialSocket.close`
  internal Void close(SerialSocket socket)
  {
    spi.actor.send(HxMsg("close", Unsafe(socket))).get(timeout)
  }

//////////////////////////////////////////////////////////////////////////
// Actor
//////////////////////////////////////////////////////////////////////////

  override Obj? onReceive(HxMsg msg)
  {
    switch (msg.id)
    {
      case "open":  return doOpen(msg.a, msg.b, msg.c)
      case "close": return doClose(((Unsafe)msg.a).val)
      default:      throw Err("Unknown msg type: $msg")
    }
  }

  private Unsafe doOpen(HxRuntime rt, Dict owner, SerialConfig config)
  {
    // sanity check owner is in project
    rec := rt.db.readById(owner.id, false)
    if (rec == null) throw ArgErr("Owner is not rec in runtime: $owner.id")

    // lookup port and ensure is available
    serialPort := port(config.name)
    if (serialPort.isOpen) throw SerialPortAlreadyOpenErr("Owner: $serialPort.owner.id.toZinc")

    // open the serial port
    socket := serialSpi.open(serialPort, config)

    // update internal state
    serialPort.rtRef.val = rt
    serialPort.ownerRef.val = owner
    socket.isClosedRef.val = false

    return Unsafe(socket)
  }

  private Obj? doClose(SerialSocket socket)
  {
    serialPort := this.port(socket.name)

    // manage internal state
    serialPort.rtRef.val = null
    serialPort.ownerRef.val = null
    socket.isClosedRef.val = true

    // route to spi
    serialSpi.close(socket)

    return null
  }
}