%% Metadata downloader.
-module(etorrent_magnet).
-export([download_meta_info/2]).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_RECEIVE_TIMEOUT, 5000).
-define(DEFAULT_AWAIT_TIMEOUT, 25000).
-define(METADATA_BLOCK_BYTE_SIZE, 16384). %% 16KiB (16384 Bytes)

%% The extension message IDs are the IDs used to send the extension messages
%% to the peer sending this handshake.
%% i.e. The IDs are local to this particular peer.


%% It is metadata extension id for this node.
%% It will be passed during handshake.
%% It can be any from 1..255.
-define(UT_METADATA_EXT_ID, 15).


-type peerid() :: <<_:160>>.
-type infohash_bin() :: <<_:160>>.
-type infohash_int() :: integer().
-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type bcode() :: etorrent_types:bcode().


-spec download_meta_info(LocalPeerId::peerid(), InfoHashNum::infohash_int()) -> list().
download_meta_info(LocalPeerId, InfoHashNum) ->
    lager:debug("Download metainfo for ~s.",
                [integer_hash_to_literal(InfoHashNum)]),
    InfoHashBin = info_hash_to_binary(InfoHashNum),
    Nodes = fetch_nodes(InfoHashNum),
    lager:debug("Node list: ~p~n", [Nodes]),
    TagRef = make_ref(),
    Peers = [Peer
            || {_, IP, Port} <- Nodes,
               Peer <- fetch_peers(IP, Port, InfoHashNum)],
    Peers1 = lists:usort(Peers),
    lager:debug("Peers ~p.", [Peers]),
    Workers = traverse_peers(LocalPeerId, InfoHashBin, TagRef, Peers1, []),
    await_respond(Workers, TagRef).

fetch_peers(IP, Port, InfoHashNum) ->
    case etorrent_dht_net:get_peers(IP, Port, InfoHashNum) of
        {_,_,Peers,_} -> Peers;
        {error, Reason} -> lager:info("Skip error ~p.", [Reason]), []
    end.

traverse_peers(LocalPeerId, InfoHashBin, TagRef,
               [{IP, Port}|Peers], Workers) ->
    Self = self(),
    Worker = spawn_link(fun() ->
        Mess =
            try
                {ok, Metadata} =
                connect_and_download_metainfo(LocalPeerId, IP, Port, InfoHashBin),
                {ok, Metadata}
            catch error:Reason ->
                {error, {Reason, erlang:get_stacktrace()}}
            end,
            Self ! {TagRef, self(), Mess}
        end),
    traverse_peers(LocalPeerId, InfoHashBin, TagRef, Peers, [Worker|Workers]);
traverse_peers(_LocalPeerId, _InfoHashBin, _TagRef, [], Workers) ->
    Workers.

await_respond([], _TagRef) ->
    {error, all_workers_exited};
await_respond([_|_]=Workers, TagRef) ->
    receive
        {TagRef, Pid, {ok, Metadata}} ->
            [exit(Worker, normal) || Worker <- Workers -- [Pid]],
            {ok, Metadata};
        {TagRef, Pid, {error, _reason}} ->
            await_respond(Workers -- [Pid], TagRef)
       ;Unmatched ->
            io:format(user, "Unmatched message: ~p~n", [Unmatched]),
            await_respond(Workers, TagRef)
        after ?DEFAULT_AWAIT_TIMEOUT ->
            [exit(Worker, normal) || Worker <- Workers],
            {error, await_timeout}
    end.


fetch_nodes(InfoHashNum) ->
    %% Fetch node list.
    %% [{NodeIdNum, IP, Port}]
    etorrent_dht_net:find_node_search(InfoHashNum).



-spec connect_and_download_metainfo(LocalPeerId, IP, Port, InfoHashBin) -> term() when
    InfoHashBin :: infohash_bin(),
    LocalPeerId :: peerid(),
    IP ::  ipaddr(),
    Port :: portnum().

connect_and_download_metainfo(LocalPeerId, IP, Port, InfoHashBin) ->
    {ok, Socket} = gen_tcp:connect(IP, Port, [binary, {active, false}],
                                   ?DEFAULT_CONNECT_TIMEOUT),
    try
        {ok, Capabilities, RemotePeerId} = etorrent_proto_wire:
            initiate_handshake(Socket, LocalPeerId, InfoHashBin),
        io:format(user, "Capabilities: ~p~n", [Capabilities]),
        assert_extended_messaging_support(Capabilities),
        {ok, HeaderMsg} = extended_messaging_handshake(Socket),
        io:format(user, "Extension header: ~p~n", [HeaderMsg]),
        MetadataExtId = metadata_ext_id(HeaderMsg),
        assert_metadata_extension_support(MetadataExtId),
        MetadataSize = metadata_size(HeaderMsg),
        assert_valid_metadata_size(MetadataSize),
        {ok, Metadata} = download_metadata(Socket, MetadataExtId, MetadataSize),
        assert_valid_metadata(Metadata, MetadataSize, InfoHashBin),
%       io:format(user, "Dowloaded metadata: ~n~p~n", [Metadata]),
        {ok, Metadata}
    after
        gen_tcp:close(Socket)
    end.

assert_extended_messaging_support(Capabilities) ->
    [error(extended_msg_not_supported)
     || not lists:member(extended_messaging, Capabilities)],
    ok.

info_hash_to_binary(InfoHashNum) when is_integer(InfoHashNum) ->
    <<InfoHashNum:160>>.


