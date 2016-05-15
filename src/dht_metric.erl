%%% @doc Internal/external representation of DHT IDs
%% In the DHT system, the canonical ID is a 160 bit integer. This ID and its operation
%% induces a metric on which everything computes. In this DHT It is 160 bit integers and
%% The XOR operation is used as the composition.
%%
%% We have to pick an internal representation of these in our system, so we have a canonical way of
%% representing these. The internal representation chosen are 160 bit integers,
%% which in erlang are the integer() type.
%%% @end
%%% @private
-module(dht_metric).

-export([mk/0, d/2]).
-export([neighborhood/3]).

%% @doc mk_random_id/0 constructs a new random ID
%% @end
-spec mk() ->  dht:id().
mk() ->
	<<ID:160>> = dht_rand:crypto_rand_bytes(20),
	ID.

%% @doc dist/2 calculates the distance between two random IDs
%% @end
-spec d(dht:id(), dht:id()) ->  dht:id().
d(ID1, ID2) -> ID1 bxor ID2.

%% @doc neighborhood/3 finds known nodes close to an ID
%% neighborhood(ID, Nodes, Limit) searches for Limit nodes in the neighborhood of ID. Nodes is the list of known nodes.
%% @end
-spec neighborhood(ID, Nodes, Limit) -> [dht:peer()]
  when
    ID :: dht:id(),
    Nodes :: [dht:peer()],
    Limit :: non_neg_integer().

neighborhood(ID, Nodes, Limit) ->
    DF = fun({NID, _, _}) -> d(ID, NID) end,
    case lists:sort(fun(X, Y) -> DF(X) < DF(Y) end, Nodes) of
        Sorted when length(Sorted) =< Limit -> Sorted;
        Sorted when length(Sorted) > Limit ->
            {H, _T} = lists:split(Limit, Sorted),
            H
    end.

