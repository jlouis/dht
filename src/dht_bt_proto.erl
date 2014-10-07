-module(dht_bt_proto).

-export([decode_as_query/1, decode_as_response/2]).
-export([encode/1, encode_response/2]).

decode_as_query(Packet) ->
    {ok, M} = benc:decode(Packet),
    case benc:get_value(<<"y">>, M) of
        <<"q">> -> decode_query(M)
    end.
    
decode_query(M) ->
    Method = benc:get_value(<<"q">>, M), 
    Args = benc:get_value(<<"a">>, M),
    MsgID = benc:get_value(<<"t">>, M),
    <<ID:160>> = benc:get_value(<<"id">>, Args),
    decode_method(ID, MsgID, Method, maps:from_list(Args)).
   
decode_method(ID, MsgID, <<"ping">>, #{}) -> {query, ID, MsgID, ping};
decode_method(ID, MsgID, <<"announce_peer">>, #{ <<"info_hash">> := <<IH:160>>, <<"token">> := Token, <<"port">> := Port}) ->
    {query, ID, MsgID, {announce_peer, IH, Token, Port}};
decode_method(ID, MsgID, <<"find_node">>, #{ <<"target">> := <<IH:160>> }) ->
    {query, ID, MsgID, {find_node, IH}};
decode_method(ID, MsgID, <<"get_peers">>, #{ <<"info_hash">> := <<IH:160>> }) ->
    {query, ID, MsgID, {get_peers, IH}}.

decode_as_response(Method, Packet) ->
    {ok, M} = benc:decode(Packet),
    case benc:get_value(<<"y">>, M) of
        <<"r">> -> decode_response(Method, M);
        <<"e">> -> decode_error(M)
    end.

decode_response(Method, M) ->
    MsgID = benc:get_value(<<"t">>, M),
    Args = benc:get_value(<<"r">>, M),
    decode_response(MsgID, Method, maps:from_list(Args)).
    
decode_response(MsgID, ping, #{ <<"id">> := <<ID:160>> }) ->
	{response, ID, MsgID, ping};
decode_response(MsgID, find_node, #{ <<"id">> := <<ID:160>>, <<"nodes">> := PackedNodes}) ->
	{response, ID, MsgID, {find_node, unpack_nodes(PackedNodes)}};
decode_response(MsgID, get_peers, #{ <<"id">> := <<ID:160>>, <<"token">> := Token, <<"nodes">> := PackedNodes}) ->
	{response, ID, MsgID, {get_peers, Token, unpack_nodes(PackedNodes)}};
decode_response(MsgID, get_peers, #{ <<"id">> := <<ID:160>>, <<"token">> := Token, <<"values">> := VList}) ->
	{response, ID, MsgID, {get_peers, Token, VList}};
decode_response(MsgID, announce_peer,#{
		<<"id">> := <<ID:160>>,
		<<"implied_port">> := IPort,
		<<"info_hash">> := <<IH:160>>,
		<<"token">> := Token,
		<<"port">> := Port }) ->
	{response, ID, MsgID, {announce_peer, Token, IH, case IPort of 0 -> Port; 1 -> implied end}};
decode_response(MsgID, announce_peer, #{
		<<"id">> := <<ID:160>>,
		<<"info_hash">> := <<IH:160>>,
		<<"token">> := Token,
		<<"port">> := Port }) ->
	{response, ID, MsgID, {announce_peer, Token, IH, Port}}.

decode_error(M) ->
    MsgID = benc:get_value(<<"t">>, M),
    [ErrCode, ErrMsg] = benc:get_value(<<"e">>, M),
    {error, MsgID, ErrCode, ErrMsg}.

encode({query, OwnID, MsgID, Request}) -> encode_query(OwnID, MsgID, Request);
encode({error, MsgID, ErrCode, ErrMsg}) -> encode_error(MsgID, ErrCode, ErrMsg);
encode({response, ID, MsgID, Response}) -> encode_response(ID, MsgID, Response).

encode_query(OwnID, MsgID, ping) ->
	encode_query(OwnID, MsgID, <<"ping">>, #{});
encode_query(OwnID, MsgID, {find_node, ID}) ->
	encode_query(OwnID, MsgID, <<"find_node">>, #{ <<"target">> => <<ID:160>>});
encode_query(OwnID, MsgID, {get_peers, ID}) ->
	encode_query(OwnID, MsgID, <<"get_peers">>, #{ <<"info_hash">> => <<ID:160>> });
encode_query(OwnID, MsgID, {announce_peer, ID, Token, Port}) ->
	encode_query(OwnID, MsgID, <<"announce_peer">>,
		#{ <<"info_hash">> => <<ID:160>>, <<"token">> => Token, <<"port">> => Port}).
		
encode_query(OwnID, MsgID, Method, Args) ->
    benc:encode([
        {<<"y">>, <<"q">>},
        {<<"q">>, Method},
        {<<"t">>, MsgID},
        {<<"a">>, maps:to_list(Args) ++ common_params(OwnID)}
    ]).

encode_response(ID, MsgID, Req) ->
    Base = [{<<"id">>, <<ID:160>>}],
    case Req of
        ping -> encode_response(MsgID, Base);
        {find_node, Ns} -> encode_response(MsgID, [{<<"nodes">>, pack_nodes(Ns)} | Base]);
        {get_peers, Token, [{_, _,_} | _] = Ns} -> encode_response(MsgID, [{<<"token">>, Token}, {<<"nodes">>, pack_nodes(Ns)} | Base]);
        {get_peers, Token, Vs} -> encode_response(MsgID, [{<<"token">>, Token}, {<<"values">>, Vs} | Base]);
        announce_peer -> encode_response(MsgID, Base)
    end.
       
encode_response(MsgID, Values) ->
    benc:encode([
       {<<"y">>, <<"r">>},
       {<<"t">>, MsgID},
       {<<"r">>, Values}
    ]).

encode_error(MsgID, Code, Msg) when is_integer(Code), is_binary(Msg) ->
    benc:encode([
        {<<"y">>, <<"e">>},
        {<<"t">>, MsgID},
        {<<"e">>, [Code, Msg]}
    ]).

%% INTERNAL FUNCTIONS
%% --------------------------------------------

pack_nodes(X) -> pack_nodes(X, <<>>).

pack_nodes([], Acc) -> Acc;
pack_nodes([{ID, {A0, A1, A2, A3}, Port} | Rest], Acc) ->
      pack_nodes(Rest, <<Acc/binary, ID:160, A0, A1, A2, A3, Port:16>>).

unpack_nodes(<<>>) ->[];
unpack_nodes(<<ID:160, A0, A1, A2, A3,
                        Port:16, Rest/binary>>) ->
    IP = {A0, A1, A2, A3},
    NodeInfo = {ID, IP, Port},
    [NodeInfo|unpack_nodes(Rest)].
    
unpack_peers(<<>>) -> [];
unpack_peers(<<A0, A1, A2, A3, Port:16, Rest/binary>>) ->
    Addr = {A0, A1, A2, A3},
    [{Addr, Port}|unpack_nodes(Rest)].

common_params(NodeID) ->
    [{<<"id">>, <<NodeID:160>>}].

node_infos_to_compact(NodeList) ->
    node_infos_to_compact(NodeList, <<>>).
node_infos_to_compact([], Acc) ->
    Acc;
node_infos_to_compact([{ID, {A0, A1, A2, A3}, Port}|T], Acc) ->
    CNode = <<ID:160, A0, A1, A2, A3, Port:16>>,
    node_infos_to_compact(T, <<Acc/binary, CNode/binary>>).
