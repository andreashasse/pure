%% Fixture for the Erlang side of the analyser: auto-imported BIFs, `!`,
%% receive, the -pure_annotated attribute and local funs all look
%% different from what the Elixir compiler emits.
-module(pure_sample_erl).

-export([add/2, sum/1, hof/2, applies/1, sends/1, receives/0, dict/1,
         table/1, spawns/1, dynamic/2, local_bif/0, capture_pure/1,
         capture_impure/1, annotated_impure/1, bound_fun/1,
         imported/1]).

-import(lists, [reverse/1]).

-pure_annotated([{add, 2}, {sum, 1}, {annotated_impure, 1}]).

add(A, B) ->
    A + B.

sum(List) ->
    lists:foldl(fun(X, Acc) -> X + Acc end, 0, List).

hof(List, Fun) ->
    lists:map(Fun, List).

applies(Fun) ->
    Fun(1).

bound_fun(List) ->
    Double = fun(X) -> X * 2 end,
    lists:map(Double, List).

sends(Pid) ->
    Pid ! hello.

receives() ->
    receive
        Msg -> Msg
    end.

%% Auto-imported BIFs are local calls in Erlang abstract code.
dict(X) ->
    put(key, X).

local_bif() ->
    self().

spawns(Fun) ->
    spawn(Fun).

table(Table) ->
    ets:lookup(Table, key).

dynamic(Module, Function) ->
    apply(Module, Function, []).

capture_pure(List) ->
    lists:map(fun string:uppercase/1, List).

capture_impure(List) ->
    lists:foreach(fun erlang:display/1, List).

annotated_impure(X) ->
    io:format("~p~n", [X]).

%% -import turns this into a local call in the abstract code.
imported(List) ->
    reverse(List).
