-module(etorrent_monitorset).
-export([new/0,
         size/1,
         insert/3,
         update/3,
         delete/2,
         fetch/2,
         is_member/2]).

-compile({no_auto_import,[monitor/2, demonitor/1]}).

-type monitorset() :: gb_tree().
-export_type([monitorset/0]).

%% @doc
%% Create an empty set of process monitors.
%% @end
-spec new() -> monitorset().
new() ->
    gb_trees:empty().

%% @doc
%%
%% @end
-spec size(monitorset()) -> pos_integer().
size(Monitorset) ->
    gb_trees:size(Monitorset).

%% @doc
%%
%% @end
-spec insert(pid(), term(), monitorset()) -> monitorset().
insert(Pid, Value, Monitorset) ->
    MRef = erlang:monitor(process, Pid),
    gb_trees:insert(Pid, {MRef, Value}, Monitorset).

%% @doc
%%
%% @end
-spec update(pid(), term(), monitorset()) -> monitorset().
update(Pid, Value, Monitorset) ->
    {MRef, _} = gb_trees:get(Pid, Monitorset),
    gb_trees:update(Pid, {MRef, Value}, Monitorset).

%% @doc
%%
%% @end
-spec delete(pid(), monitorset()) -> monitorset().
delete(Pid, Monitorset) ->
    {MRef, _} = gb_trees:get(Pid, Monitorset),
    true = erlang:demonitor(MRef, [flush]),
    gb_trees:delete(Pid, Monitorset).

%% @doc
%%
%% @end
-spec is_member(pid(), monitorset()) -> boolean().
is_member(Pid, Monitorset) ->
    gb_trees:is_defined(Pid, Monitorset).

%% @doc
%%
%% @end
-spec fetch(pid(), monitorset()) -> term().
fetch(Pid, Monitorset) ->
    {_, Value} = gb_trees:get(Pid, Monitorset),
    Value.


