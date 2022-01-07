#! /usr/bin/env fan
// Copyright (c) 2021, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   23 Jun 2021  Brian Frank  Creation

using build

**
** Build script for conn directory
**
class Build : BuildGroup
{
  new make()
  {
    childrenScripts =
    [
      `mqtt/build.fan`,
      `hxHaystack/build.fan`,
      `hxSql/build.fan`,
      `hxMqtt/build.fan`,
    ]
  }
}

