%%% @doc Internal/external representation of DHT IDs
%%% <p>In the DHT system, the canonical ID is a 160 bit integer. This ID and its operation
%%% induces a metric on which everything computes. In this DHT It is 160 bit integers and
%%% The XOR operation is used as the composition.
%%% </p>
%%% <p>
%%% We have to pick an internal representation of these in our system, so we have a canonical way of
%%% representing these. The internal representation chosen are 160 bit integers,
%%% which in erlang are the integer() type.
%%% @end
-module(dht_id).

-export([mk_random_id/0, dist/2]).
-export([neighborhood/3]).

-type id() :: non_neg_integer().

-record(peer, {
	id :: id(),
	addr :: inet:ip_address(),
	port :: inet:port_number()
}).

-type peer() :: #peer{}.
-export_type([id/0, peer/0]).

%% @doc mk_random_id/0 constructs a new random ID
%% @end
-spec mk_random_id() -> id().
mk_random_id() ->
	<<ID:160>> = crypto:rand_bytes(20),
	ID.

%% @doc dist/2 calculates the distance between two random IDs
%% @end
dist(ID1, ID2) -> ID1 bxor ID2.

%% @doc neighborhood/3 finds known nodes close to an ID
%% neighborhood(ID, Nodes, Limit) searches for Limit nodes in the neighborhood of ID. Nodes is the list of known nodes.
%% @end
neighborhood(ID, Nodes, Limit) ->
	Distances = [{dist(ID, NID), N} || #peer { id = NID } = N <- Nodes],
	Eligible = case lists:sort(Distances) of
	    Sorted when length(Sorted) =< Limit -> Sorted;
	    Sorted when length(Sorted) > Limit ->
	        {H, _T} = lists:split(Limit, Sorted),
	        H
	end,
	[S || {_, S} <- Eligible].

