%%% @doc Module dht_proto handles syntactical DHT protocol encoding/decoding.
%%% @end
-module(dht_proto).

-export([encode/1, decode/1]).

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

decode(<<"EDHT-KDM-", ?VERSION:8, Tag:2/binary, $q, Query/binary>>) ->
    {query, Tag, decode_query(Query)};
decode(<<"EDHT-KDM-", ?VERSION:8, Tag:2/binary, $r, Response/binary>>) ->
    {response, Tag, decode_response(Response)};
decode(<<"EDHT-KDM-", ?VERSION:8, Tag:2/binary, $e, ErrCode:16, ErrorString/binary>>) ->
    {error, Tag, ErrCode, ErrorString}.
    
decode_query(<<$p>>) -> ping;
decode_query(<<$f, $n, ID:256>>) -> {find, node, ID};
decode_query(<<$f, $v, ID:256>>) -> {find, value, ID};
decode_query(<<$s, Token:4/binary, ID:256, Port:16>>) -> {store, Token, ID, Port}.

decode_response(<<$p, ID:256>>) -> {ping, ID};
decode_response(<<$f, $n, L:8, Pack/binary>>) -> {find, node, decode_nodes(L, Pack)};
decode_response(<<$f, $v, Token:4/binary, L:8, Pack/binary>>) -> {find, value, Token, decode_nodes(L, Pack)};
decode_response(<<$s>>) -> store.

%% Force recognition of the correct number of incoming arguments.
decode_nodes(0, <<>>) -> [];
decode_nodes(K, <<ID:256, B1, B2, B3, B4, Port:16, Nodes/binary>>) ->
    [{ID, {B1, B2, B3, B4}, Port} | decode_nodes(K-1, Nodes)].
