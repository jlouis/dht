%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Manage and control peer communication.
%% <p>This gen_server handles the communication with a single peer. It
%% handles incoming connections, and transmits the right messages back
%% to the peer, according to the specification of the BitTorrent
%% procotol.</p>
%% <p>Each peer runs one gen_server of this kind. It handles the
%% queueing of pieces, requestal of new chunks to download, choking
%% states, the remotes request queue, etc.</p>
%% @end
-module(etorrent_peer_control).

-behaviour(gen_server).

-include("etorrent_rate.hrl").

%% API
-export([start_link/8,
        choke/1,
        unchoke/1,
        initialize/2,
        incoming_msg/2,
        check_choke/1,
        update_queue/1,
        stop/1]).

%% gproc registry entries
-export([register_server/2,
         lookup_server/1,
         await_server/1,
         lookup_peers/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         format_status/2]).

%% interspection helpers
-export([has_incoming_requests/1]).

-type torrentid() :: etorrent_types:torrent_id().
-type pieceindex() :: etorrent_types:piece_index().
-type ipaddr() :: etorrent_types:ipaddr().
-type pieceset() :: etorrent_pieceset:t().
-type peerstate() :: etorrent_peerstate:peerstate().
-type peerconf() :: etorrent_peerconf:peerconf().
-type tservices() :: etorrent_download:tservices().
-record(state, {
    torrent_id = exit(required) :: integer(),
    info_hash = exit(required) ::  binary(),
    metadata_size :: non_neg_integer(),
    socket = none  :: none | inet:socket(),
    send_pid :: pid(),

    download = exit(required) :: tservices(),
    rate :: etorrent_rate:rate(),

    remote = exit(required) :: peerstate(),
    local  = exit(required) :: peerstate(),
    config = exit(required) :: peerconf(),

    extensions :: term(),
    reject_after_choke_tref :: term(),
    %% Does remote peer support DHT?
    remote_dht :: boolean(),
    remote_ip :: ipaddr()
    }).

%% Default size for a chunk. All clients use this.
-define(DEFAULT_CHUNK_SIZE, 16384).
%% How many chunks to queue up to
-define(HIGH_WATERMARK, 30).
%% Requeue when there are less than this number of pieces in queue
-define(LOW_WATERMARK, 5).
%% Reject all incoming requests after this timeout (in ms) passed.
-define(REJECT_AFTER_CHOKE_TIMEOUT, 30000).

%%====================================================================

%% @doc Register the current process as a peer process
register_server(TorrentID, Socket) ->
    etorrent_utils:register(server_name(Socket)),
    etorrent_utils:register_member(group_name(TorrentID)).

%% @doc Lookup the process id of a specific peer.
lookup_server(Socket) ->
    etorrent_utils:lookup(server_name(Socket)).

%% @doc
await_server(Socket) ->
    etorrent_utils:await(server_name(Socket)).

%% @doc
-spec lookup_peers(torrentid()) -> [pid()].
lookup_peers(TorrentID) ->
    etorrent_utils:lookup_members(group_name(TorrentID)).


%% @doc Name of a specific peer process
server_name(Socket) ->
    {etorrent, Socket, peer}.

%& @doc Name of all peers in a torrent
group_name(TorrentID) ->
    {etorrent, TorrentID, peers}.




%% @doc Starts the server
%% @end
start_link(TrackerUrl, LocalPeerID, RemotePeerID,
           InfoHash, Id, {IP, Port}, Caps, Socket)
  when is_binary(LocalPeerID), is_binary(RemotePeerID) ->
    gen_server:start_link(?MODULE, [TrackerUrl, LocalPeerID, RemotePeerID,
                                    InfoHash, Id, {IP, Port}, Caps, Socket], []).

%% @doc Gracefully ask the server to stop.
%% @end
stop(Pid) ->
    gen_server:cast(Pid, stop).

%% @doc Choke the peer.
%% <p>The intended caller of this function is the {@link etorrent_choker}</p>
%% @end
choke(Pid) ->
    gen_server:cast(Pid, choke).

%% @doc Unchoke the peer.
%% <p>The intended caller of this function is the {@link etorrent_choker}</p>
%% @end
unchoke(Pid) ->
    gen_server:cast(Pid, unchoke).

%% @doc Rerun `poll_local_rqueue'.
%% <p>The intended caller of this function is the {@link etorrent_pending}</p>
%% @end
update_queue(Pid) ->
    gen_server:cast(Pid, update_queue).


%% @doc Initialize the connection.
%% <p>The `Way' parameter tells the client of the connection is
%% `incoming' or `outgoing'. They are handled differently since part
%% of the handshake is already completed for incoming connections.</p>
%% @end
-type direction() :: incoming | outgoing.
-spec initialize(pid(), direction()) -> ok.
initialize(Pid, Way) ->
    gen_server:cast(Pid, {initialize, Way}).


