defmodule Pure.Knowledge do
  @moduledoc """
  What the analyser knows about functions it cannot look inside.

  Most leaves of the call graph are BIFs, NIFs or OTP functions whose
  effects are not visible in their abstract code — `:ets.insert/2` compiles
  to `erlang:nif_error(undef)`, and analysing that would happily report it
  as pure. This module is the hand-maintained ground truth that stops the
  fixpoint from bottoming out in a lie.

      iex> Pure.Knowledge.lookup(IO, :puts, 1)
      {:impure, :io}

      iex> Pure.Knowledge.lookup(String, :upcase, 1)
      :pure

      iex> Pure.Knowledge.lookup(Enum, :map, 2)
      {:hof, [2]}

      iex> Pure.Knowledge.lookup(SomeUnknownLib, :frobnicate, 1)
      :unknown

  A `{:hof, positions}` answer means "pure as long as the funs given at
  these 1-based argument positions are pure" — the analyser resolves those
  arguments at each call site.
  """

  @typedoc "Why a function is impure."
  @type category ::
          :io
          | :file
          | :network
          | :system
          | :time
          | :random
          | :process
          | :process_dictionary
          | :message
          | :message_receive
          | :ets
          | :persistent_term
          | :mutable_state
          | :code_loading
          | :port
          | :tracing
          | :dynamic_call
          | :higher_order
          | :unknown

  @type answer :: :pure | {:impure, category()} | {:hof, [pos_integer()]} | :unknown

  # Modules where every function is pure unless overridden below.
  @pure_modules MapSet.new([
                  # Erlang
                  :array,
                  :base64,
                  :binary,
                  :calendar,
                  :dict,
                  :erl_anno,
                  :erl_internal,
                  :erl_parse,
                  :erl_scan,
                  :filename,
                  :gb_sets,
                  :gb_trees,
                  :io_lib,
                  :json,
                  :lists,
                  :maps,
                  :math,
                  :orddict,
                  :ordsets,
                  :proplists,
                  :queue,
                  :re,
                  :sets,
                  :string,
                  :unicode,
                  :uri_string,
                  :erlang,
                  # Elixir
                  Access,
                  Atom,
                  Base,
                  Bitwise,
                  Calendar,
                  Calendar.ISO,
                  Collectable,
                  Enumerable,
                  Inspect,
                  Inspect.Algebra,
                  Inspect.Opts,
                  # Returns escape sequences, writes nothing.
                  IO.ANSI,
                  Kernel.Utils,
                  OptionParser,
                  Date,
                  Date.Range,
                  DateTime,
                  Duration,
                  Enum,
                  Exception,
                  Float,
                  Function,
                  Integer,
                  Kernel,
                  Keyword,
                  List,
                  List.Chars,
                  Map,
                  MapSet,
                  NaiveDateTime,
                  Path,
                  Range,
                  Regex,
                  Stream,
                  String,
                  String.Chars,
                  Time,
                  Tuple,
                  URI,
                  Version,
                  Version.Requirement
                ])

  # Modules where every function has this effect unless overridden below.
  @impure_modules %{
    # Erlang
    :application => :system,
    :beam_lib => :file,
    :code => :code_loading,
    :counters => :mutable_state,
    :atomics => :mutable_state,
    :ct => :io,
    :dbg => :tracing,
    :dets => :file,
    :digraph => :ets,
    :digraph_utils => :ets,
    :disk_log => :file,
    :epp => :file,
    :erl_eval => :dynamic_call,
    :erpc => :network,
    :error_logger => :io,
    :ets => :ets,
    :eunit => :io,
    :file => :file,
    :filelib => :file,
    :gen => :process,
    :gen_event => :process,
    :gen_sctp => :network,
    :gen_server => :process,
    :gen_statem => :process,
    :gen_tcp => :network,
    :gen_udp => :network,
    :global => :network,
    :httpc => :network,
    :inet => :network,
    :inets => :network,
    :io => :io,
    :logger => :io,
    :mnesia => :ets,
    :net_adm => :network,
    :net_kernel => :network,
    :os => :system,
    :persistent_term => :persistent_term,
    :pg => :process,
    :prim_file => :file,
    :proc_lib => :process,
    :rand => :random,
    :random => :random,
    :rpc => :network,
    :seq_trace => :tracing,
    :socket => :network,
    :ssh => :network,
    :ssl => :network,
    :supervisor => :process,
    :sys => :process,
    :timer => :time,
    :zlib => :process,
    # Elixir
    Agent => :process,
    Application => :system,
    Code => :code_loading,
    Config => :system,
    DynamicSupervisor => :process,
    File => :file,
    File.Stream => :file,
    GenServer => :process,
    IO => :io,
    IO.Stream => :io,
    Logger => :io,
    Mix => :system,
    Mix.Project => :system,
    Mix.Shell => :io,
    Mix.Shell.IO => :io,
    Mix.Task => :system,
    Module => :code_loading,
    Node => :network,
    Port => :port,
    Process => :process,
    Registry => :process,
    StringIO => :io,
    Supervisor => :process,
    System => :system,
    Task => :process,
    Task.Supervisor => :process
  }

  # Per-function answers. Keys are {module, function, arity} or {module,
  # function} for every arity. Checked before the module defaults, so this
  # holds both the impure functions of pure modules and vice versa.
  @overrides %{
    # --- :erlang, the big one -------------------------------------------
    {:erlang, :send} => {:impure, :message},
    {:erlang, :send_after} => {:impure, :message},
    {:erlang, :send_nosuspend} => {:impure, :message},
    {:erlang, :start_timer} => {:impure, :message},
    {:erlang, :cancel_timer} => {:impure, :message},
    {:erlang, :read_timer} => {:impure, :message},
    {:erlang, :spawn} => {:impure, :process},
    {:erlang, :spawn_link} => {:impure, :process},
    {:erlang, :spawn_monitor} => {:impure, :process},
    {:erlang, :spawn_opt} => {:impure, :process},
    {:erlang, :spawn_request} => {:impure, :process},
    {:erlang, :spawn_request_abandon} => {:impure, :process},
    {:erlang, :self} => {:impure, :process},
    {:erlang, :alias} => {:impure, :process},
    {:erlang, :unalias} => {:impure, :process},
    {:erlang, :is_process_alive} => {:impure, :process},
    {:erlang, :process_info} => {:impure, :process},
    {:erlang, :process_display} => {:impure, :process},
    {:erlang, :process_flag} => {:impure, :process},
    {:erlang, :processes} => {:impure, :process},
    {:erlang, :link} => {:impure, :process},
    {:erlang, :unlink} => {:impure, :process},
    {:erlang, :monitor} => {:impure, :process},
    {:erlang, :demonitor} => {:impure, :process},
    {:erlang, :monitor_node} => {:impure, :network},
    {:erlang, :exit, 2} => {:impure, :process},
    {:erlang, :group_leader} => {:impure, :process},
    {:erlang, :hibernate} => {:impure, :process},
    {:erlang, :suspend_process} => {:impure, :process},
    {:erlang, :resume_process} => {:impure, :process},
    {:erlang, :yield} => {:impure, :process},
    {:erlang, :bump_reductions} => {:impure, :process},
    {:erlang, :garbage_collect} => {:impure, :process},
    {:erlang, :register} => {:impure, :process},
    {:erlang, :unregister} => {:impure, :process},
    {:erlang, :whereis} => {:impure, :process},
    {:erlang, :registered} => {:impure, :process},
    {:erlang, :put} => {:impure, :process_dictionary},
    {:erlang, :get, 0} => {:impure, :process_dictionary},
    {:erlang, :get, 1} => {:impure, :process_dictionary},
    {:erlang, :get_keys} => {:impure, :process_dictionary},
    {:erlang, :erase} => {:impure, :process_dictionary},
    {:erlang, :node, 0} => {:impure, :network},
    {:erlang, :nodes} => {:impure, :network},
    {:erlang, :disconnect_node} => {:impure, :network},
    {:erlang, :set_cookie} => {:impure, :network},
    {:erlang, :get_cookie} => {:impure, :network},
    {:erlang, :halt} => {:impure, :system},
    {:erlang, :memory} => {:impure, :system},
    {:erlang, :statistics} => {:impure, :system},
    {:erlang, :system_info} => {:impure, :system},
    {:erlang, :system_flag} => {:impure, :system},
    {:erlang, :system_monitor} => {:impure, :system},
    {:erlang, :system_profile} => {:impure, :system},
    {:erlang, :display} => {:impure, :io},
    {:erlang, :display_string} => {:impure, :io},
    {:erlang, :now} => {:impure, :time},
    {:erlang, :date} => {:impure, :time},
    {:erlang, :time} => {:impure, :time},
    {:erlang, :localtime} => {:impure, :time},
    {:erlang, :universaltime} => {:impure, :time},
    {:erlang, :monotonic_time} => {:impure, :time},
    {:erlang, :system_time} => {:impure, :time},
    {:erlang, :time_offset} => {:impure, :time},
    {:erlang, :timestamp} => {:impure, :time},
    {:erlang, :unique_integer} => {:impure, :random},
    {:erlang, :make_ref} => {:impure, :random},
    {:erlang, :open_port} => {:impure, :port},
    {:erlang, :port_call} => {:impure, :port},
    {:erlang, :port_close} => {:impure, :port},
    {:erlang, :port_command} => {:impure, :port},
    {:erlang, :port_connect} => {:impure, :port},
    {:erlang, :port_control} => {:impure, :port},
    {:erlang, :port_info} => {:impure, :port},
    {:erlang, :ports} => {:impure, :port},
    {:erlang, :load_module} => {:impure, :code_loading},
    {:erlang, :load_nif} => {:impure, :code_loading},
    {:erlang, :prepare_loading} => {:impure, :code_loading},
    {:erlang, :finish_loading} => {:impure, :code_loading},
    {:erlang, :purge_module} => {:impure, :code_loading},
    {:erlang, :delete_module} => {:impure, :code_loading},
    {:erlang, :check_process_code} => {:impure, :code_loading},
    {:erlang, :check_old_code} => {:impure, :code_loading},
    {:erlang, :module_loaded} => {:impure, :code_loading},
    {:erlang, :pre_loaded} => {:impure, :code_loading},
    {:erlang, :loaded} => {:impure, :code_loading},
    {:erlang, :function_exported} => {:impure, :code_loading},
    {:erlang, :trace} => {:impure, :tracing},
    {:erlang, :trace_pattern} => {:impure, :tracing},
    {:erlang, :trace_info} => {:impure, :tracing},
    {:erlang, :trace_delivered} => {:impure, :tracing},
    {:erlang, :apply} => {:impure, :dynamic_call},
    # Reflection on the module's own metadata: deterministic, no effect.
    {:erlang, :get_module_info} => :pure,

    # Compiled into ordinary Elixir code: `map.key` on a non-map raises
    # through this helper, so it appears in perfectly pure functions.
    {:elixir_erl_pass, :no_parens_remote} => :pure,

    # --- pure modules with impure corners -------------------------------
    {:calendar, :local_time} => {:impure, :time},
    {:calendar, :universal_time} => {:impure, :time},
    {:calendar, :local_time_to_universal_time_dst} => {:impure, :time},
    {:crypto, :hash} => :pure,
    {:crypto, :hash_init} => :pure,
    {:crypto, :hash_update} => :pure,
    {:crypto, :hash_final} => :pure,
    {:crypto, :strong_rand_bytes} => {:impure, :random},
    {:erl_eval, :expr} => {:impure, :dynamic_call},
    {Date, :utc_today} => {:impure, :time},
    {DateTime, :utc_now} => {:impure, :time},
    {DateTime, :now} => {:impure, :time},
    {DateTime, :now!} => {:impure, :time},
    {DateTime, :shift_zone} => {:impure, :system},
    {DateTime, :shift_zone!} => {:impure, :system},
    {NaiveDateTime, :utc_now} => {:impure, :time},
    {NaiveDateTime, :local_now} => {:impure, :time},
    {Time, :utc_now} => {:impure, :time},
    {Enum, :random} => {:impure, :random},
    {Enum, :shuffle} => {:impure, :random},
    {Enum, :take_random} => {:impure, :random},
    {Exception, :format_stacktrace, 0} => {:impure, :process},
    {Function, :capture} => {:impure, :dynamic_call},
    {Kernel, :dbg} => {:impure, :io},
    {Kernel, :binding} => {:impure, :process},
    {Kernel, :apply} => {:impure, :dynamic_call},
    {Kernel, :spawn} => {:impure, :process},
    {Kernel, :spawn_link} => {:impure, :process},
    {Kernel, :spawn_monitor} => {:impure, :process},
    {Kernel, :send} => {:impure, :message},
    {Kernel, :self} => {:impure, :process},
    {Kernel, :make_ref} => {:impure, :random},
    {Kernel, :node} => {:impure, :network},
    {Kernel, :inspect} => :pure,
    {Kernel, :to_string} => :pure,
    {Kernel, :to_charlist} => :pure,
    {Process, :put} => {:impure, :process_dictionary},
    {Process, :get} => {:impure, :process_dictionary},
    {Process, :get_keys} => {:impure, :process_dictionary},
    {Process, :delete} => {:impure, :process_dictionary},
    {Process, :erase} => {:impure, :process_dictionary},
    {Path, :expand, 1} => {:impure, :file},
    {Path, :absname, 1} => {:impure, :file},
    {Path, :wildcard} => {:impure, :file},
    {Path, :safe_relative_to} => {:impure, :file},
    {Stream, :interval} => {:impure, :time},
    {Stream, :timer} => {:impure, :time},
    {Stream, :resource} => {:impure, :unknown},

    # --- impure modules with pure corners -------------------------------
    {:code, :which} => {:impure, :code_loading},
    {:logger, :get_config} => {:impure, :system},
    {:os, :type} => :pure,
    {:timer, :hms} => :pure,
    {:timer, :hours} => :pure,
    {:timer, :minutes} => :pure,
    {:timer, :seconds} => :pure,
    {:timer, :now_diff} => :pure,
    {File, :join} => :pure,
    {IO.ANSI, :format} => :pure,
    {IO.ANSI, :format_fragment} => :pure,
    {IO, :chardata_to_string} => :pure,
    {IO, :iodata_to_binary} => :pure,
    {IO, :iodata_length} => :pure,
    {Module, :concat} => :pure,
    {Module, :split} => :pure,
    {Module, :safe_concat} => :pure,
    {System, :convert_time_unit} => :pure
  }

  # Functions that are pure exactly when the funs at these 1-based
  # argument positions are pure.
  @hofs %{
    # Erlang
    {:lists, :all, 2} => [1],
    {:lists, :any, 2} => [1],
    {:lists, :dropwhile, 2} => [1],
    {:lists, :filter, 2} => [1],
    {:lists, :filtermap, 2} => [1],
    {:lists, :flatmap, 2} => [1],
    {:lists, :foldl, 3} => [1],
    {:lists, :foldr, 3} => [1],
    {:lists, :foreach, 2} => [1],
    {:lists, :map, 2} => [1],
    {:lists, :mapfoldl, 3} => [1],
    {:lists, :mapfoldr, 3} => [1],
    {:lists, :partition, 2} => [1],
    {:lists, :search, 2} => [1],
    {:lists, :sort, 2} => [1],
    {:lists, :splitwith, 2} => [1],
    {:lists, :takewhile, 2} => [1],
    {:lists, :uniq, 2} => [1],
    {:lists, :usort, 2} => [1],
    {:lists, :zipwith, 3} => [1],
    {:maps, :filter, 2} => [1],
    {:maps, :filtermap, 2} => [1],
    {:maps, :fold, 3} => [1],
    {:maps, :foreach, 2} => [1],
    {:maps, :map, 2} => [1],
    {:maps, :update_with, 3} => [2],
    {:maps, :update_with, 4} => [2],
    # Elixir
    {Enum, :all?, 2} => [2],
    {Enum, :any?, 2} => [2],
    {Enum, :chunk_by, 2} => [2],
    {Enum, :chunk_while, 4} => [3, 4],
    {Enum, :count, 2} => [2],
    {Enum, :count_until, 3} => [2],
    {Enum, :dedup_by, 2} => [2],
    {Enum, :drop_while, 2} => [2],
    {Enum, :each, 2} => [2],
    {Enum, :filter, 2} => [2],
    {Enum, :find, 2} => [2],
    {Enum, :find, 3} => [3],
    {Enum, :find_index, 2} => [2],
    {Enum, :find_value, 2} => [2],
    {Enum, :find_value, 3} => [3],
    {Enum, :flat_map, 2} => [2],
    {Enum, :flat_map_reduce, 3} => [3],
    {Enum, :frequencies_by, 2} => [2],
    {Enum, :group_by, 2} => [2],
    {Enum, :group_by, 3} => [2, 3],
    {Enum, :into, 3} => [3],
    {Enum, :map, 2} => [2],
    {Enum, :map_every, 3} => [3],
    {Enum, :map_intersperse, 3} => [3],
    {Enum, :map_join, 3} => [3],
    {Enum, :map_reduce, 3} => [3],
    {Enum, :max_by, 2} => [2],
    {Enum, :min_by, 2} => [2],
    {Enum, :min_max_by, 2} => [2],
    {Enum, :reduce, 2} => [2],
    {Enum, :reduce, 3} => [3],
    {Enum, :reduce_while, 3} => [3],
    {Enum, :reject, 2} => [2],
    {Enum, :scan, 2} => [2],
    {Enum, :scan, 3} => [3],
    {Enum, :sort, 2} => [2],
    {Enum, :sort_by, 2} => [2],
    {Enum, :sort_by, 3} => [2],
    {Enum, :split_while, 2} => [2],
    {Enum, :split_with, 2} => [2],
    {Enum, :sum_by, 2} => [2],
    {Enum, :take_while, 2} => [2],
    {Enum, :uniq_by, 2} => [2],
    {Enum, :with_index, 2} => [2],
    {Enum, :zip_with, 2} => [2],
    {Enum, :zip_with, 3} => [3],
    {Kernel, :tap, 2} => [2],
    {Kernel, :then, 2} => [2],
    {Kernel, :get_and_update_in, 3} => [3],
    {Kernel, :update_in, 3} => [3],
    {Keyword, :filter, 2} => [2],
    {Keyword, :get_and_update, 3} => [3],
    {Keyword, :get_lazy, 3} => [3],
    {Keyword, :map, 2} => [2],
    {Keyword, :pop_lazy, 3} => [3],
    {Keyword, :put_new_lazy, 3} => [3],
    {Keyword, :reject, 2} => [2],
    {Keyword, :replace_lazy, 3} => [3],
    {Keyword, :update, 4} => [4],
    {Keyword, :update!, 3} => [3],
    {List, :foldl, 3} => [3],
    {List, :foldr, 3} => [3],
    {Map, :filter, 2} => [2],
    {Map, :get_and_update, 3} => [3],
    {Map, :get_and_update!, 3} => [3],
    {Map, :get_lazy, 3} => [3],
    {Map, :map, 2} => [2],
    {Map, :merge, 3} => [3],
    {Map, :new, 2} => [2],
    {Map, :pop_lazy, 3} => [3],
    {Map, :put_new_lazy, 3} => [3],
    {Map, :reject, 2} => [2],
    {Map, :replace_lazy, 3} => [3],
    {Map, :update, 4} => [4],
    {Map, :update!, 3} => [3],
    {MapSet, :filter, 2} => [2],
    {MapSet, :reject, 2} => [2],
    {Stream, :chunk_by, 2} => [2],
    {Stream, :chunk_while, 4} => [3, 4],
    {Stream, :dedup_by, 2} => [2],
    {Stream, :drop_while, 2} => [2],
    {Stream, :each, 2} => [2],
    {Stream, :filter, 2} => [2],
    {Stream, :flat_map, 2} => [2],
    {Stream, :iterate, 2} => [2],
    {Stream, :map, 2} => [2],
    {Stream, :map_every, 3} => [3],
    {Stream, :reject, 2} => [2],
    {Stream, :repeatedly, 1} => [1],
    {Stream, :scan, 2} => [2],
    {Stream, :scan, 3} => [3],
    {Stream, :take_while, 2} => [2],
    {Stream, :transform, 3} => [3],
    {Stream, :unfold, 2} => [2],
    {Stream, :uniq_by, 2} => [2],
    {Stream, :with_index, 2} => [2]
  }

  @doc """
  What is known about `module:function/arity`.

  `:unknown` means the analyser has no entry and could not read the
  function's code either — callers decide how paranoid to be about that.
  """
  @spec lookup(module(), atom(), arity()) :: answer()
  def lookup(module, function, arity) do
    with :error <- Map.fetch(@hofs, {module, function, arity}) |> wrap(:hof),
         :error <- Map.fetch(@overrides, {module, function, arity}),
         :error <- Map.fetch(@overrides, {module, function}),
         :error <- module_default(module),
         :error <- behaviour_default(function, arity) do
      :unknown
    else
      {:ok, answer} -> answer
    end
  end

  # `raise ArgumentError, "..."` compiles to a call to the exception
  # module's callback. Reached only for modules with no entry above, so a
  # known-impure module keeps its verdict.
  defp behaviour_default(:exception, 1), do: {:ok, :pure}
  defp behaviour_default(_function, _arity), do: :error

  defp wrap({:ok, positions}, :hof), do: {:ok, {:hof, positions}}
  defp wrap(:error, _), do: :error

  defp module_default(module) do
    cond do
      MapSet.member?(@pure_modules, module) ->
        {:ok, :pure}

      Map.has_key?(@impure_modules, module) ->
        {:ok, {:impure, Map.fetch!(@impure_modules, module)}}

      true ->
        :error
    end
  end

  @doc """
  All known higher-order functions, as `{module, function, arity} => positions`.

  Exposed because the analyser needs the argument positions before it has
  resolved anything else.
  """
  @spec higher_order_functions() :: %{mfa() => [pos_integer()]}
  def higher_order_functions do
    Map.new(@hofs, fn {{m, f, a}, positions} -> {{m, f, a}, positions} end)
  end

  @doc """
  Human-readable one-liner for an effect category.

      iex> Pure.Knowledge.describe(:process_dictionary)
      "reads or writes the process dictionary"
  """
  @spec describe(category()) :: String.t()
  def describe(:io), do: "performs I/O"
  def describe(:file), do: "touches the file system"
  def describe(:network), do: "talks to the network or other nodes"
  def describe(:system), do: "reads or changes system/application state"
  def describe(:time), do: "reads the clock"
  def describe(:random), do: "produces non-deterministic values"
  def describe(:process), do: "inspects or manipulates processes"
  def describe(:process_dictionary), do: "reads or writes the process dictionary"
  def describe(:message), do: "sends messages"
  def describe(:message_receive), do: "receives messages"
  def describe(:ets), do: "reads or writes shared tables"
  def describe(:persistent_term), do: "reads or writes persistent_term"
  def describe(:mutable_state), do: "reads or writes shared mutable state"
  def describe(:code_loading), do: "depends on loaded code"
  def describe(:port), do: "talks to a port"
  def describe(:tracing), do: "changes tracing"
  def describe(:dynamic_call), do: "calls a function decided at runtime"
  def describe(:higher_order), do: "applies a fun the analyser cannot resolve"
  def describe(:unknown), do: "calls a function the analyser knows nothing about"
end
