name = "moonframe-facade-smoke"

version = "0.1.0"

// The version pin below is decorative and deliberately unwatched: moon.work
// lists ../../.. as a member, and a workspace member is resolved from its
// local source with the @version ignored (the manifest documentation's own
// rule), so this fixture always compiles against main and never fetches the
// pinned release — the built ihb2032/MoonFrame artifacts under its _build
// come from the member tree. The pin stays spelled because `moon add` writes
// one, and a future move off the workspace would need a real number here.
import {
  "ihb2032/MoonFrame@0.7.0",
}
