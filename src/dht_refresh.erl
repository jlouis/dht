%%% @doc This module contains various refreshing tasks
%%% @end
%%% @private
-module(dht_refresh).
-export([insert_nodes/1, range/1]).

%% @doc insert_nodes/1 inserts a list of nodes into the routing table asynchronously
%% @end
-spec insert_nodes([dht:node_t()]) -> ok.
insert_nodes(NodeInfos) ->
    [spawn_link(dht_net, ping, [{IP, Port}]) || {_, IP, Port} <- NodeInfos],
    ok.

%% @doc refresh_range/1 refreshes a range for the system based on its ID
%% @end
-spec range(dht:peer()) -> reference().
range({ID, IP, Port}) ->
  spawn_link(fun() ->
    case dht_net:find_node({IP, Port}, ID) of
        {error, timeout} -> ok;
        {nodes, _, _Token, Nodes} ->
            [spawn_link(fun() -> dht_net:ping({I, P}) end) || {_, I, P} <- Nodes],
            ok
    end
  end),
  ok.

