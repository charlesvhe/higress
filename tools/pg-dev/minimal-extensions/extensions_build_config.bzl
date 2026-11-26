# Native validation profile; production gateway uses the complete Higress profile.
EXTENSIONS = {
    "envoy.access_loggers.file": "//source/extensions/access_loggers/file:config",
    "envoy.clusters.static": "//source/extensions/clusters/static:static_cluster_lib",
    "envoy.filters.http.router": "//source/extensions/filters/http/router:config",
    "envoy.filters.http.wasm": "//source/extensions/filters/http/wasm:config",
    "envoy.filters.network.http_connection_manager": "//source/extensions/filters/network/http_connection_manager:config",
    "envoy.network.dns_resolver.apple": "//source/extensions/network/dns_resolver/apple:config",
    "envoy.network.dns_resolver.cares": "//source/extensions/network/dns_resolver/cares:config",
    "envoy.transport_sockets.raw_buffer": "//source/extensions/transport_sockets/raw_buffer:config",
    "envoy.transport_sockets.tls": "//source/extensions/transport_sockets/tls:config",
    "envoy.transport_sockets.starttls": "//source/extensions/transport_sockets/starttls:config",
    "envoy.wasm.runtime.wamr": "//source/extensions/wasm_runtime/wamr:config",
}

# These can be changed to ["//visibility:public"], for  downstream builds which
# need to directly reference Envoy extensions.
EXTENSION_CONFIG_VISIBILITY = ["//:extension_config", "//:contrib_library", "//:mobile_library"]
EXTENSION_PACKAGE_VISIBILITY = ["//:extension_library", "//:contrib_library", "//:mobile_library"]
CONTRIB_EXTENSION_PACKAGE_VISIBILITY = ["//:contrib_library"]
MOBILE_PACKAGE_VISIBILITY = ["//:mobile_library"]

# Set this variable to true to disable alwayslink for envoy_cc_library.
# TODO(alyssawilk) audit uses of this in source/ and migrate all libraries to extensions.
LEGACY_ALWAYSLINK = 1
