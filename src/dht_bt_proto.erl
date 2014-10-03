-module(dht_bt_proto).

-export([decode_as_query/1, decode_as_response/2]).
-export([encode/1, encode_response/2]).

-export([handle_query/6]).

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
        {announce_peer, Token, IH, implied} ->
        	encode_response(MsgID, [{<<"token">>, Token}, {<<"info_hash">>, <<IH:160>>}, {<<"implied_port">>, 1}, {<<"port">>, 0} | Base]);
        {announce_peer, Token, IH, Port} ->
        	encode_response(MsgID, [{<<"token">>, Token}, {<<"info_hash">>, <<IH:160>>}, {<<"port">>, Port} | Base])
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

handle_query(ping, _, Peer, MsgID, Self, _Tokens) ->
    dht_net:return(Peer, MsgID, common_params(Self));
handle_query('find_node', Params, Peer, MsgID, Self, _Tokens) ->
    <<Target:160>> = benc:get_value(<<"target">>, Params),
    CloseNodes = filter_node(Peer, dht_state:closest_to(Target)),
    BinCompact = node_infos_to_compact(CloseNodes),
    Values = [{<<"nodes">>, BinCompact}],
    dht_net:return(Peer, MsgID, common_params(Self) ++ Values);
handle_query('get_peers', Params, Peer, MsgID, Self, Tokens) ->
    <<InfoHash:160>> = benc:get_value(<<"info_hash">>, Params),
    %% TODO: handle non-local requests.
    Values = case dht_tracker:get_peers(InfoHash) of
        [] ->
            Nodes = filter_node(Peer, dht_state:closest_to(InfoHash)),
            BinCompact = node_infos_to_compact(Nodes),
            [{<<"nodes">>, BinCompact}]
    end,
    RecentToken = queue:last(Tokens),
    Token = [{<<"token">>, token_value(Peer, RecentToken)}],
    dht_net:return(Peer, MsgID, common_params(Self) ++ Token ++ Values);
handle_query('announce_peer', Params, {IP, _} = Peer, MsgID, Self, Tokens) ->
    <<InfoHash:160>> = benc:get_value(<<"info_hash">>, Params),
    BTPort = benc:get_value(<<"port">>,   Params),
    Token = benc:get_binary_value(<<"token">>, Params),
    case is_valid_token(Token, Peer, Tokens) of
        true ->
            %% TODO: handle non-local requests.
            dht_tracker:announce(InfoHash, IP, BTPort);
        false ->
            ok = error_logger:info_msg("Invalid token from ~p: ~w", [Peer, Token])
    end,
    dht_net:return(Peer, MsgID, common_params(Self)).

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

%% @doc Delete node with `IP' and `Port' from the list.
filter_node({IP, Port}, Nodes) ->
    [X || {_NID, NIP, NPort}=X <- Nodes, NIP =/= IP orelse NPort =/= Port].

node_infos_to_compact(NodeList) ->
    node_infos_to_compact(NodeList, <<>>).
node_infos_to_compact([], Acc) ->
    Acc;
node_infos_to_compact([{ID, {A0, A1, A2, A3}, Port}|T], Acc) ->
    CNode = <<ID:160, A0, A1, A2, A3, Port:16>>,
    node_infos_to_compact(T, <<Acc/binary, CNode/binary>>).
    
token_value({IP, Port}, Token) ->
    Hash = erlang:phash2({IP, Port, Token}),
    <<Hash:32>>.
    
is_valid_token(TokenValue, Peer, Tokens) ->
    ValidValues = [token_value(Peer, Token) || Token <- queue:to_list(Tokens)],
    lists:member(TokenValue, ValidValues).
