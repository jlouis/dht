%% Metadata downloader.
%% http://wiki.vuze.com/w/Magnet_link
-module(etorrent_magnet).
%% Public API
-export([download/1]).

%% Used for testing
-export([download_meta_info/2,
         build_torrent/2,
         write_torrent/2,
         parse_url/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_RECEIVE_TIMEOUT, 5000).
-define(DEFAULT_AWAIT_TIMEOUT, 25000).
-define(METADATA_BLOCK_BYTE_SIZE, 16384). %% 16KiB (16384 Bytes)

-define(URL_PARSER, mochiweb_util).

%% The extension message IDs are the IDs used to send the extension messages
%% to the peer sending this handshake.
%% i.e. The IDs are local to this particular peer.


%% It is metadata extension id for this node.
%% It will be passed during handshake.
%% It can be any from 1..255.
-define(UT_METADATA_EXT_ID, 15).


%% @doc Parse a magnet link into a tuple "{Infohash, Description, Trackers}".
-spec parse_url(Url) -> {XT, DN, [TR]} when
    Url :: string() | binary(),
    XT :: non_neg_integer(),
    DN :: string() | undefined,
    TR :: string().
parse_url(Url) ->
    {Scheme, _Netloc, _Path, Query, _Fragment} = ?URL_PARSER:urlsplit(Url),
    case Scheme of
        "magnet" ->
            %% Get a parameter proplist. Keys and values are strings.
            Params = ?URL_PARSER:parse_qs(Query),
            analyse_params(Params, undefined, undefined, []);
        _ ->
            error({unknown_scheme, Scheme, Url})
    end.

analyse_params([{K,V}|Params], XT, DN, TRS) ->
    case K of
        "xt" ->
            analyse_params(Params, V, DN, TRS);
        "dn" ->
            analyse_params(Params, XT, V, TRS);
        "tr" ->
            analyse_params(Params, XT, DN, [V|TRS]);
        _ ->
            lager:error("Unknown magnet link parameter ~p.", [K])
    end;
analyse_params([], undefined, _DN, _TRS) ->
    error(undefined_xt);
analyse_params([], XT, DN, TRS) ->
    {xt_to_integer(list_to_binary(XT)), DN, lists:reverse(TRS)}.

xt_to_integer(<<"urn:btih:", Base16:40/binary>>) ->
    list_to_integer(binary_to_list(Base16), 16);
xt_to_integer(<<"urn:btih:", Base32:32/binary>>) ->
    etorrent_utils:base32_binary_to_integer(Base32).


-type peerid() :: <<_:160>>.
-type infohash_bin() :: <<_:160>>.
-type infohash_int() :: integer().
-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type bcode() :: etorrent_types:bcode().

download({infohash, Hash}) ->
    LocalPeerId = etorrent_ctl:local_peer_id(),
    {ok, Info} = download_meta_info(LocalPeerId, Hash),
    {ok, DecodedInfo} = etorrent_bcoding:decode(Info),
    {ok, Torrent} = build_torrent(DecodedInfo, []),
    write_torrent(Torrent);
download({magnet_link, Link}) ->
    LocalPeerId = etorrent_ctl:local_peer_id(),
    {Hash, _, Trackers} = parse_url(Link),
    {ok, Info} = download_meta_info(LocalPeerId, Hash),
    {ok, DecodedInfo} = etorrent_bcoding:decode(Info),
    {ok, Torrent} = build_torrent(DecodedInfo, Trackers),
    write_torrent(Torrent).




%% @doc Write a value, returned from {@link download_meta_info/2} into a file.
-spec write_torrent(Out, Torrent::bcode()) -> {ok, Out} | {error, term()} when
    Out :: file:filename().
write_torrent(Out, Torrent) ->
    Encoded = etorrent_bcoding:encode(Torrent),
    case file:write_file(Out, Encoded) of
        ok -> {ok, Out};
        {error, Reason} -> {error, Reason}
    end.
    
-spec write_torrent(Torrent::bcode()) -> {ok, Out} | {error, term()} when
    Out :: file:filename().
write_torrent(Torrent) ->
    Name = filename:basename(etorrent_metainfo:get_name(Torrent)),
    Out = filename:join(etorrent_config:work_dir(), Name) ++ ".torrent",
    write_torrent(Out, Torrent).


-spec build_torrent(Info::bcode(), Trackers::[string()]) -> {ok, Torrent::bcode()}.
build_torrent(InfoDecoded, Trackers) ->
    Torrent = add_trackers(Trackers) ++ [{<<"info">>, InfoDecoded}],
    {ok, Torrent}.


add_trackers([T]) ->
    [{<<"announce">>, T}];
add_trackers([T|_]=Ts) ->
    Teer1 = [iolist_to_binary(X) || X <- Ts],
    [{<<"announce">>, iolist_to_binary(T)}, {<<"announce-list">>, [Teer1]}];
add_trackers([]) -> [].


-spec download_meta_info(LocalPeerId::peerid(), InfoHashNum::infohash_int()) -> binary().
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
        {TagRef, Pid, {error, Reason}} ->
            lager:debug("Worker Pid ~p exited with reason ~p~n", [Pid, Reason]),
            await_respond(Workers -- [Pid], TagRef)
       ;Unmatched ->
            lager:debug("Unmatched message: ~p~n", [Unmatched]),
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
        {ok, Capabilities, _RemotePeerId} = etorrent_proto_wire:
            initiate_handshake(Socket, LocalPeerId, InfoHashBin),
        lager:debug("Capabilities: ~p~n", [Capabilities]),
        assert_extended_messaging_support(Capabilities),
        {ok, HeaderMsg} = extended_messaging_handshake(Socket),
        lager:debug("Extension header: ~p~n", [HeaderMsg]),
        MetadataExtId = metadata_ext_id(HeaderMsg),
        assert_metadata_extension_support(MetadataExtId),
        MetadataSize = metadata_size(HeaderMsg),
        assert_valid_metadata_size(MetadataSize),
        {ok, Metadata} = download_metadata(Socket, MetadataExtId, MetadataSize),
        assert_valid_metadata(MetadataSize, InfoHashBin, Metadata),
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
    download_metadata(Socket, MetadataExtId, MetadataSize, MetadataSize, 0, <<>>).

download_metadata(Socket, MetadataExtId, LeftSize, MetadataSize, PieceNum, Data) ->
    send_ext_msg(Socket, MetadataExtId, piece_request_msg(PieceNum)),
    {ok, RespondMsgBin} = receive_ext_msg(Socket, ?UT_METADATA_EXT_ID),
    {RespondMsg, Piece} = etorrent_bcoding2:decode(RespondMsgBin),
    case decode_metadata_respond(RespondMsg) of
        {data, PieceNum, TotalSize} ->
            PieceSize = byte_size(Piece),
            assert_total_size(MetadataSize, TotalSize),
            assert_piece_size(LeftSize, PieceSize),
            Data2 = <<Data/binary, Piece/binary>>,
            case LeftSize - PieceSize of
                0 -> {ok, Data2};
                LeftSize2 when LeftSize2 > 0 ->
                    download_metadata(Socket, MetadataExtId, LeftSize2, 
                                      MetadataSize, PieceNum+1, Data2)
            end
    end.

receive_ext_msg(Socket, MetadataExtId) ->
    case receive_msg(Socket) of
        {ok, {extended, MetadataExtId, MsgBin}} ->
%           lager:debug("Ext message was received: ~n~p~n", [MsgBin]),
            {ok, MsgBin};
        {ok, OtherMess} ->
%           lager:debug("Unexpected message was received:~n~p~n",
%                     [OtherMess]),
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
assert_piece_size(LeftSize, ?METADATA_BLOCK_BYTE_SIZE)
    when LeftSize >= ?METADATA_BLOCK_BYTE_SIZE ->
    ok;
assert_piece_size(LeftSize, LeftSize) ->
    %% Last piece
    ok.

assert_total_size(TotalSize, TotalSize) ->
    ok;
assert_total_size(MetadataSize, TotalSize) ->
    error({bad_total_size, [{expected, MetadataSize}, {passed, TotalSize}]}).


assert_valid_metadata(MetadataSize, InfoHashBin, Metadata) when
    byte_size(Metadata) =:= MetadataSize ->
    case crypto:sha(Metadata) of
        InfoHashBin -> ok;
        OtherHash ->
            error({bad_hash, [{expected, InfoHashBin}, {generated, OtherHash}]})
    end;
assert_valid_metadata(MetadataSize, _InfoHashBin, Metadata) ->
    error({bad_size, [{expected, MetadataSize},
                      {generated, byte_size(Metadata)}]}).



%% Send extended messaging handshake (type id = 0).
%% const().
encoded_handshake_payload() ->
    etorrent_proto_wire:extended_msg_contents(m_block()).

m_block() ->
    [{<<"ut_metadata">>,?UT_METADATA_EXT_ID}].

integer_hash_to_literal(InfoHashInt) when is_integer(InfoHashInt) ->
    io_lib:format("~40.16.0B", [InfoHashInt]).


-ifdef(TEST).

colton_url() ->
    "magnet:?xt=urn:btih:b48ed25b01668963e1f0ff782be383c5e7060eb4&"
    "dn=Jonathan+Coulton+-+Discography&"
    "tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80&"
    "tr=udp%3A%2F%2Ftracker.publicbt.com%3A80&"
    "tr=udp%3A%2F%2Ftracker.istole.it%3A6969&"
    "tr=udp%3A%2F%2Ftracker.ccc.de%3A80".

parse_url_test_() ->
    [?_assertEqual(parse_url("magnet:?xt=urn:btih:IXE2K3JMCPUZWTW3YQZZOIB5XD6KZIEQ"),
                   {398417223648295740807581630131068684170926268560, undefined, []})
    ,?_assertEqual(parse_url(colton_url()),
                   {1030803369114085151184244669493103882218552823476,
                                   "Jonathan Coulton - Discography",
                                   ["udp://tracker.publicbt.com:80",
                                    "udp://tracker.openbittorrent.com:80",
                                    "udp://tracker.istole.it:6969",
                                    "udp://tracker.ccc.de:80"]})
    ].
-endif.
