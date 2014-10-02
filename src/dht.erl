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
	ping/1,
	store/3,
	store_term/3,
	find_node/1,
	find_value/1
]).

-type node_id() :: non_neg_integer().
-type node_t() :: {node_id(), inet:ip_address(), inet:port_number()}.
-type peer_info() :: {inet:ip_address(), inet:port_number()}.


-export_type([node_id/0, node_t/0, peer_info/0]).

find_self() ->
    Self = dht_state:node_id(),
    dht_net:find_node_search(Self).


%% API Functions
-spec ping({IP, Port}) -> pang | {ok, node_id()} | {error, Reason}
  when
    IP :: inet:ip_address(),
    Port :: inet:port_number(),
    Reason :: any().

ping(Peer) ->
	dht_net:ping(Peer).
	
store(IP, Port, Data) ->
	dht_net:store(IP, Port, Data).

store_term(IP, Port, Data) ->
	store(IP, Port, term_to_binary(Data, [compressed])).


find_node(Node) ->
	dht_net:find_node(Node).

find_value(ID) ->
	dht_net:find_value(ID).