%% @doc Inject an incoming message to the process.
%% <p>This is the main "Handle-incoming-messages" call. The intended
%% caller is {@link etorrent_peer_recv}, whenever a message arrives on
%% the socket.</p>
%% @end
incoming_msg(Pid, Msg) ->
    gen_server:cast(Pid, {incoming_msg, Msg}).

%% @doc Trigger a check of the current choke status.
%% <p>
%% Rechecking the current choke status ensures that an upload-slot is
%% immediately allocated to a peer that has shown interest, if there is
%% an available upload-slot.
%% </p>
%% <p>
%% The current choke status is also rechecked when a peer has shown a lack
%% of interest. This ensures that the upload-slot it has allocated, if it
%% is unchoked at the time, is freed and reallocated to another peer.
%% </p>
%% @end
-spec check_choke(pid()) -> ok.
check_choke(Pid) ->
    gen_server:cast(Pid, check_choke).


has_incoming_requests(Pid) ->
    gen_server:call(Pid, has_incoming_requests).

%% ==================================================================

%% @private
init([TrackerUrl, LocalPeerID, RemotePeerID,
      InfoHash, TorrentID, {IP, Port}, Caps, Socket]) ->
    lager:info("New peer ~p:~p is known as ~p for #~p. Caps: ~p.",
               [IP, Port, RemotePeerID, TorrentID, Caps]),

    random:seed(os:timestamp()),
    %% Use socket handle as remote peer-id.
    register_server(TorrentID, Socket),
    Download = etorrent_download:await_servers(TorrentID),

    %% Keep track of the local state and the remote state
    TorrentPid  = etorrent_torrent_ctl:await_server(TorrentID),
    {ok, Valid} = etorrent_torrent_ctl:valid_pieces(TorrentPid),
    Numpieces   = etorrent_pieceset:capacity(Valid),
    Local0 = etorrent_peerstate:new(Numpieces, 3, 16),
    Local  = etorrent_peerstate:pieces(Valid, Local0),
    Remote = etorrent_peerstate:new(Numpieces, 2, 250),

    Extended = proplists:get_bool(extended_messaging, Caps),
    Fast     = proplists:get_bool(fast_extension, Caps),
    %% Does remote peer support DHT?
    DHT      = proplists:get_bool(dht_support, Caps),
    [lager:info("Remote peer supports DHT.") || DHT],
    Config0  = etorrent_peerconf:new(),
    Config1  = etorrent_peerconf:localid(LocalPeerID, Config0),
    Config2  = etorrent_peerconf:remoteid(RemotePeerID, Config1),
    Config3  = etorrent_peerconf:extended(Extended, Config2),
    Config   = etorrent_peerconf:fast(Fast, Config3),
    IsPrivate = etorrent_info:is_private(TorrentID),
    Exts     = etorrent_ext:new([ut_metadata], [private || IsPrivate]),

    MetadataSize = etorrent_info:metadata_size(TorrentID),

    ok = etorrent_table:new_peer(TrackerUrl, IP, Port, TorrentID, self(),
                                 leeching, Fast, RemotePeerID),
    ok = etorrent_choker:monitor(self()),
    State = #state{
        torrent_id=TorrentID,
        info_hash=InfoHash,
        metadata_size=MetadataSize,
        socket=Socket,
        download=Download,
        remote=Remote,
        local=Local,
        config=Config,
        extensions=Exts,
        remote_dht=DHT,
        remote_ip=IP},
    {ok, State}.

%% @private
handle_cast({initialize, Way}, S) ->
    case etorrent_counters:obtain_peer_slot() of
        ok ->
            case connection_initialize(Way, S) of
                {ok, NS} -> {noreply, NS};
                {stop, Type} -> {stop, Type, S}
            end;
        full ->
            {stop, normal, S}
    end;

handle_cast({incoming_msg, Msg}, S) ->
    case handle_message(Msg, S) of
        {ok, NS} -> {noreply, NS};
        {stop, Reason, NS} -> {stop, Reason, NS}
    end;

