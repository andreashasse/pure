defmodule PureFun.Presets do
  @moduledoc """
  Reviewed `:known` tables for libraries that the analysis cannot settle
  on its own.

  Ecto and Gettext decide most of what they do at runtime: a changeset
  casts through whatever `Ecto.Type` a field has, and a translation goes
  through a backend and a logger. Followed call by call, that makes every
  changeset impure for reasons that have nothing to do with the
  changeset. A preset states the answer for the public API instead:

      def project do
        [
          pure_fun: [
            presets: [:ecto, :gettext],
            known: %{{MyLib.Money, :add, 2} => :pure}
          ]
        ]
      end

  `:known` wins over a preset, so a project can still correct one entry.
  The presets are atoms rather than calls because `mix.exs` is read
  before any dependency is compiled. Where the code is already compiled,
  as in `.credo.exs`, `ecto/0` and `gettext/0` return the tables
  themselves.

      iex> PureFun.Presets.ecto()[{Ecto.Changeset, :validate_required, 3}]
      :pure

      iex> PureFun.Presets.gettext()[{Gettext, :dgettext, 3}]
      {:impure, :process_dictionary}
  """

  alias PureFun.Knowledge

  @type name :: :ecto | :gettext
  @type table :: %{mfa() => Knowledge.answer()}

  # A query needs a database, and the database is on the other side of a
  # socket.
  @ecto_impure %{
    {Ecto.Changeset, :unsafe_validate_unique, 3} => {:impure, :network},
    {Ecto.Changeset, :unsafe_validate_unique, 4} => {:impure, :network}
  }

  # Each one calls the related schema's changeset/2, or the `with:` fun,
  # and which module that is is only known at runtime. Pure would hide
  # whatever that function does.
  @ecto_dynamic %{
    {Ecto.Changeset, :cast_assoc, 2} => {:impure, :dynamic_call},
    {Ecto.Changeset, :cast_assoc, 3} => {:impure, :dynamic_call},
    {Ecto.Changeset, :cast_embed, 2} => {:impure, :dynamic_call},
    {Ecto.Changeset, :cast_embed, 3} => {:impure, :dynamic_call}
  }

  @ecto_hofs %{
    {Ecto.Changeset, :optimistic_lock, 3} => {:hof, [3]},
    # The fun runs later, inside the repo transaction, and is usually
    # impure. Blaming the caller that hands it over is the only place
    # the analyser can do that.
    {Ecto.Changeset, :prepare_changes, 2} => {:hof, [2]},
    {Ecto.Changeset, :traverse_errors, 2} => {:hof, [2]},
    {Ecto.Changeset, :traverse_validations, 2} => {:hof, [2]},
    {Ecto.Changeset, :update_change, 3} => {:hof, [3]},
    {Ecto.Changeset, :validate_change, 3} => {:hof, [3]},
    {Ecto.Changeset, :validate_change, 4} => {:hof, [4]},
    {Ecto.Type, :dump, 3} => {:hof, [3]},
    {Ecto.Type, :load, 3} => {:hof, [3]}
  }

  @ecto_pure [
    {Ecto, :assoc, 2},
    {Ecto, :assoc, 3},
    {Ecto, :assoc_loaded?, 1},
    {Ecto, :build_assoc, 2},
    {Ecto, :build_assoc, 3},
    {Ecto, :embedded_dump, 2},
    {Ecto, :embedded_load, 3},
    {Ecto, :get_meta, 2},
    {Ecto, :primary_key, 1},
    {Ecto, :primary_key!, 1},
    {Ecto, :put_meta, 2},
    {Ecto, :reset_fields, 2},
    {Ecto.Changeset, :add_error, 3},
    {Ecto.Changeset, :add_error, 4},
    {Ecto.Changeset, :apply_action, 2},
    {Ecto.Changeset, :apply_action!, 2},
    {Ecto.Changeset, :apply_changes, 1},
    {Ecto.Changeset, :assoc_constraint, 2},
    {Ecto.Changeset, :assoc_constraint, 3},
    {Ecto.Changeset, :cast, 3},
    {Ecto.Changeset, :cast, 4},
    {Ecto.Changeset, :change, 1},
    {Ecto.Changeset, :change, 2},
    {Ecto.Changeset, :changed?, 2},
    {Ecto.Changeset, :changed?, 3},
    {Ecto.Changeset, :check_constraint, 2},
    {Ecto.Changeset, :check_constraint, 3},
    {Ecto.Changeset, :constraints, 1},
    {Ecto.Changeset, :delete_change, 2},
    {Ecto.Changeset, :empty_values, 0},
    {Ecto.Changeset, :exclusion_constraint, 2},
    {Ecto.Changeset, :exclusion_constraint, 3},
    {Ecto.Changeset, :fetch_change, 2},
    {Ecto.Changeset, :fetch_change!, 2},
    {Ecto.Changeset, :fetch_field, 2},
    {Ecto.Changeset, :fetch_field!, 2},
    {Ecto.Changeset, :field_missing?, 2},
    {Ecto.Changeset, :force_change, 3},
    {Ecto.Changeset, :foreign_key_constraint, 2},
    {Ecto.Changeset, :foreign_key_constraint, 3},
    {Ecto.Changeset, :get_assoc, 2},
    {Ecto.Changeset, :get_assoc, 3},
    {Ecto.Changeset, :get_change, 2},
    {Ecto.Changeset, :get_change, 3},
    {Ecto.Changeset, :get_embed, 2},
    {Ecto.Changeset, :get_embed, 3},
    {Ecto.Changeset, :get_field, 2},
    {Ecto.Changeset, :get_field, 3},
    {Ecto.Changeset, :merge, 2},
    {Ecto.Changeset, :no_assoc_constraint, 2},
    {Ecto.Changeset, :no_assoc_constraint, 3},
    {Ecto.Changeset, :optimistic_lock, 2},
    {Ecto.Changeset, :put_assoc, 3},
    {Ecto.Changeset, :put_assoc, 4},
    {Ecto.Changeset, :put_change, 3},
    {Ecto.Changeset, :put_embed, 3},
    {Ecto.Changeset, :put_embed, 4},
    {Ecto.Changeset, :unique_constraint, 2},
    {Ecto.Changeset, :unique_constraint, 3},
    {Ecto.Changeset, :validate_acceptance, 2},
    {Ecto.Changeset, :validate_acceptance, 3},
    {Ecto.Changeset, :validate_confirmation, 2},
    {Ecto.Changeset, :validate_confirmation, 3},
    {Ecto.Changeset, :validate_exclusion, 3},
    {Ecto.Changeset, :validate_exclusion, 4},
    {Ecto.Changeset, :validate_format, 3},
    {Ecto.Changeset, :validate_format, 4},
    {Ecto.Changeset, :validate_inclusion, 3},
    {Ecto.Changeset, :validate_inclusion, 4},
    {Ecto.Changeset, :validate_length, 3},
    {Ecto.Changeset, :validate_number, 3},
    {Ecto.Changeset, :validate_required, 2},
    {Ecto.Changeset, :validate_required, 3},
    {Ecto.Changeset, :validate_subset, 3},
    {Ecto.Changeset, :validate_subset, 4},
    {Ecto.Changeset, :validations, 1},
    {Ecto.Enum, :cast_value, 3},
    {Ecto.Enum, :dump_values, 2},
    {Ecto.Enum, :mappings, 2},
    {Ecto.Enum, :values, 2},
    {Ecto.Type, :base?, 1},
    {Ecto.Type, :cast, 2},
    {Ecto.Type, :cast!, 2},
    {Ecto.Type, :composite?, 1},
    {Ecto.Type, :dump, 2},
    {Ecto.Type, :embed_as, 2},
    {Ecto.Type, :embedded_dump, 3},
    {Ecto.Type, :embedded_load, 3},
    {Ecto.Type, :equal?, 3},
    {Ecto.Type, :format, 1},
    {Ecto.Type, :load, 2},
    {Ecto.Type, :match?, 2},
    {Ecto.Type, :parameterized?, 2},
    {Ecto.Type, :primitive?, 1},
    {Ecto.Type, :type, 1}
  ]

  @ecto @ecto_pure
        |> Map.new(&{&1, :pure})
        |> Map.merge(@ecto_hofs)
        |> Map.merge(@ecto_dynamic)
        |> Map.merge(@ecto_impure)

  # Every translation reads the locale from the process dictionary, which
  # is the one effect it has. with_locale/2,3 is left to the analysis: it
  # also runs the fun it is given.
  @gettext_locale [
    {Gettext, :dgettext, 3},
    {Gettext, :dgettext, 4},
    {Gettext, :dngettext, 5},
    {Gettext, :dngettext, 6},
    {Gettext, :dpgettext, 4},
    {Gettext, :dpgettext, 5},
    {Gettext, :dpngettext, 6},
    {Gettext, :dpngettext, 7},
    {Gettext, :get_locale, 0},
    {Gettext, :get_locale, 1},
    {Gettext, :gettext, 2},
    {Gettext, :gettext, 3},
    {Gettext, :ngettext, 4},
    {Gettext, :ngettext, 5},
    {Gettext, :pgettext, 3},
    {Gettext, :pgettext, 4},
    {Gettext, :pngettext, 5},
    {Gettext, :pngettext, 6},
    {Gettext, :put_locale, 1},
    {Gettext, :put_locale, 2}
  ]

  @gettext @gettext_locale
           |> Map.new(&{&1, {:impure, :process_dictionary}})
           |> Map.put({Gettext, :known_locales, 1}, :pure)

  @presets %{ecto: @ecto, gettext: @gettext}

  @doc """
  The Ecto preset: `Ecto`, `Ecto.Changeset`, `Ecto.Type` and the
  `Ecto.Enum` helpers.

  Building, casting and validating a changeset is pure. The functions
  that take a fun are pure as long as that fun is, and
  `unsafe_validate_unique/3,4` is impure, because it runs a query.
  `cast_assoc/2,3` and `cast_embed/2,3` call the related schema's
  `changeset/2`, which is only known at runtime, so they are
  `:dynamic_call` and a caller's verdict is `unknown`. Once that
  changeset is annotated itself, the caller can say
  `@pure_fun except: [:dynamic_call]`.

  It trusts every `Ecto.Type` in the build to cast, dump and load purely.
  A custom type that reads the clock or the application environment in
  `cast/1` is not reported through `cast/3`. The `Ecto.Query` builder and
  `Ecto.Repo` are not covered.

      iex> PureFun.Presets.ecto()[{Ecto.Changeset, :unsafe_validate_unique, 3}]
      {:impure, :network}

      iex> PureFun.Presets.ecto()[{Ecto.Changeset, :validate_change, 3}]
      {:hof, [3]}

      iex> PureFun.Presets.ecto()[{Ecto.Changeset, :cast_embed, 3}]
      {:impure, :dynamic_call}
  """
  @spec ecto() :: table()
  def ecto, do: @ecto

  @doc """
  The Gettext preset: the `Gettext` module that `use Gettext` calls into.

  A translation reads the locale from the process dictionary and nothing
  else, so it is `{:impure, :process_dictionary}`. A function that
  translates can say so with `@pure_fun except: [:process_dictionary]`.

  A missing binding is logged by the backend's
  `handle_missing_bindings/2`. That is a bug in the call site rather than
  something a translation does, and a backend that overrides the callback
  is trusted too.

      iex> PureFun.Presets.gettext()[{Gettext, :known_locales, 1}]
      :pure
  """
  @spec gettext() :: table()
  def gettext, do: @gettext

  @doc """
  The names that `pure_fun: [presets: [...]]` accepts.

      iex> PureFun.Presets.names()
      [:ecto, :gettext]
  """
  @spec names() :: [name()]
  def names, do: @presets |> Map.keys() |> Enum.sort()

  @doc """
  The `:known` table for a `pure_fun:` configuration: its presets, with
  its own `:known` entries merged over them.

      iex> PureFun.Presets.known(presets: [:ecto], known: %{{Ecto.Changeset, :cast, 3} => {:impure, :time}})
      ...> |> Map.fetch!({Ecto.Changeset, :cast, 3})
      {:impure, :time}

      iex> PureFun.Presets.known([])
      %{}

  Raises `ArgumentError` for a preset that does not exist.
  """
  @spec known(keyword()) :: table()
  def known(config) do
    config
    |> Keyword.get(:presets, [])
    |> Enum.map(&fetch!/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
    |> Map.merge(Keyword.get(config, :known, %{}))
  end

  defp fetch!(name) do
    case Map.fetch(@presets, name) do
      {:ok, table} ->
        table

      :error ->
        raise ArgumentError,
              "unknown pure_fun preset #{inspect(name)}, expected one of: " <>
                Enum.map_join(names(), ", ", &inspect/1)
    end
  end
end
