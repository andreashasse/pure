%% Fixture for a module-wide claim written the Erlang way: -pure_fun_module
%% takes the same `true` or `[{except, Classes}]` an Elixir @pure_fun_module
%% does.
-module(pure_module_erl).

-export([stamped/0, plain/2]).

-pure_fun_module([{except, [time]}]).

stamped() ->
    erlang:system_time().

plain(A, B) ->
    A + B.
