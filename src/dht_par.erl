%%% @doc Module dht_par runs commands in parallel for the DHT
%%% @end
%%% @private
-module(dht_par).

-export([pmap/2]).

%% @doc Very very parallel pmap implementation :)
%% @end
%% @todo: fix this parallelism
-spec pmap(fun((A) -> B), [A]) -> [B].
pmap(_F, []) -> [];
pmap(F, [E | Es]) -> [F(E) | pmap(F, Es)].
