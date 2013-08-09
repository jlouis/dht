-module(etorrent_magnet_peer_ctl).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-type bcode() :: etorrent_types:bcode().

-record(mpeer_state, {
        torrent_id :: non_neg_integer(),
        ip,
        socket,
        send :: pid(),
        recv :: pid(),
        control :: pid(),
        metadata_size :: non_neg_integer(),
        metadata_ext_id :: non_neg_integer(),
        %% Was info about this process passed to magnet_ctl process?
        registered = false :: boolean()
}).

%% The extension message IDs are the IDs used to send the extension messages
%% to the peer sending this handshake.
%% i.e. The IDs are local to this particular peer.


%% It is metadata extension id for this node.
%% It will be passed during handshake.
%% It can be any from 1..255.
-define(UT_METADATA_EXT_ID, 15).
-define(METADATA_BLOCK_BYTE_SIZE, 16384). %% 16KiB (16384 Bytes)

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/8]).
-export([request_piece/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(TrackerUrl, LocalPeerId, RemotePeerId, InfoHash,
           TorrentId, {IP, Port}, Capabilities, Socket) ->
    Args = [TrackerUrl, LocalPeerId, RemotePeerId, InfoHash,
            TorrentId, {IP, Port}, Capabilities, Socket],
    gen_server:start_link(?MODULE, Args, []).

%% async.
request_piece(PeerCtl, PieceNum) ->
    gen_server:cast(PeerCtl, {piece_request, PieceNum}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([_TrackerUrl, _LocalPeerId, _RemotePeerId, _InfoHash,
      TorrentId, {IP, _Port}, Capabilities, Socket]) ->
    lager:debug("Capabilities: ~p~n", [Capabilities]),
    assert_extended_messaging_support(Capabilities),
    etorrent_peer_control:register_server(TorrentId, Socket),
    {ok, #mpeer_state{socket=Socket, torrent_id=TorrentId, ip=IP}}.

handle_call(x, _From, State) ->
    {reply, ok, State}.


handle_cast({incoming_msg,_}, State=#mpeer_state{control=undefined}) ->
    {stop, race_condition, State};
handle_cast({incoming_msg,{extended,0,HeaderMsgBin}}, State=
           #mpeer_state{registered=false, control=CtlPid, ip=IP}) ->
    {ok, HeaderMsg} = etorrent_bcoding:decode(HeaderMsgBin),
    lager:debug("Extension header: ~p", [HeaderMsg]),
    MetadataExtId = metadata_ext_id(HeaderMsg),
    assert_metadata_extension_support(MetadataExtId),
    MetadataSize = metadata_size(HeaderMsg),
    assert_valid_metadata_size(MetadataSize),
    lager:debug("Send a registration request to ~p.", [CtlPid]),
    CtlPid ! {magnet_peer_ctl, self(),
              {ready, MetadataSize, piece_count(MetadataSize), IP}},
    {noreply, State#mpeer_state{ metadata_size=MetadataSize,
                                 metadata_ext_id=MetadataExtId,
                                 registered=true}};

handle_cast({incoming_msg,{extended,0,HeaderMsgBin}}, State=
           #mpeer_state{registered=true}) ->
    {ok, HeaderMsg} = etorrent_bcoding:decode(HeaderMsgBin),
    lager:debug("Reapply an extension header: ~p~n", [HeaderMsg]),
    MetadataExtId = metadata_ext_id(HeaderMsg),
    assert_metadata_extension_support(MetadataExtId),
    {noreply, State#mpeer_state{ metadata_ext_id=MetadataExtId }};

handle_cast({incoming_msg,{extended, ?UT_METADATA_EXT_ID, MsgBin}}, State=
            #mpeer_state{ metadata_size=MetadataSize, control=CtlPid }) ->
    {RespondMsg, Piece} = etorrent_bcoding2:decode(MsgBin),
    case decode_metadata_respond(RespondMsg) of
        {data, PieceNum, TotalSize} ->
            lager:debug("Metadata piece #~p was downloaded.", [PieceNum]),
            PieceSize = byte_size(Piece),
            assert_total_size(MetadataSize, TotalSize),
            assert_piece_size(PieceSize, PieceNum, MetadataSize),
            CtlPid ! {magnet_peer_ctl, self(), {piece, PieceNum, Piece}},
            {noreply, State}
    end;


handle_cast({piece_request, PieceNum}, State=
            #mpeer_state{send=SendPid, metadata_ext_id=MetadataExtId}) ->
    lager:debug("Request ~p.", [PieceNum]),
    Mess = {extended, MetadataExtId, piece_request_msg(PieceNum)},
    etorrent_peer_send:ext_msg(SendPid, Mess),
    {noreply, State};

handle_cast({initialize,outgoing}, State=
            #mpeer_state{socket=Socket, torrent_id=TorrentId}) ->
    CtlPid = etorrent_torrent_ctl:await_server(TorrentId),
    SendPid = etorrent_peer_send:await_server(Socket),
    RecvPid = etorrent_peer_recv:await_server(Socket),
    etorrent_peer_send:ext_setup(SendPid, m_block(), []),
    lager:info("Initilize outgoing connection.", []),
%   etorrent_counters:obtain_peer_slot() 
    {noreply, State#mpeer_state{ send=SendPid, recv=RecvPid, control=CtlPid}};
handle_cast({incoming_msg, _Mess}, State=#mpeer_state{}) ->
%   lager:debug("Ignore ~p.", [Mess]),
    {noreply, State}.

handle_info(x, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

assert_extended_messaging_support(Capabilities) ->
    [error(extended_msg_not_supported)
     || not lists:member(extended_messaging, Capabilities)],
    ok.


m_block() ->
    [{<<"ut_metadata">>,?UT_METADATA_EXT_ID}].


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

%% 10MB is the maximum torrent size.
assert_valid_metadata_size(Size)
        when Size > 0, Size < 10 * 1024 * 1024, is_integer(Size) ->
    ok.


%% If the piece is the last piece of the metadata, it may be less than 16kiB.
%% If it is not the last piece of the metadata, it MUST be 16kiB.
assert_piece_size(PieceSize, PieceNum, TotalSize) ->
    case piece_size(PieceNum, TotalSize) of
        PieceSize -> ok;
        ExpectedPieceSize ->
            error({bad_piece_size, [{expected, ExpectedPieceSize},
                                    {generated, PieceSize}]})
    end.

assert_total_size(TotalSize, TotalSize) ->
    ok;
assert_total_size(MetadataSize, TotalSize) ->
    error({bad_total_size, [{expected, MetadataSize}, {passed, TotalSize}]}).

piece_request_msg(PieceNum) ->
    PL = [{<<"msg_type">>, 0}, {<<"piece">>, PieceNum}],
    iolist_to_binary(etorrent_bcoding:encode(PL)).


decode_metadata_respond(RespondMsg) ->
    V = fun(X) -> etorrent_bcoding:get_value(X, RespondMsg) end,
    case V(<<"msg_type">>) of
        1 -> {data, V(<<"piece">>), V(<<"total_size">>)};
        2 -> {reject, V(<<"piece">>)}
    end.

piece_size(PieceNum, TotalSize) ->
    piece_size(PieceNum, ?METADATA_BLOCK_BYTE_SIZE, TotalSize).

piece_size(PieceNum, BlockSize, TotalSize) ->
    Div = TotalSize div BlockSize,
    Mod = TotalSize rem BlockSize,
    %% Decrement, if the last block is full.
    LastPieceNum = case Mod of
            0 -> Div - 1;
            _ -> Div
        end,
    if PieceNum =:= LastPieceNum, Mod =/= 0 -> Mod;
       true                                 -> BlockSize
    end.


piece_count(TotalSize) ->
    piece_count(?METADATA_BLOCK_BYTE_SIZE, TotalSize).

piece_count(BlockSize, TotalSize) ->
    Div = TotalSize div BlockSize,
    Mod = TotalSize rem BlockSize,
    case Mod of
        0 -> Div;
        _ -> Div + 1
    end.