%% Returns an extension header hand-shake message.
extended_messaging_handshake(Socket) ->
    {ok, _Size} =
        etorrent_proto_wire:send_msg(Socket, {extended, 0, encoded_handshake_payload()}),
    {ok, {extended, 0, HeaderMsgBin}} = receive_msg(Socket),
    {ok, _HeaderMsg} = etorrent_bcoding:decode(HeaderMsgBin).

send_ext_msg(Socket, ExtMsgId, EncodedExtMsg) ->
    {ok, _Size} =
        etorrent_proto_wire:send_msg(Socket, {extended, ExtMsgId, EncodedExtMsg}).

download_metadata(Socket, MetadataExtId, MetadataSize) ->
    download_metadata(Socket, MetadataExtId, MetadataSize, 0, <<>>).

download_metadata(Socket, MetadataExtId, LeftSize, PieceNum, Data) ->
    send_ext_msg(Socket, MetadataExtId, piece_request_msg(PieceNum)),
    {ok, RespondMsgBin} = receive_ext_msg(Socket, ?UT_METADATA_EXT_ID),
    {RespondMsg, Piece} = etorrent_bcoding2:decode(RespondMsgBin),
    case decode_metadata_respond(RespondMsg) of
        {data, PieceNum, TotalSize} ->
            assert_total_size(LeftSize, TotalSize),
            Data2 = <<Data/binary, Piece/binary>>,
            case LeftSize - TotalSize of
                0 -> {ok, Data2};
                LeftSize2 when LeftSize2 > 0 ->
                    download_metadata(Socket, MetadataExtId, LeftSize2, PieceNum+1, Data2)
            end
    end.

receive_ext_msg(Socket, MetadataExtId) ->
    case receive_msg(Socket) of
        {ok, {extended, MetadataExtId, MsgBin}} ->
%           io:format(user, "Ext message was received: ~n~p~n", [MsgBin]),
            {ok, MsgBin};
        {ok, OtherMess} ->
            io:format(user, "Unexpected message was received:~n~p~n",
                      [OtherMess]),
            receive_ext_msg(Socket, MetadataExtId)
    end.

decode_metadata_respond(RespondMsg) ->
    V = fun(X) -> etorrent_bcoding:get_value(X, RespondMsg) end,
    case V(<<"msg_type">>) of
        1 -> {data, V(<<"piece">>), V(<<"total_size">>)};
        2 -> {reject, V(<<"piece">>)}
    end.


piece_request_msg(PieceNum) ->
    PL = [{<<"msg_type">>, 0}, {<<"piece">>, PieceNum}],
    iolist_to_binary(etorrent_bcoding:encode(PL)).


receive_msg(Socket) ->
    %% Read 4 bytes.
    {ok, <<MsgSize:32/big>>} = gen_tcp:recv(Socket, 4, ?DEFAULT_RECEIVE_TIMEOUT),
    {ok, Msg} = gen_tcp:recv(Socket, MsgSize, ?DEFAULT_RECEIVE_TIMEOUT),
    {ok, etorrent_proto_wire:decode_msg(Msg)}.


-spec metadata_size(HeaderMsg) -> Size when
    HeaderMsg :: bcode(),
    Size :: non_neg_integer() | undefined.

metadata_size(HeaderMsg) ->
    etorrent_bcoding:get_value(<<"metadata_size">>, HeaderMsg).


-spec metadata_ext_id(HeaderMsg) -> ExtId when
    HeaderMsg :: bcode(),
    ExtId :: non_neg_integer() | undefined.

metadata_ext_id(HeaderMsg) ->
    case etorrent_bcoding:get_value(<<"m">>, HeaderMsg) of
        undefined ->
            undefined;
        M ->
            etorrent_bcoding:get_value(<<"ut_metadata">>, M)
    end.

assert_metadata_extension_support(Size) when Size > 0, is_integer(Size) ->
    ok.

assert_valid_metadata_size(Size) when Size > 0, is_integer(Size) ->
    ok.


%% Extension header
%% Example extension handshake message:
%% {'m': {'ut_metadata', 3}, 'metadata_size': 31235}
header_example() ->
    [{<<"m">>,
          [{<<"LT_metadata">>,14},
           {<<"lt_donthave">>,5},
           {<<"upload_only">>,2},
           {<<"ut_metadata">>,15},
           {<<"ut_pex">>,1}]},
         {<<"metadata_size">>,14857},
         {<<"reqq">>,250},
         {<<"v">>,<<"Deluge 1.3.3">>},
         {<<"yourip">>,<<127,0,0,1>>}].



%-include_lib("eunit/include/eunit.hrl").


%% If the piece is the last piece of the metadata, it may be less than 16kiB.
%% If it is not the last piece of the metadata, it MUST be 16kiB.
assert_total_size(LeftSize, ?METADATA_BLOCK_BYTE_SIZE)
    when LeftSize >= ?METADATA_BLOCK_BYTE_SIZE ->
    ok;
assert_total_size(LeftSize, LeftSize) ->
    %% Last piece
    ok.


assert_valid_metadata(Metadata, MetadataSize, InfoHashBin) when
    byte_size(Metadata) =:= MetadataSize ->
    case crypto:sha(Metadata) of
        InfoHashBin -> ok;
        OtherHash ->
            error({bad_hash, [{expected, InfoHashBin}, {generated, OtherHash}]})
    end.



%% Send extended messaging handshake (type id = 0).
%% const().
encoded_handshake_payload() ->
    etorrent_proto_wire:extended_msg_contents(m_block()).

m_block() ->
    [{<<"ut_metadata">>,?UT_METADATA_EXT_ID}].

integer_hash_to_literal(InfoHashInt) when is_integer(InfoHashInt) ->
    io_lib:format("~40.16.0B", [InfoHashInt]).
