# `webdav` server configuration: built-in defaults, TOML file overlay,
# and CLI flag overrides.
#
# Precedence (highest first): explicit CLI flags > TOML file > built-ins.
# The file layer maps onto `DavConfig` via openparser's typed `fromToml`;
# keys absent from the file keep their current (default) values, unknown
# keys are ignored, and type mismatches raise `ValueError` naming the file.

import std/os
import pkg/openparser/toml

type
  DavConfig* = object
    root*: string
    port*: int
    address*: string

  DavFlags* = object
    ## Raw CLI values; empty string / zero port means "not passed".
    root*: string
    port*: int
    address*: string
    config*: string

const defaultConfigName* = "webdav.config.toml"
  ## File `webdav init` writes and `webdav serve` auto-loads from the cwd.

proc defaultDavConfig*(): DavConfig =
  DavConfig(root: getCurrentDir() / "davroot", port: 9001,
    address: "127.0.0.1")

proc defaultConfigToml*(): string =
  ## Defaults rendered as TOML: what `webdav init` writes to disk.
  # `root` stays relative so the file works wherever the project lives.
  """# webdav server config - created by `webdav init`.
# CLI flags override these values; see `webdav serve --help`.
root = "./davroot"
port = 9001
address = "127.0.0.1"
"""

proc initConfigFile*(path = defaultConfigName, force = false) =
  ## Write defaults to `path`; refuse to overwrite unless `force`.
  if fileExists(path) and not force:
    raise newException(IOError, "Config file `" & path &
      "` already exists (use --force to overwrite)")
  writeFile(path, defaultConfigToml())

proc autoConfigPath*(): string =
  ## `webdav.config.toml` in the cwd when present, else "".
  result = getCurrentDir() / defaultConfigName
  if not fileExists(result):
    result = ""

proc loadConfig*(path: string): DavConfig =
  ## Built-in defaults overlaid with the TOML file at `path`.
  result = defaultDavConfig()
  var content: string
  try:
    content = readFile(path)
  except IOError as e:
    raise newException(IOError, "Cannot read config file `" & path & "`: " & e.msg)
  try:
    fromToml(parseTOML(content), result)
  except OpenParserTomlError as e:
    raise newException(ValueError,
      "Invalid config file `" & path & "`: " & e.msg)

proc resolveConfig*(flags: DavFlags): DavConfig =
  ## Merge built-ins, optional TOML file, and explicit flags.
  result = if flags.config.len > 0: loadConfig(flags.config)
           else: defaultDavConfig()
  if flags.root.len > 0:
    result.root = flags.root
  if flags.port > 0:
    result.port = flags.port
  if flags.address.len > 0:
    result.address = flags.address
  if result.port < 1 or result.port > 65535:
    raise newException(ValueError, "Port out of range: " & $result.port)
