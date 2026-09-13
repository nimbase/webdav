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
  import cligen
  import webdav/config

  proc serveDav(root = "", port = 0, address = "", config = "") =
    ## Start the WebDAV server. Empty `root`/`address` and zero `port`
    ## mean "not passed": values resolve as flags > TOML file > built-ins.
    let cfg = resolveConfig(DavFlags(root: root, port: port,
      address: address, config: config))
    let srv = newDavServer(newLocalDriver(cfg.root))
    echo "webdav serving " & cfg.root & " on http://" & cfg.address &
      ":" & $cfg.port
    echo "  Press Ctrl+C to stop"
    newHttpServer().start(srv.davHandler(), cfg.address, Port(cfg.port))

  dispatch(serveDav, help = {
    "root": "Storage root directory",
    "port": "TCP port to listen on",
    "address": "Address to bind",
    "config": "TOML config file (explicit flags override file values)"
  })
