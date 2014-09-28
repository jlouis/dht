%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc This module provides few helpers and supervise the DHT processes.
%% Starts two workers: {@link etorrent_dht_state} and {@link etorrent_dht_net}.
%% @end
-module(dht).
-export([
	find_self/0
]).

%% API for others to use
-export([
	ping/2,
	store/3,
	store_term/3,
	find_node/3,
	find_value/3
]).

-type node_id() :: non_neg_integer().
-type node_t() :: {node_id(), inet:ip_address(), inet:port_number()}.
-type peer_info() :: {inet:ip_address(), inet:port_number()}.


-export_type([node_id/0, node_t/0, peer_info/0]).

find_self() ->
    Self = dht_state:node_id(),
    dht_net:find_node_search(Self).


%% API Functions
-spec ping(IP, Port) -> pang | node_id()
  when
    IP :: inet:ip_address(),
    Port :: inet:port_number().

ping(IP, Port) ->
	dht_net:ping(IP, Port).
	
store(IP, Port, Data) ->
	dht_net:store(IP, Port, Data).

store_term(IP, Port, Data) ->
	store(IP, Port, term_to_binary(Data, [compressed])).


find_node(IP, Port, Target) ->
	dht_net:find_node(IP, Port, Target).

find_value(IP, Port, ID) ->
	dht_net:find_value(IP, Port, ID).