%% Block the remote node (send from etorrent_choker).
handle_cast(choke, State) ->
    #state{
        torrent_id=TorrentID, send_pid=SendPid,
        remote=Remote, config=Config} = State,
    case etorrent_peerstate:choked(Remote) of
        false ->
            Reqs = etorrent_peerstate:requests(Remote),
            {Remote1, RejectTRef} =
            case {etorrent_peerconf:fast(Config),
                  etorrent_rqueue:is_empty(Reqs)} of
                {true, false} ->
                    %% Will reject incoming requests after the timeout.
                    {ok, TRef} = timer:send_after(?REJECT_AFTER_CHOKE_TIMEOUT,
                                                   reject_after_choke_timeout),
                    lager:debug("Create a reject timeout ~p.", [TRef]),
                    {Remote, TRef};
                {false, false} ->
                    %% Throw away all incoming requests.
                    NewReqs = etorrent_rqueue:flush(Reqs),
                    TmpRemote = etorrent_peerstate:requests(NewReqs, Remote),
                    {TmpRemote, undefined};
                {_, _} ->
                    {Remote, undefined}
            end,
            etorrent_peer_states:set_local_choke(TorrentID, self()),
            etorrent_peer_send:choke(SendPid),
            Remote2 = etorrent_peerstate:choked(true, Remote1),
            NewState = State#state{remote=Remote2,
                                   reject_after_choke_tref=RejectTRef},
            {noreply, NewState};
        true ->
            {noreply, State}
    end;

handle_cast(unchoke, State) ->
    #state{torrent_id=TorrentID, send_pid=SendPid, remote=Remote,
           reject_after_choke_tref=RejectTRef} = State,
    [timer:cancel(RejectTRef) || RejectTRef =/= undefined],
    case etorrent_peerstate:choked(Remote) of
        false ->
            %% @todo handle duplicate unchoke?
            {noreply, State};
        true ->
            etorrent_peer_states:set_local_unchoke(TorrentID, self()),
            etorrent_peer_send:unchoke(SendPid),
            NewRemote = etorrent_peerstate:choked(false, Remote),
            NewState = State#state{remote=NewRemote,
                                   reject_after_choke_tref=undefined},
            {noreply, NewState}
    end;

handle_cast(check_choke, State) ->
    #state{remote=Remote} = State,
    Choked = etorrent_peerstate:choked(Remote),
    Interested = etorrent_peerstate:interested(Remote),
    case {Choked, Interested} of
        {false, false} ->
            etorrent_choker:perform_rechoke();
        {true, true} ->
            etorrent_choker:perform_rechoke();
        {_Choked, _Interested} ->
            ok
    end,
    {noreply, State};

%% The chunk manager wants new chunks.
handle_cast(update_queue, State) ->
    #state{download=Download, send_pid=SendPid, local=Local, remote=Remote} = State,
    NewLocal = poll_local_rqueue(Download, SendPid, Remote, Local),
    NewState = State#state{local=NewLocal},
    {noreply, NewState};

handle_cast(interested, State) ->
    self() ! {interested, true},
    {noreply, State};

%% TODO: this cause death of `etorrent_peer_sup' with reason 
%%       `reached_max_restart_intensity'.
handle_cast(stop, S) ->
    {stop, normal, S}.


%% @private
handle_info(reject_after_choke_timeout, State) ->
    lager:debug("Handle request reject timeout.", []),
    #state{remote=Remote, send_pid=SendPid} = State,
    Reqs = etorrent_peerstate:requests(Remote), 
    [etorrent_peer_send:reject(SendPid, Index, Offset, Length)
    || {Index, Offset, Length} <- etorrent_rqueue:to_list(Reqs)],
    NewReqs = etorrent_rqueue:flush(Reqs),
    Remote1 = etorrent_peerstate:requests(NewReqs, Remote),
    NewState = State#state{remote=Remote1, reject_after_choke_tref=undefined},
    {noreply, NewState};

handle_info({chunk, {fetched, Index, Offset, Length, _}}, State) ->
    #state{send_pid=SendPid, local=Local} = State,
    Requests = etorrent_peerstate:requests(Local),
    Hasrequest = etorrent_rqueue:member(Index, Offset, Length, Requests),
    NewLocal = if
        not Hasrequest ->
            Local;
        Hasrequest ->
            etorrent_peer_send:cancel(SendPid, Index, Offset, Length),
            NewReqs = etorrent_rqueue:delete(Index, Offset, Length, Requests),
            etorrent_peerstate:requests(NewReqs, Local)
    end,
    NewState = State#state{local=NewLocal},
    {noreply, NewState};

