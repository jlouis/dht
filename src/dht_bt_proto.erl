-module(dht_bt_proto).

-export([decode_msg/1, decode_response/2]).
-export([encode_query/2, encode_response/2]).

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
    
encode_query({Method, Params}, MsgID) ->
    Msg = [
       {<<"y">>, <<"q">>},
       {<<"q">>, encode_method(Method)},
       {<<"t">>, MsgID},
       {<<"a">>, Params}],
    benc:encode(Msg).

encode_response(MsgID, Values) ->
    Msg = [
       {<<"y">>, <<"r">>},
       {<<"t">>, MsgID},
       {<<"r">>, Values}],
    benc:encode(Msg).

encode_method(ping) -> <<"ping">>;
encode_method(find_node) -> <<"find_node">>;
encode_method(get_peers) -> <<"get_peers">>;
encode_method(announce) -> <<"announce_peer">>.

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

