%%% @doc API for the DHT application.
%%
%% This module provides the API of the DHT application. There are two
%% major groups of calls: Low level DHT code, and high level API which
%% is the one you are going to use, most likely.
%%
%% The high level API is:
%%
%% <ul>
%% <li>lookup/1</li>
%% <li>enter/2</li>
%% <li>delete/1</li>
%% </ul>
%%
%% The Low-level API exposes the low-level four commands you can execute
%% against the DHT. It is intended for those who wants to build their own
%% subsystems around the DHT. The high-level API uses these to provide the
%% low level implementation:
%%
%% <ul>
%% <li>ping/1</li>
%% <li>store/4</li>
%% <li>find_node/2</li>
%% <li>find_value/2</li>
%% </ul>
%%
%% @end

%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
-module(dht).

%% High-level API
-export([
	node_id/0,
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
-type endpoint() :: {inet:ip_address(), inet:port_number()}.

-type range() :: {id(), id()}.

-export_type([id/0, tag/0, token/0]).
-export_type([peer/0, range/0, endpoint/0]).

%% High-level API Functions
%% ------------------------------

%% @doc node_id/0 returns the `ID' of the current node
%% @end
node_id() ->
    dht_state:node_id().

%% @doc delete/1 removes an `ID' inserted by this node
%%
%% Remove the tracking of the `ID' inserted by this node. If no such `ID' exist,
%% this is a no-op.
%%
%% It may take up to an hour before peers stop contacting you for the ID. This is
%% an artifact of the DHT, so you must be prepared to handle the case where you
%% are contacted for an old inexistant ID.
%% @end
delete(ID) ->
    dht_track:delete(ID).

%% @doc enter/2 associates an `ID' with a `Location' on this node.
%%
%% Associate the given `ID' with a `Port'. Lookups to this ID will
%% henceforth contain this node as a possible peer for the ID. The protocol
%% which is used to transfer the data afterwards is not specified by the DHT.
%%
%% Note that the IP address to use is given by the UDP port on which the system
%% is bound. This is a current setup in order to make it harder to craft packets
%% where you impersonate someone else. The hope is that egress filtering at ISPs
%% will help to mitigate eventual amplification attacks.
%%
%% @end
-spec enter(ID, Port) -> ok
    when
        ID       :: id(),
        Port :: inet:port_number().
enter(ID, Port) ->
    dht_track:store(ID, Port).

%% @doc lookup/1 searches the DHT for nodes which can give you an `ID' back
%%
%% Perform a lookup operation. It returns a list of pairs {IP, Port} pairs
%% which the DHT knows about that given ID.
%%
%% Assumptions:
%%
%% <ul>
%% <li>We are never looking up keys which we have locally stored at the service.</li>
%% <li>Before querying the network, we look into our own store. If we have entries
%%   locally, we pick those.</li>
%% <li>If we don't have entries ourselves, we look up in the swarm.</li>
%% </ul>
%% @end
lookup(ID) ->
    case dht_store:find(ID) of
        [] ->
            #{ found := Fs } = dht_search:run(find_value, ID),
            [{IP, Port} || {_ID, IP, Port} <- Fs];
        Peers -> Peers
    end.

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