handle_info({chunk, {contents, Index, Offset, Length, Data}}, State) ->
    #state{torrent_id=TorrentID, send_pid=SendPid, remote=Remote,
           config=Config} = State,
    Requests = etorrent_peerstate:requests(Remote),
    Choked = etorrent_peerstate:choked(Remote),
    Fast = etorrent_peerconf:fast(Config),
    case etorrent_rqueue:peek(Requests) of
        %% When the remote peer enters the choked state with a non-empty
        %% request queue we are expecting to receive the result of the last
        %% asynchronous chunk read in the choked state.
        false when Choked ->
            {noreply, State};
        %% The same applies to a peer that has entered the choked state and
        %% quickly re-entered the unchoked state. Use separate clause for now.
        false when not Choked ->
            {noreply, State};
        %% We must only reply with a PIECE message if the request at the head
        %% of the remote request queue matches and the peer is unchoked.
        {Index, Offset, Length} when not Choked ->
            NewRequests = etorrent_rqueue:pop(Requests),
            NewRemote = etorrent_peerstate:requests(NewRequests, Remote),
            NewState = State#state{remote=NewRemote},
            ok = etorrent_peer_send:piece(SendPid, Index, Offset, Length, Data),
            % Is this call already in peer_send? It causes double-rating!
            % ok = etorrent_torrent:statechange(TorrentID, [{add_upload, Length}]),
            ok = pop_remote_rqueue_hook(TorrentID, NewRequests),
            {noreply, NewState};
        %% Same as clause #2. Peer returned to unchoked state. Non empty queue
        %% while choked is considered invalid. It should have been flushed.
        {_Index, _Offset, _Length} when not Choked ->
            {noreply, State};
        %% We still waiting a timeout to reject incoming requests.
        {_Index, _Offset, _Length} when Choked, Fast ->
            {noreply, State}
    end;

handle_info({piece, {valid, Piece}}, State) ->
    #state{send_pid=SendPid, download=Download, local=Local, remote=Remote} = State,
    WithLocal = etorrent_peerstate:hasone(Piece, Local),
    ok        = etorrent_peer_send:have(SendPid, Piece),
    TmpLocal  = recheck_local_interest(Piece, Remote, WithLocal, SendPid),
    NewLocal  = poll_local_rqueue(Download, SendPid, Remote, TmpLocal),
    NewState  = State#state{local=NewLocal},
    {noreply, NewState};

handle_info({piece, {unassigned, _}}, State) ->
    #state{download=Download, send_pid=SendPid, local=Local, remote=Remote} = State,
    NewLocal = poll_local_rqueue(Download, SendPid, Remote, Local),
    NewState = State#state{local=NewLocal},
    {noreply, NewState};

%% etorrent_peerstate:interested(self()),
handle_info({peer, {check, seeder}}, State) ->
    {noreply, State};


