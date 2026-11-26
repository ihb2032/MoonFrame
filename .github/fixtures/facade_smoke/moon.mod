name = "moonframe-facade-smoke"

version = "0.1.0"

// The pin below is a workspace member's ignored version: moon.work lists
// ../../.. as a member, so the fixture always compiles against main. It
// carries the historical marker because the release-identity guard scans
// every manifest and this number is not MoonFrame's current release. The
// driver in the SQL entries' signatures is moondb's own, so a caller
// brings that dependency itself — the way this fixture does, to reach the
// in-memory driver its SQL smoke test runs on.
import {
  "ihb2032/MoonFrame@0.7.0", // doc-guard: historical: workspace member pin, resolved from source
  "moonbitstack/moondb@0.3.1",
}
