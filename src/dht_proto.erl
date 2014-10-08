%%% @doc Module dht_proto handles syntactical DHT protocol encoding/decoding.
%%% @end
-module(dht_proto).

-export([encode/1]).

-define(VERSION, 0).


%% Encoding on the wire
%% ------------------------
header(Tag) -> <<"EDHT-KDM-", ?VERSION:8, Tag/binary>>.

encode({query, Tag, Q}) -> [header(Tag), $q, encode_query(Q)];
encode({response, Tag, R}) -> [header(Tag), $r, encode_response(R)];
encode({error, Tag, ErrCode, ErrStr}) -> [header(Tag), $e, <<ErrCode:16, ErrStr/binary>>].

encode_query(ping) -> $p;
encode_query({find, node, ID}) -> <<$f, $n, ID:256>>;
encode_query({find, value, ID}) -> <<$f, $v, ID:256>>;
encode_query({store, Token, ID, Port}) -> <<$s, Token/binary, ID:256, Port:16>>.

encode_response({ping, ID}) -> <<$p, ID:256>>;
encode_response({find, node, Ns}) ->
    L = length(Ns),
    [<<$f, $n, L:8>>, encode_nodes(Ns)];
encode_response({find, value, Token, Vs}) ->
    L = length(Vs),
    [<<$f, $v, Token/binary, L:8>>, encode_nodes(Vs)];
encode_response(store) ->
    $s.
    
encode_nodes(Ns) -> << <<ID:256, B1, B2, B3, B4, Port:16>> || {ID, {B1, B2, B3, B4}, Port} <- Ns >>.

%% Decoding from the wire
%% -----------------------

