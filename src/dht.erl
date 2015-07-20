%%% @doc API for the DHT application.
%%
%% This module provides the API of the DHT application. There are two
%% major groups of calls: Low level DHT code, and high level API which
%% is the one you are going to use, most likely.
%%
%% The Low-level API exposes the low-level four commands you can execute
%% against the DHT. The High-level API exposes a more useful Set of functions
%% for general use.
%% @end

%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
-module(dht).

%% High-level API
-export([
         lookup/1,
         enter/2,
         delete/1
]).
    
%% Low-level API for others to use
-export([
	ping/1,
	store/4,
	find_node/2,
	find_value/2
]).

-type id() :: non_neg_integer().
-type tag() :: binary().
-type token() :: binary().

-type peer() :: {id(), inet:ip_address(), inet:port_number()}.
-type range() :: {id(), id()}.

-export_type([id/0, tag/0, token/0]).
-export_type([peer/0, range/0]).

%% High-level API Functions
%% ------------------------------

%% @doc delete/1 removes an `ID' inserted by this node
%%
%% Remove the tracking of the `ID' inserted by this node. If no such `ID' exist,
%% this is a no-op.
%% @end
delete(ID) ->
    dht_track:delete(ID).

%% @doc enter/2 associates an `ID' with a `Location' on this node.
%%
%% Associate the given `ID' with a `Location'. Lookups to this ID will
%% henceforth contain this node as a possible peer for the ID. The protocol
%% which is used to transfer the data afterwards is not specified by the DHT
%%
%% @end
-spec enter(ID, Location) -> ok
    when
        ID       :: id(),
        Location :: {inet:ip_address(), inet:port_number()}.
enter(ID, Location) ->
    dht_track:store(ID, Location).

%% @doc lookup/1 searches the DHT for nodes which can give you an `ID' back
%%
%% Perform a lookup operation. It returns a list of pairs {IP, Port} pairs
%% which the DHT knows about that given ID
%%
%% @end
lookup(ID) ->
    #{ found := Fs } = dht_search:run(find_value, ID),
    [{IP, Port} || {_ID, IP, Port} <- Fs].

%% Low-level API Functions

%% @doc ping/1 queries a peer with a ping message
%%
%% Low level message which allows you to program your own strategies.
%%
%% @end
-spec ping(Location) -> pang | {ok, id()} | {error, Reason}
  when
    Location :: {inet:ip_address(), inet:port_number()},
    Reason   :: any().
ping(Peer) ->
    dht_net:ping(Peer).

%% @doc store/4 stores a new association at a peer
%%
%% Low level message which allows you to program your own strategies.
%%
%% @end
store(Peer, Token, ID, Port) ->
    dht_net:store(Peer, Token, ID, Port).

%% @doc find_node/2 performs a `find_node' query
%%
%% Low level message which allows you to program your own strategies.
%%
%% @end
find_node({IP, Port}, Node) ->
    dht_net:find_node({IP, Port}, Node).

%% @doc find_value/2 performs a `find_value' query
%%
%% Low level message which allows you to program your own strategies.
%%
%% @end
find_value({IP, Port}, ID) ->
    dht_net:find_value({IP, Port}, ID).
