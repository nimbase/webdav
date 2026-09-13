# WebDAV server and client on top of powpow.
#
# `davmethod` must be imported first so the WebDAV verbs are staged via
# pkg/voodoo before powpow compiles. Keep that order here and in user code
# (`import webdav` before any direct `import powpow`).

import webdav/davmethod
import powpow
import webdav/[types, davxml, backend, props, caldav, carddav, server, client]

export davmethod
export powpow
export types
export davxml
export backend
export props
export caldav
export carddav
export server
export client

when isMainModule:
  # Server binary: `clue build` (see `bin`/`binDir` in webdav.nimble).
  # Library users (`import webdav`) never compile this block.
  # Option values use the `--opt=value` form.
  import kapsis
  import webdav/config

  proc serveCommand(v: Values) =
    let root = if v.has("--root"): v.get("--root").getStr else: ""
    let port = if v.has("--port"): v.get("--port").getInt else: 0
    let address = if v.has("--address"): v.get("--address").getStr else: ""
    let config = if v.has("--config"): v.get("--config").getStr else: ""
    var cfgPath = config
    if root == "" and port == 0 and address == "" and config == "":
      cfgPath = autoConfigPath()
      if cfgPath == "":
        quit("serve: no options given and no ./webdav.config.toml found.\n" &
          "Run `webdav init` or `webdav serve --help`.", 1)
    let cfg = resolveConfig(DavFlags(root: root, port: port,
      address: address, config: cfgPath))
    let srv = newDavServer(newLocalDriver(cfg.root))
    echo "webdav serving " & cfg.root & " on http://" & cfg.address &
      ":" & $cfg.port
    echo "  Press Ctrl+C to stop"
    newHttpServer().start(srv.davHandler(), cfg.address, Port(cfg.port))

  proc initCommand(v: Values) =
    let path = if v.has("--path"): v.get("--path").getStr
               else: defaultConfigName
    let force = if v.has("--force"): v.get("--force").getBool else: false
    try:
      initConfigFile(path, force)
    except IOError as e:
      quit(e.msg, 1)
    echo "wrote " & path

  initKapsis do:
    commands do:
      -- "Server"
      serve ?string("--root"), ?int("--port"), ?string("--address"), ?string("--config"):
        ## Start the WebDAV server
      init ?string("--path"), ?bool("--force"):
        ## Write webdav.config.toml with default settings
