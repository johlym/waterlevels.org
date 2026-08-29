# MapLibre ships an ESM worker. Propshaft looks up Content-Type by extension;
# without this, .mjs assets are served with an empty type and Chrome will not
# execute them as module workers.
Mime::Type.register "text/javascript", :mjs unless Mime::Type.lookup_by_extension("mjs")
