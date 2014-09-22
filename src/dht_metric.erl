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
-module(dht_metric).

-export([mk/0, d/2]).
-export([neighborhood/3]).

-type t() :: non_neg_integer().

-record(peer, {
	id :: t(),
	addr :: inet:ip_address(),
	port :: inet:port_number()
}).

-type peer() :: #peer{}.
-export_type([t/0, peer/0]).

%% @doc mk_random_id/0 constructs a new random ID
%% @end
-spec mk() ->  t().
mk() ->
	<<ID:160>> = crypto:rand_bytes(20),
	ID.

%% @doc dist/2 calculates the distance between two random IDs
%% @end
-spec d(t(), t()) ->  t().
d(ID1, ID2) -> ID1 bxor ID2.

%% @doc neighborhood/3 finds known nodes close to an ID
%% neighborhood(ID, Nodes, Limit) searches for Limit nodes in the neighborhood of ID. Nodes is the list of known nodes.
%% @end
-spec neighborhood(ID, Nodes, Limit) -> [peer()]
  when
    ID :: t(),
    Nodes :: [peer()],
    Limit :: non_neg_integer().

neighborhood(ID, Nodes, Limit) ->
	Distances = [{d(ID, NID), N} || #peer {id = NID} = N <- Nodes],
	Eligible = case lists:sort(Distances) of
	    Sorted when length(Sorted) =< Limit -> Sorted;
	    Sorted when length(Sorted) > Limit ->
	        {H, _T} = lists:split(Limit, Sorted),
	        H
	end,
	[S || {_, S} <- Eligible].

