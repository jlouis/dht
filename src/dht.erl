%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc This module provides few helpers and supervise the DHT processes.
%% Starts two workers: {@link etorrent_dht_state} and {@link etorrent_dht_net}.
%% @end
-module(dht).
-export([
	find_self/0
]).

-type node_id() :: non_neg_integer().
-type node_info() :: {node_id(), inet:ip_address(), inet:port_number()}.
-type peer_info() :: {inet:ip_address(), inet:port_number()}.


-export_type([node_id/0, node_info/0, peer_info/0]).

find_self() ->
    Self = dht_state:node_id(),
    dht_net:find_node_search(Self).


