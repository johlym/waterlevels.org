import * as esbuild from "esbuild"

const watch = process.argv.includes("--watch")

const shared = {
  bundle: true,
  format: "esm",
  minify: true,
  sourcemap: true,
  logLevel: "info"
}

// Separate entries so Propshaft can fingerprint each file. esbuild code
// splitting would emit chunk imports that do not match those fingerprints.
const builds = [
  {
    ...shared,
    entryPoints: [
      "app/javascript/application.js",
      "app/javascript/map.js",
      "app/javascript/hydrograph.js"
    ],
    outdir: "app/assets/builds",
    publicPath: "/assets"
  },
  {
    ...shared,
    entryPoints: [ "node_modules/maplibre-gl/dist/maplibre-gl-worker.mjs" ],
    outfile: "app/assets/builds/maplibre-gl-worker.js"
  }
]

if (watch) {
  const contexts = await Promise.all(builds.map((options) => esbuild.context(options)))
  await Promise.all(contexts.map((context) => context.watch()))
} else {
  await Promise.all(builds.map((options) => esbuild.build(options)))
}
