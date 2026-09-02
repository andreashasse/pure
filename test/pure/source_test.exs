defmodule Pure.SourceTest do
  use ExUnit.Case, async: true

  alias Pure.Source

  doctest Pure.Source

  defp annotations(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    Source.annotations(ast)
  end

  defp functions(source) do
    [module] = annotations(source)

    for function <- module.functions do
      {function.name, function.arity, function.public?, value(function.annotation)}
    end
  end

  defp value(nil), do: nil
  defp value(%{value: value}), do: value

  test "a file that claims nothing is nobody's business" do
    assert annotations("""
           defmodule Plain do
             def add(a, b), do: a + b
           end
           """) == []
  end

  test "the module, the line and the value are all kept" do
    [module] =
      annotations("""
      defmodule Payments.Core do
        @pure true
        def fee(amount), do: amount
      end
      """)

    assert module.module == Payments.Core
    assert module.line == 1
    assert module.annotation == nil
    assert [%{name: :fee, arity: 1, line: 3, public?: true}] = module.functions
  end

  test "a module annotation is read apart from the functions it covers" do
    [module] =
      annotations("""
      defmodule Core do
        @pure_module except: [:time]
        def fee(amount), do: amount
      end
      """)

    assert module.annotation == %{value: [except: [:time]], line: 2}
    assert [%{name: :fee, annotation: nil}] = module.functions
  end

  test "the annotation belongs to the definition, not to every later one" do
    assert functions("""
           defmodule Core do
             @pure true
             def first(x), do: x
             def second(x), do: x
           end
           """) == [{:first, 1, true, true}, {:second, 1, true, nil}]
  end

  test "anything in between leaves the annotation standing" do
    assert functions("""
           defmodule Core do
             @pure except: [:io]
             @doc "writes"
             @spec log(term()) :: :ok
             def log(x), do: IO.puts(x)
           end
           """) == [{:log, 1, true, [except: [:io]]}]
  end

  test "clauses of one function are one function" do
    assert functions("""
           defmodule Core do
             @pure true
             def run(0), do: :zero
             def run(n) when n > 0, do: n
           end
           """) == [{:run, 1, true, true}]
  end

  test "an annotation above a later clause still belongs to the function" do
    assert functions("""
           defmodule Core do
             def run(0), do: :zero
             @pure true
             def run(n), do: n
           end
           """) == [{:run, 1, true, true}]
  end

  test "a default argument is annotated at every arity it produces" do
    assert functions("""
           defmodule Core do
             @pure true
             def fee(amount, rate \\\\ 0.03, cap \\\\ nil), do: {amount, rate, cap}
           end
           """) == [
             {:fee, 1, true, true},
             {:fee, 2, true, true},
             {:fee, 3, true, true}
           ]
  end

  test "private functions are told apart from public ones" do
    assert functions("""
           defmodule Core do
             @pure true
             def public(x), do: private(x)
             @pure true
             defp private(x), do: x
           end
           """) == [{:public, 1, true, true}, {:private, 1, false, true}]
  end

  test "a delegated function is a function" do
    assert functions("""
           defmodule Core do
             @pure true
             defdelegate fee(amount), to: Other
           end
           """) == [{:fee, 1, true, true}]
  end

  test "a function with no arguments" do
    assert functions("""
           defmodule Core do
             @pure true
             def zero, do: 0
           end
           """) == [{:zero, 0, true, true}]
  end

  test "nested modules are named and scanned in their own right" do
    modules =
      annotations("""
      defmodule Outer do
        @pure_module true

        defmodule Inner do
          @pure true
          def inner(x), do: x
        end

        def outer(x), do: x
      end
      """)

    assert Enum.map(modules, & &1.module) == [Outer, Outer.Inner]
    assert [%{functions: [%{name: :outer}]}, %{functions: [%{name: :inner}]}] = modules
  end

  test "a module that claims nothing is left out even when its neighbour claims" do
    assert annotations("""
           defmodule Quiet do
             def add(a, b), do: a + b
           end

           defmodule Loud do
             @pure true
             def add(a, b), do: a + b
           end
           """)
           |> Enum.map(& &1.module) == [Loud]
  end

  test "a value that will not parse is still found, so it can be reported" do
    assert functions("""
           defmodule Core do
             @pure :yes
             def fee(amount), do: amount
           end
           """) == [{:fee, 1, true, :yes}]
  end
end
