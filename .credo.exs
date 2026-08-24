# This project's own purity check, run over this project.
#
# `enabled:` replaces Credo's default set rather than adding to it, which
# is what is wanted here: the point of this file is to run `mix pure`'s
# own check against the code that implements it. A project that wants
# this check alongside Credo's defaults writes `extra:` instead.
#
# The fixtures under `test/support` are deliberately impure, so a lint
# run has no business reporting them; the test suite is what asserts on
# what they say.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "mix.exs"], excluded: []},
      strict: true,
      checks: %{
        enabled: [
          {Pure.Check.Purity, []}
        ]
      }
    }
  ]
}
