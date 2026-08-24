# The stdlib sweep is slower than the rest of the suite put together:
# run it with `mix test --include stdlib`.
ExUnit.start(exclude: [:stdlib])

# Credo is a `runtime: false` dependency, so the caches its checks parse
# source files through are not started for us.
{:ok, _started} = Application.ensure_all_started(:credo)
