name = "moonframe-facade-smoke"

version = "0.1.0"

// The pin below is a workspace member's ignored version: moon.work lists
// ../../.. as a member, so the fixture always compiles against main. It
// carries the historical marker because the release-identity guard scans
// every manifest and this number is not MoonFrame's current release.
import {
  "ihb2032/MoonFrame@0.7.0", // doc-guard: historical: workspace member pin, resolved from source
}
