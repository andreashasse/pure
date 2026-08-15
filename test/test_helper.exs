# The stdlib sweep is slower than the rest of the suite put together:
# run it with `mix test --include stdlib`.
ExUnit.start(exclude: [:stdlib])
