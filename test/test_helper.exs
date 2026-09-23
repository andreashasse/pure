# The stdlib sweep is slower than the rest of the suite put together:
# run it with `mix test --include stdlib`. Building a host project is
# slower still: `mix test --include host_project`.
ExUnit.start(exclude: [:stdlib, :host_project])

# Credo is a `runtime: false` dependency, so the caches its checks rely
# on to parse source files are not started for us.
{:ok, _started} = Application.ensure_all_started(:credo)
