-module(dht_bt_proto).

-export([decode_msg/1, decode_response/2]).
-export([encode_query/2, encode_response/2]).

-export([handle_query/6]).

decode_msg(InMsg) ->
    {ok, Msg} = benc:decode(InMsg),
    MsgID = benc:get_value(<<"t">>, Msg),
    case benc:get_value(<<"y">>, Msg) of
        <<"q">> ->
            MString = benc:get_value(<<"q">>, Msg),
            Method  = decode_method(MString),
            Params  = benc:get_value(<<"a">>, Msg),
            {Method, MsgID, Params};
        <<"r">> ->
            Values = benc:get_value(<<"r">>, Msg),
            {response, MsgID, Values};
        <<"e">> ->
            [ECode, EMsg] = benc:get_value(<<"e">>, Msg),
            {error, MsgID, ECode, EMsg}
    end.

decode_response(ping, Values) ->
     dht:integer_id(benc:get_value(<<"id">>, Values));
decode_response(find_node, Values) ->
    ID = dht:integer_id(benc:get_value(<<"id">>, Values)),
    BinNodes = benc:get_value(<<"nodes">>, Values),
    Nodes = compact_to_node_infos(BinNodes),
    {ID, Nodes};
decode_response(get_peers, Values) ->
    ID = dht:integer_id(benc:get_value(<<"id">>, Values)),
    Token = benc:get_value(<<"token">>, Values),
    NoPeers = make_ref(),
    MaybePeers = benc:get_value(<<"values">>, Values, NoPeers),
    {Peers, Nodes} = case MaybePeers of
        NoPeers when is_reference(NoPeers) ->
            BinCompact = benc:get_value(<<"nodes">>, Values),
            INodes = compact_to_node_infos(BinCompact),
            {[], INodes};
        BinPeers when is_list(BinPeers) ->
            PeerLists = [compact_to_peers(N) || N <- BinPeers],
            IPeers = lists:flatten(PeerLists),
            {IPeers, []}
    end,
    {ID, Token, Peers, Nodes};
decode_response(announce, Values) ->
    dht:integer_id(benc:get_value(<<"id">>, Values)).

encode_query(Req, MsgID) ->
    case Req of
        ping -> encode_request(<<"ping">>, [], MsgID);
        {find_node, Target} -> encode_request(<<"find_node">>, [{<<"target">>, <<Target:160>>}], MsgID);
        {get_peers, InfoHash} -> encode_request(<<"get_peers">>, [{<<"info_hash">>, <<InfoHash:160>>}], MsgID);
        {announce, InfoHash, Token, BTPort} ->
        	LHash = dht:bin_id(InfoHash),
        	encode_request(
        		<<"announce_peer">>,
        		[{<<"info_hash">>, LHash},
        		 {<<"port">>, BTPort},
        		 {<<"token">>, Token}],
        		MsgID)
    end.

encode_request(Method, Params, MsgID) ->
    Msg = [{<<"y">>, <<"q">>}, {<<"q">>, Method}, {<<"t">>, MsgID}, {<<"a">>, Params ++ common_params()}],
    benc:encode(Msg).

encode_response(MsgID, Values) ->
    Msg = [
       {<<"y">>, <<"r">>},
       {<<"t">>, MsgID},
       {<<"r">>, Values}],
    benc:encode(Msg).

handle_query(ping, _, Peer, MsgID, Self, _Tokens) ->
    dht_net:return(Peer, MsgID, common_params(Self));
handle_query('find_node', Params, Peer, MsgID, Self, _Tokens) ->
    Target = dht:integer_id(benc:get_value(<<"target">>, Params)),
    CloseNodes = filter_node(Peer, dht_state:closest_to(Target)),
    BinCompact = node_infos_to_compact(CloseNodes),
    Values = [{<<"nodes">>, BinCompact}],
    dht_net:return(Peer, MsgID, common_params(Self) ++ Values);
handle_query('get_peers', Params, Peer, MsgID, Self, Tokens) ->
    InfoHash = dht:integer_id(benc:get_value(<<"info_hash">>, Params)),
    %% TODO: handle non-local requests.
    Values = case dht_tracker:get_peers(InfoHash) of
        [] ->
            Nodes = filter_node(Peer, dht_state:closest_to(InfoHash)),
            BinCompact = node_infos_to_compact(Nodes),
            [{<<"nodes">>, BinCompact}];
        Peers ->
            ok = lager:debug("Get a list of peers from the local tracker ~p", [Peers]),
            PeerList = [peers_to_compact([P]) || P <- Peers],
            [{<<"values">>, PeerList}]
    end,
    RecentToken = queue:last(Tokens),
    Token = [{<<"token">>, token_value(Peer, RecentToken)}],
    dht_net:return(Peer, MsgID, common_params(Self) ++ Token ++ Values);
handle_query('announce', Params, {IP, _} = Peer, MsgID, Self, Tokens) ->
    InfoHash = dht:integer_id(benc:get_value(<<"info_hash">>, Params)),
    BTPort = benc:get_value(<<"port">>,   Params),
    Token = benc:get_binary_value(<<"token">>, Params),
    case is_valid_token(Token, Peer, Tokens) of
        true ->
            %% TODO: handle non-local requests.
            dht_tracker:announce(InfoHash, IP, BTPort);
        false ->
            ok = lager:error("Invalid token from ~p: ~w", [Peer, Token])
    end,
    dht_net:return(Peer, MsgID, common_params(Self)).

%% INTERNAL FUNCTIONS
%% --------------------------------------------

decode_method(<<"ping">>) -> ping;
decode_method(<<"find_node">>) -> find_node;
decode_method(<<"get_peers">>) -> get_peers;
decode_method(<<"announce_peer">>) -> announce.

compact_to_node_infos(<<>>) ->
    [];
compact_to_node_infos(<<ID:160, A0, A1, A2, A3,
                        Port:16, Rest/binary>>) ->
    IP = {A0, A1, A2, A3},
    NodeInfo = {ID, IP, Port},
    [NodeInfo|compact_to_node_infos(Rest)].
    
compact_to_peers(<<>>) -> [];
compact_to_peers(<<A0, A1, A2, A3, Port:16, Rest/binary>>) ->
    Addr = {A0, A1, A2, A3},
    [{Addr, Port}|compact_to_peers(Rest)].

%% Default args. Returns a proplist of default args
common_params() ->
    NodeID = dht_state:node_id(),
    common_params(NodeID).

common_params(NodeID) ->
    [{<<"id">>, dht:bin_id(NodeID)}].

%% @doc Delete node with `IP' and `Port' from the list.
filter_node({IP, Port}, Nodes) ->
    [X || {_NID, NIP, NPort}=X <- Nodes, NIP =/= IP orelse NPort =/= Port].

