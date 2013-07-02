-module(etorrent_magnet_ctl).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/5]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(mctl_state, {
        torrent_id :: non_neg_integer(),
        info_hash :: binary(),
        var=etorrent_metadata_variant:new() :: term(),
        options,
        trackers :: [[string()]]
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options)
    when is_integer(TorrentID), is_binary(TorrentIH) ->
    gen_server:start_link(?MODULE, [self(), TorrentIH, LocalPeerID, TorrentID, UrlTiers, Options], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Parent, <<IntIH:160>> = BinIH, LocalPeerID,
      TorrentID, UrlTiers, Options]) ->
    lager:info("Init magnet downloader ~p.", [TorrentID]),
    etorrent_torrent_ctl:register_server(TorrentID),
    etorrent_table:new_torrent("", BinIH, Parent, TorrentID),
    ok = etorrent_torrent:insert(
           TorrentID,
           [{peer_id, LocalPeerID}, %% TODO: Add this property, only if local peer id =/= peer id for this torrent
            {display_name, integer_hash_to_literal(IntIH)},
            {uploaded, 0},
            {downloaded, 0},
            {all_time_uploaded, 0},
            {all_time_downloaded, 0},
            {left, 0},
            {total, 0},
            {is_private, false},
            {pieces, 0},
            {missing, 0},
            {state, fetching}]),
    {ok, #mctl_state{torrent_id=TorrentID, info_hash=BinIH,
                     trackers=UrlTiers, options=Options}}.

handle_call(request, _From, State) ->
    {reply, ok, State}.

handle_cast(msg, State) ->
    {noreply, State}.

handle_info({magnet_peer_ctl, PeerPid, {ready, MetadataSize, PieceCount, IP}},
            State=#mctl_state{var=Var}) ->
%   monitor(process, PeerPid),
    lager:debug("Register PeerPid=~p, MetadataSize=~p, PieceCount=~p.",
                [PeerPid, MetadataSize, PieceCount]),
    Var2 = etorrent_metadata_variant:add_peer(PeerPid, PieceCount, Var),
    PieceNum = etorrent_metadata_variant:request_piece(PeerPid, Var2),
    etorrent_magnet_peer_ctl:request_piece(PeerPid, PieceNum),
    {noreply, State#mctl_state{var=Var2}};
handle_info({magnet_peer_ctl, PeerPid, {piece, PieceNum, Piece}},
            State=#mctl_state{var=Var, info_hash=RequiredIH,
                              trackers=UrlTiers, options=Options,
                              torrent_id=TorrentID}) ->
    lager:debug("Piece #~p was received.", [PieceNum]),
    {PeerProgress, GlobalProgress, Var2} =
        etorrent_metadata_variant:save_piece(PeerPid, PieceNum, Piece, Var),
    lager:debug("Progress of ~p is ~p/~p.",
                [PeerPid, PeerProgress, GlobalProgress]),
    {TryCheck, Fail2Ban, RequestMore} =
    case {GlobalProgress, PeerProgress} of
        {downloaded, downloaded}   -> {true, true, false};
        {downloaded, in_progress}  -> {true, false, true};
        {in_progress, in_progress} -> {false, false, true}
    end,
    if TryCheck ->
        Data = iolist_to_binary(etorrent_metadata_variant:
                                extract_data(PeerPid, Var2)),
        case etorrent_utils:sha(Data) of
            RequiredIH ->
                lager:info("Metadata downloaded.", []),
                handle_completion(RequiredIH, TorrentID, Data, UrlTiers,
                                  Options),
                %% exit here
                ok;
            InvalidHash ->
                lager:info("Invalid hash ~p, expected ~p.",
                           [InvalidHash, RequiredIH])
                %% TODO: handle Fail2Ban here.
        end;
        true -> skip_check
    end,
    if RequestMore ->
        NextPieceNum = etorrent_metadata_variant:request_piece(PeerPid, Var2),
        etorrent_magnet_peer_ctl:request_piece(PeerPid, NextPieceNum);
        true -> no_more_requests
    end,
    {noreply, State#mctl_state{var=Var2}};
handle_info(Msg, State) ->
    lager:warning("Unexpected message ~p.", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


integer_hash_to_literal(InfoHashInt) when is_integer(InfoHashInt) ->
    iolist_to_binary(io_lib:format("~40.16.0B", [InfoHashInt])).

handle_completion(RequiredIH, TorrentID, Data, UrlTiers, Options) ->
    proc_lib:spawn(fun() ->
        lager:info("Terminate metadata-downloader ~p.", [RequiredIH]),
        etorrent_ctl:stop_and_wait(TorrentID),
        etorrent_magnet:handle_completion(RequiredIH, TorrentID, Data,
                                          UrlTiers, Options)
        end).