%% Handle a message from `etorrent_download:update/2'.
handle_info({download, Update}, State) ->
    #state{download=Download} = State,
    NewDownload = etorrent_download:update(Update, Download),
    NewState = State#state{download=NewDownload},
    {noreply, NewState};
            
handle_info({tcp, _, _}, State) ->
    lager:error("Detected wrong controller for TCP socket"),
    {noreply, State}.

%% @private
terminate(_Reason, _S) ->
    ok.

%% @private
handle_call(has_incoming_requests, _From, State=#state{remote=Remote}) ->
    Requests = etorrent_peerstate:requests(Remote),
    IsEmpty = etorrent_rqueue:is_empty(Requests),
    {reply, not IsEmpty, State}.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ==================================================================

format_status(_Opt, [_Pdict, S]) ->
    #state{config=Config} = S,
    RemoteID = etorrent_peerconf:remoteid(Config),
    IPPort = case inet:peername(S#state.socket) of
        {ok, IPP} -> IPP;
        {error, Reason} -> {port_error, Reason}
    end,
    Term = [
        {torrent_id,     S#state.torrent_id},
        {remote_peer_id, RemoteID},
        {info_hash,      S#state.info_hash},
        {socket_info,    IPPort}],
    [{data,  [{"State",  Term}]}].
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: handle_message(Msg, State) -> {ok, NewState} | {stop, Reason, NewState}
%% Description: Process an incoming message Msg from the wire. Return either
%%  {ok, S} if the processing was ok, or {stop, Reason, S} in case of an error.
%%--------------------------------------------------------------------
-spec handle_message(_,_) -> {'ok',_} | {'stop', _, _}.
handle_message(keep_alive, S) ->
    {ok, S};
handle_message(choke, State) ->
    #state{
        torrent_id=TorrentID,
        local=Local,
        config=Config,
        download=Download} = State,
    ok = etorrent_peer_states:set_choke(TorrentID, self()),
    NewState = case etorrent_peerconf:fast(Config) of
        true ->
            %% If the Fast Extension is enabled a CHOKE message does
            %% not imply that all outstanding requests are dropped.
            NewLocal = etorrent_peerstate:choked(true, Local),
            State#state{local=NewLocal};
        false ->
            %% A CHOKE message implies that all outstanding requests has been dropped.
            Requests = etorrent_peerstate:requests(Local),
            Pieces = etorrent_rqueue:pieces(Requests),
            Chunks = etorrent_rqueue:to_list(Requests),
            Peers  = etorrent_peer_control:lookup_peers(TorrentID),
            ok = etorrent_piecestate:unassigned(Pieces, Peers),
            ok = etorrent_download:chunks_dropped(Chunks, Download),
            NewReqs = etorrent_rqueue:flush(Requests),
            TmpLocal = etorrent_peerstate:choked(true, Local),
            NewLocal = etorrent_peerstate:requests(NewReqs, TmpLocal),
            State#state{local=NewLocal}
    end,
    {ok, NewState};

handle_message(unchoke, State) ->
    #state{torrent_id=TorrentID} = State,
    #state{send_pid=SendPid, download=Download, local=Local, remote=Remote} = State,
    ok = etorrent_peer_states:set_unchoke(TorrentID, self()),
    TmpLocal = etorrent_peerstate:choked(false, Local),
    NewLocal = poll_local_rqueue(Download, SendPid, Remote, TmpLocal),
    NewState = State#state{local=NewLocal},
    {ok, NewState};

handle_message(interested, State) ->
    #state{torrent_id=TorrentID, remote=Remote} = State,
    ok = etorrent_peer_states:set_interested(TorrentID, self()),
    ok = etorrent_peer_control:check_choke(self()),
    NewRemote = etorrent_peerstate:interested(true, Remote),
    NewState = State#state{remote=NewRemote},
    {ok, NewState};

handle_message(not_interested, State) ->
    #state{torrent_id=TorrentID, remote=Remote} = State,
    ok = etorrent_peer_states:set_not_interested(TorrentID, self()),
    ok = etorrent_peer_control:check_choke(self()),
    %% FIXME: badarg
    NewRemote = etorrent_peerstate:interested(false, Remote),
    NewState = State#state{remote=NewRemote},
    {ok, NewState};

%% Handle incoming chunk request from wire.
handle_message({request, Index, Offset, Length}, State) ->
    #state{torrent_id=TorrentID, remote=Remote, config=Config, send_pid=SendPid} = State,
    Requests = etorrent_peerstate:requests(Remote),
    NewRequests = etorrent_rqueue:push(Index, Offset, Length, Requests),
    IsOverlimit = etorrent_rqueue:is_overlimit(NewRequests),
    FastEnabled = etorrent_peerconf:fast(Config),
    case etorrent_peerstate:choked(Remote) of
        %% The remote peer is choked by the local peer. The peer should not
        %% expect a PIECE message as a response while in this state. It was
        %% most likely sent before it received the CHOKE message from us.
        true when FastEnabled ->
            %% In the original bittorrent specification the behaviour
            %% in this situation was undefined. The FAST extension adds
            %% a REJECT message which makes more sense than replying to
            %% or dropping the request on the floor.
            etorrent_peer_send:reject(SendPid, Index, Offset, Length),
            {ok, State};
        true ->
            {ok, State};

        false when IsOverlimit, FastEnabled ->
            %% We can only signal that we are only accepting a limited amount
            %% of pipelined requests if the FAST extension is used.
            etorrent_peer_send:reject(SendPid, Index, Offset, Length),
            {ok, State};

        false when IsOverlimit ->
            {stop, max_queue_len_exceeded, State};

        false ->
            %% The remote peer is unchoked by the local peer. The peer expects a
            %% PIECE message as a response to this message. If the local peer
            %% chokes the remote peer before a response is sent the same rules
            %% apply to this request as a requests received after the choke.
            ok = push_remote_rqueue_hook(TorrentID, NewRequests),
            NewRemote = etorrent_peerstate:requests(NewRequests, Remote),
            NewState = State#state{remote=NewRemote},
            {ok, NewState}
    end;

handle_message({cancel, Index, Offset, Length}, State) ->
    %% If the FAST extension is enabled the peer expects a REJECT response
    %% to a CANCEL request. We assume that the CANCEL request refers to a
    %% previously sent chunk REQUEST. If the REQUEST is not a member of the
    %% remote request queue we can assume that we have sent a PIECE response.
    %% If the REQUEST is a member of the remote request queue we remove it
    %% and respond with a REJECT message. Either case is valid.
    #state{send_pid=SendPid, remote=Remote, config=Config} = State,
    Reqs = etorrent_peerstate:requests(Remote),
    case etorrent_rqueue:member(Index, Offset, Length, Reqs) of
        true ->
            case etorrent_peerconf:fast(Config) of
                false -> ok;
                true  -> etorrent_peer_send:reject(SendPid, Index, Offset, Length)
            end,
            NewReqs = etorrent_rqueue:delete(Index, Offset, Length, Reqs),
            NewRemote = etorrent_peerstate:requests(NewReqs, Remote),
            NewState = State#state{remote=NewRemote},
            {ok, NewState};
        false ->
            {ok, State}
    end;

handle_message({reject_request, Index, Offset, Length}, State) ->
    %% Reject Request notifies a requesting peer that its request will 
    %% not be satisfied.
    #state{download=Download, remote=Remote, config=Config} = State,
    %% If the fast extension is disabled and a peer receives a reject 
    %% request then the peer MUST close the connection.
    etorrent_peerconf:fast(Config) orelse erlang:error(badarg),
    Reqs = etorrent_peerstate:requests(Remote),
    case etorrent_rqueue:member(Index, Offset, Length, Reqs) of
        true ->
            NewReqs = etorrent_rqueue:delete(Index, Offset, Length, Reqs),
            Chunks = [{Index, Offset, Length}],
            ok = etorrent_download:chunks_dropped(Chunks, Download),
            NewRemote = etorrent_peerstate:requests(NewReqs, Remote),
            NewState = State#state{remote=NewRemote},
            {ok, NewState};
        false ->
            %% If a peer receives a reject for a request that was never sent
            %% then the peer SHOULD close the connection.
            {ok, State}
    end;

handle_message({suggest, Piece}, State) ->
    #state{config=Config} = State,
    PeerID = etorrent_peerconf:remoteid(Config),
    lager:info(
      "Peer ~p suggested piece ~B, but no support is currently available",
      [PeerID, Piece]),
    {ok, State};

handle_message({have, Piece}, State) ->
    #state{torrent_id=TorrentID, send_pid=SendPid,
           download=Download, remote=Remote, local=Local} = State,
    TmpRemote = etorrent_peerstate:hasone(Piece, Remote),
    Pieceset  = etorrent_peerstate:pieces(TmpRemote),
    %% TODO - see etorrent_peerstate:haspieces/1
    HasPieces = etorrent_peerstate:haspieces(Remote),
    HasPieces orelse etorrent_scarcity:add_peer(TorrentID, Pieceset),
    ok        = etorrent_scarcity:add_piece(TorrentID, Piece, Pieceset),
    TmpLocal  = check_local_interest(Piece, Local, SendPid),
    NewRemote = check_remote_seeder(TmpRemote, TmpLocal),
    NewLocal  = poll_local_rqueue(Download, SendPid, NewRemote, TmpLocal),
    Changed   = etorrent_peerstate:seeder(Remote) =/=
                etorrent_peerstate:seeder(NewRemote),
    Changed andalso etorrent_table:statechange_peer(self(), seeder),
    NewState  = State#state{remote=NewRemote, local=NewLocal},
    {ok, NewState};

handle_message(have_none, State) ->
    #state{torrent_id=TorrentID, remote=Remote, config=Config} = State,
    etorrent_peerconf:fast(Config) orelse erlang:error(badarg),
    NewRemote = etorrent_peerstate:hasnone(Remote),
    Pieceset  = etorrent_peerstate:pieces(NewRemote),
    ok        = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    NewState  = State#state{remote=NewRemote},
    {ok, NewState};

handle_message(have_all, State) ->
    #state{torrent_id=TorrentID, send_pid=SendPid, download=Download, remote=Remote, local=Local, config=Config} = State,
    etorrent_peerconf:fast(Config) orelse erlang:error(badarg),
    TmpRemote = etorrent_peerstate:hasall(Remote),
    Pieceset  = etorrent_peerstate:pieces(TmpRemote),
    ok        = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    TmpLocal  = check_local_interest(Pieceset, Local, SendPid),
    NewRemote = check_remote_seeder(TmpRemote, TmpLocal),
    NewLocal  = poll_local_rqueue(Download, SendPid, NewRemote, TmpLocal),
    NewState  = State#state{remote=NewRemote, local=NewLocal},
    {ok, NewState};

handle_message({bitfield, Bitfield}, State) ->
    #state{torrent_id=TorrentID, send_pid=SendPid, download=Download, local=Local, remote=Remote} = State,
    TmpRemote = etorrent_peerstate:hasset(Bitfield, Remote),
    Pieceset  = etorrent_peerstate:pieces(TmpRemote),
    ok        = etorrent_scarcity:add_peer(TorrentID, Pieceset),
    TmpLocal  = check_local_interest(Pieceset, Local, SendPid),
    NewRemote = check_remote_seeder(TmpRemote, TmpLocal),
    NewLocal  = poll_local_rqueue(Download, SendPid, NewRemote, TmpLocal),
    NewState  = State#state{remote=NewRemote, local=NewLocal},
    {ok, NewState};

handle_message({piece, Index, Offset, Data}, State) ->
    #state{torrent_id=TorrentID} = State,
    #state{send_pid=SendPid, download=Download, local=Local, remote=Remote} = State,
    Length = byte_size(Data),
    Requests = etorrent_peerstate:requests(Local),
    NewLocal = case etorrent_rqueue:is_head(Index, Offset, Length, Requests) of
        true ->
            ok = etorrent_download:chunk_fetched(Index, Offset, Length, Download),
            ok = etorrent_io:write_chunk(TorrentID, Index, Offset, Data),
            ok = etorrent_download:chunk_stored(Index, Offset, Length, Download),
            NewRequests = etorrent_rqueue:pop(Requests),
            TmpLocal = etorrent_peerstate:requests(NewRequests, Local),
            poll_local_rqueue(Download, SendPid, Remote, TmpLocal);
        false ->
            %% Stray piece, we could try to get hold of it but for now we just
            %% throw it on the floor. TODO - crash if the fast extension is enabled?
            Local
    end,
    NewState = State#state{local=NewLocal},
    {ok, NewState};

%% Extended messaging handshake
handle_message({extended, 0, Data}, State) ->
    #state{config=Config, extensions=Exts} = State,
    lager:debug("Getting a supported extension list from the peer.", []),
    etorrent_peerconf:extended(Config) orelse erlang:error(badarg),
    {ok, Msg} = etorrent_bcoding:decode(Data),
    lager:debug("Extended handshake dict: ~p", [Msg]),
    ClientVersion = proplists:get_value(<<"v">>, Msg),
    [etorrent_table:statechange_peer(self(), {version, ClientVersion})
     || is_binary(ClientVersion)],
    Exts2 = etorrent_ext:handle_handshake_respond(Msg, Exts),
    {ok, State#state{extensions=Exts2}};

handle_message({extended, ExtId, Data}, State) ->
    #state{extensions=Exts} = State,
    {ok, Msg} = etorrent_ext:decode_msg(ExtId, Data, Exts),
    handle_ext_message(Msg, State);

handle_message({port, PortNum}, State=#state{remote_dht=true,
                                             remote_ip=RemoteIP}) ->
    lager:info("Remote DHT-port is ~p.", [PortNum]),
    LocalDHT = etorrent_config:dht(),
    [etorrent_dht_state:safe_insert_node(RemoteIP, PortNum) || LocalDHT],
    {ok, State};

handle_message(Unknown, State) ->
    lager:error("Unknown handle_message: ~p", [Unknown]),
    {stop, normal, State}.


handle_ext_message({metadata_request, PieceNum}, State) ->
    #state{torrent_id=TorrentID, extensions=Exts, send_pid=SendPid,
           metadata_size=MetadataSize} = State,
    %% Get data.
    PieceData = etorrent_info:get_piece(TorrentID, PieceNum),
    %% Form an answer.
    Answer = {metadata_data, PieceNum, MetadataSize, PieceData},
    {ok, Encoded} = etorrent_ext:encode_msg(ut_metadata, Answer, Exts),
    %% Send the answer.
    etorrent_peer_send:ext_msg(SendPid, Encoded),
    {ok, State};
handle_ext_message(_, _State) ->
    error(unknown_extended_message).

% @doc Initialize the connection, depending on the way the connection is
connection_initialize(incoming, State) ->
    #state{
        socket=Socket,
        info_hash=Infohash,
        local=Local,
        config=Config,
        extensions=Exts,
        metadata_size=MetadataSize,
        remote_dht=RemoteDHT} = State,
    Extended = etorrent_peerconf:extended(Config),
    LocalID = etorrent_peerconf:localid(Config),
    Valid = etorrent_peerstate:pieces(Local),
    case etorrent_proto_wire:complete_handshake(Socket, Infohash, LocalID) of
        ok ->
            SendPid = complete_connection_setup(Socket, Extended, Valid,
                                                Exts, MetadataSize, RemoteDHT),
            NewState = State#state{send_pid=SendPid},
            {ok, NewState};
        {error, stop} ->
            {stop, normal}
    end;

connection_initialize(outgoing, State) ->
    #state{
        socket=Socket,
        local=Local,
        config=Config,
        extensions=Exts,
        metadata_size=MetadataSize,
        remote_dht=RemoteDHT} = State,
    Extended = etorrent_peerconf:extended(Config),
    Valid = etorrent_peerstate:pieces(Local),
    SendPid = complete_connection_setup(Socket, Extended, Valid, Exts,
                                        MetadataSize, RemoteDHT),
    NewState = State#state{send_pid=SendPid},
    {ok, NewState}.

%%--------------------------------------------------------------------
%% Description: Do the bookkeeping needed to set up the peer:
%%    * enable passive messaging mode on the socket.
%%    * Start the send pid
%%    * Send off the bitfield
%%--------------------------------------------------------------------
complete_connection_setup(Socket, Extended, Valid, Exts, MetadataSize,
                          RemoteDHT) ->
    SendPid = etorrent_peer_send:await_server(Socket),
    LocalDHT = etorrent_config:dht(),
    [etorrent_peer_send:port(SendPid, etorrent_config:dht_port())
     || RemoteDHT, LocalDHT],
    Bitfield = etorrent_pieceset:to_binary(Valid),
    Extra = add_metadata_size(Exts, MetadataSize),
    Extended andalso etorrent_peer_send:
        ext_setup(SendPid, etorrent_ext:extension_list(Exts), Extra),
    etorrent_peer_send:bitfield(SendPid, Bitfield),
    SendPid.


add_metadata_size(Exts, MetadataSize) ->
    [{<<"metadata_size">>, MetadataSize}
    || etorrent_ext:is_locally_supported(ut_metadata, Exts)].

        
%% @private Check if the local request queue is low on requests.
%% An updated copy of the local peer state is returned, including any new requests.
-spec poll_local_rqueue(tservices(), pid(), peerstate(), peerstate()) -> peerstate().
poll_local_rqueue(Download, SendPid, Remote, Local) ->
    case etorrent_peerstate:needreqs(Local) of
        false ->
            Local;
        true  ->
            Requests = etorrent_peerstate:requests(Local),
            Pieces = etorrent_peerstate:pieces(Remote),
            Needs = etorrent_rqueue:needs(Requests),
            case etorrent_download:request_chunks(Needs, Pieces, Download) of
                {ok, assigned} ->
                    Local;
                {ok, Chunks} ->
                    [etorrent_peer_send:request(SendPid, Chunk)
                    || Chunk <- Chunks],
                    NewRequests = etorrent_rqueue:push(Chunks, Requests),
                    etorrent_peerstate:requests(NewRequests, Local)
            end
    end.

%% @private Check if a new asynchronous chunk read needs to be started.
%% A new chunk read should be started when a REQUEST message is pushed into an
%% empty request queue. The calling code is expected to only call this function
%% when the local peer is expected to send a PIECE request.
push_remote_rqueue_hook(TorrentID, Requests) ->
    case etorrent_rqueue:size(Requests) of
        1 ->
            {Piece, Offset, Length} = etorrent_rqueue:peek(Requests),
            {ok, _} = etorrent_io:aread_chunk(TorrentID, Piece, Offset, Length),
            ok;
        N when N > 1 ->
            ok
    end.


%% @private Check if a new asynchronous chunk read needs to be started.
%% A new chunk read should be started when a REQUEST message is popped from a non
%% empty request queue. The calling code is expected to call this function with
%% the most recent version of the queue.
pop_remote_rqueue_hook(TorrentID, Requests) ->
    case etorrent_rqueue:size(Requests) of
        0 ->
            ok;
        N when N > 0 ->
            {Piece, Offset, Length} = etorrent_rqueue:peek(Requests),
            {ok, _} = etorrent_io:aread_chunk(TorrentID, Piece, Offset, Length),
            ok
    end.


%% @doc Check if a peer provided an interesting piece.
%% This function should be called when a have-message is received.
%% If the piece is interesting and we are not already interested a
%% status update is sent to the local process to trigger a state
%% change.
%% @end
-spec check_local_interest(pieceindex() | pieceset(),
                           peerstate(), pid()) -> peerstate().
check_local_interest(Pieces, Local, SendPid) ->
    case etorrent_peerstate:interesting(Pieces, Local) of
        Local ->
            Local;
        NewLocal ->
            ok = etorrent_peer_send:interested(SendPid),
            NewLocal
    end.


%% @doc Check if a peer still provides interesting pieces.
%% This function should be called when a have-message is sent. If the
%% peer no longer provides any interesting pieces and we are interested
%% a status update is sent to the local process to trigger a state change.
%% @end
-spec recheck_local_interest(pieceindex(), peerstate(),
                             peerstate(), pid()) -> peerstate().
recheck_local_interest(Piece, Remote, Local, SendPid) ->
    case etorrent_peerstate:interesting(Piece, Remote, Local) of
        Local ->
            Local;
        NewLocal ->
            ok = etorrent_peer_send:not_interested(SendPid),
            NewLocal
    end.


%% @doc Check the remote peer has become a seeder
%% This is only worth checking if we are also seeding the torrent.
%% We are expected to close the connection if both peers are seeders,
%% exit with reason badarg if we find ourselves in this situation,
%% it should have been handled elsewhere.
%% Return an updated copy of the remote state and send a notification
%% to ourselves if the remote peer became a seeder.
%% @end
-spec check_remote_seeder(peerstate(), peerstate()) -> peerstate().
check_remote_seeder(Remote, Local) ->
    case etorrent_peerstate:seeding(Remote, Local) of
        Remote ->
            Remote;
        _ ->
            exit(seeder)
    end.

