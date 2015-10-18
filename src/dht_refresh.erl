%%% @doc This module contains various refreshing tasks
%%% @end
%%% @private
-module(dht_refresh).
-export([insert_nodes/1, range/1, verify/3]).

%% @doc insert_nodes/1 inserts a list of nodes into the routing table asynchronously
%% @end
-spec insert_nodes([dht:peer()]) -> ok.
insert_nodes(NodeInfos) ->
    [spawn_link(dht_net, ping, [{IP, Port}]) || {_, IP, Port} <- NodeInfos],
    ok.

%% @doc range/1 refreshes a range for the system based on its ID
%% @end
-spec range(dht:peer()) -> ok.
range({ID, IP, Port}) ->
  spawn_link(fun() ->
    case dht_net:find_node({IP, Port}, ID) of
        {error, timeout} -> ok;
        {error, Err} ->
            error_logger:info_report([{unrecognized_error, Err}]),
            ok;
        {nodes, _, _Token, Nodes} ->
            [spawn_link(fun() -> dht_net:ping({I, P}) end) || {_, I, P} <- Nodes],
            ok
    end
  end),
  ok.

-spec verify(dht:peer(), dht:peer(), map()) -> pid().
verify({QID, QIP, QPort} = QNode, Node, Opts) ->
    spawn_link(fun() ->
        case dht_net:ping({QIP, QPort}) of
            pang -> dht_state:request_timeout(QNode);
            {ok, QID} -> ok;
            {ok, _Other} -> dht_state:request_timeout(QNode)
        end,
        dht_state:request_success(Node, Opts)
    end).
