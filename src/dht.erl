%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc This module provides few helpers and supervise the DHT processes.
%% Starts two workers: {@link etorrent_dht_state} and {@link etorrent_dht_net}.
%% @end
-module(dht).

%% API for others to use
-export([
	ping/1,
	store/2,
	find_node/1,
	find_value/1
]).

-type id() :: non_neg_integer().
-type tag() :: binary().
-type token() :: binary().

-type peer() :: {id(), inet:ip_address(), inet:port_number()}.
-type range() :: {id(), id()}.

-export_type([id/0, tag/0, token/0]).
-export_type([peer/0, range/0]).

%% API Functions
-spec ping({IP, Port}) -> pang | {ok, id()} | {error, Reason}
  when
    IP :: inet:ip_address(),
    Port :: inet:port_number(),
    Reason :: any().

ping(Peer) ->
	dht_net:ping(Peer).
	
%% @todo This is currently miserably wrong since there is something murky in the protocol.
store(ID, OPort) ->
    case dht_search:find(find_value, ID) of
        {Store, _, _} ->
            [store_id(Peer, ID, OPort) || Peer <- Store],
            ok
    end.

store_id({Peer, Token}, ID, OPort) ->
    {ok, _} = dht_net:store(Peer, Token, ID, OPort),
    ok.

find_node(Node) ->
	dht_net:find_node(Node).

find_value(ID) ->
    case dht_search:find(find_value, ID) of
        {_Store, Found, _} -> Found
    end.
