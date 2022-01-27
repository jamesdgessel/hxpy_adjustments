#! /usr/bin/env fan
// Copyright (c) 2021, SkyFoundry LLC
// Licensed under the Academic Free License version 3.0
//
// History:
//   30 Mar 2021  Brian Frank  Creation

using build

**
** Build script for util directory
**
class Build : BuildGroup
{
  new make()
  {
    childrenScripts =
    [
      `oauth2/build.fan`,
      `ftp/build.fan`,
      `obix/build.fan`,
      `rdf/build.fan`,
      `docker/build.fan`,
    ]
  }
}

