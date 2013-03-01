%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Accept new connections from the network.
%% <p>This function will accept a new connection from the network and
%% then perform the initial part of the handshake. If successful, the
%% process will spawn a real controller process and hand off the
%% socket to that process.</p>
%% @end
-module(etorrent_acceptor).

-behaviour(gen_server).


%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { listen_socket = none :: none | port(),
                 our_peer_id          :: binary() }).

%% @doc Starts the server.
%% @end
%% @todo Type of listen socket!
-spec start_link(pid(), term()) -> {ok, pid()} | ignore | {error, term()}.
start_link(OurPeerId, LSock) ->
    gen_server:start_link(?MODULE, [OurPeerId, LSock], []).

%%====================================================================

%% @private
init([PeerId, LSock]) when is_binary(PeerId) ->
    {ok, #state{ listen_socket = LSock,
                 our_peer_id = PeerId }, 0}.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(timeout, #state { our_peer_id = PeerId } = S) ->
    case gen_tcp:accept(S#state.listen_socket) of
        {ok, Socket} ->
            {ok, _Pid} = etorrent_listen_sup:start_child(),
            handshake(Socket, PeerId);
        {error, closed}       -> ok;
        {error, econnaborted} -> ok;
        {error, enotconn}     -> ok;
        {error, E}            ->
            lager:info("TCP accept error: ~p", [E]),
            ok
    end,
    {stop, normal, S}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
handshake(Socket, LocalPeerId) ->
    %% This try..catch block is essentially a maybe monad. Each call
    %% checks for some condition to be true and throws an exception
    %% if the check fails. Finally, control is handed over to the control
    %% pid or we handle an error by closing down.
    try
        {ok, {IP, Port}} = inet:peername(Socket),
        {ok, Caps, InfoHash, RemotePeerId} = receive_handshake(Socket),
        ok = check_infohash(InfoHash),
        ok = check_peer(IP, Port, InfoHash, LocalPeerId, RemotePeerId),
        ok = check_peer_count(),
        {ok, RecvPid, ControlPid} =
            check_torrent_state(Socket, Caps, IP, Port, InfoHash, LocalPeerId,
                                RemotePeerId),
        ok = handover_control(Socket, RecvPid, ControlPid)
    catch
        error:{badmatch, {error, enotconn}} ->
            ok;
        throw:{error, Reason} ->
            lager:debug("Handshake failed with reason ~p.", [Reason]),
            gen_tcp:close(Socket),
            ok;
        throw:{bad_peer, PeerPid} ->
            lager:info("Bad Peer: ~p", [PeerPid]),
            gen_tcp:close(Socket),
            ok
    end.

receive_handshake(Socket) ->
    case etorrent_proto_wire:receive_handshake(Socket) of
        {ok, Caps, InfoHash, RemotePeerId} ->
            {ok, Caps, InfoHash, RemotePeerId};
        {error, Reason} ->
            throw({error, Reason})
    end.

check_infohash(InfoHash) ->
    case etorrent_table:get_torrent({infohash, InfoHash}) of
        {value, _} ->
            ok;
        not_found ->
            throw({error, infohash_not_found})
    end.

handover_control(Socket, RPid, CPid) ->
    case gen_tcp:controlling_process(Socket, RPid) of
        ok -> etorrent_peer_control:initialize(CPid, incoming),
              ok;
        {error, enotconn} ->
            etorrent_peer_control:stop(CPid),
            throw({error, enotconn})
    end.

check_peer(_IP, _Port, _InfoHash, PeerId, PeerId) ->
    throw({error, connect_to_ourselves});
check_peer(IP, Port, InfoHash, _LocalPeerId, RemotePeerId) ->
    {value, PL} = etorrent_table:get_torrent({infohash, InfoHash}),
    case etorrent_peer_mgr:is_bad_peer(IP, Port) of
        true ->
            throw({bad_peer, RemotePeerId});
        false ->
            ok
    end,
    case etorrent_table:connected_peer(IP, Port, proplists:get_value(id, PL)) of
        true -> throw({error, already_connected});
        false -> ok
    end.

%% `LocalPeerId' is the default peer id for this node.
check_torrent_state(Socket, Caps, IP, Port, InfoHash, LocalPeerId, RemotePeerId) ->
    {value, PL} = etorrent_table:get_torrent({infohash, InfoHash}),
    TorrentId = proplists:get_value(id, PL),
    {value, PL2} = etorrent_torrent:lookup(TorrentId),
    %% Get the rewritten peer id (if defined).
    LocalPeerId2 = proplists:get_value(peer_id, PL2, LocalPeerId),
    case proplists:get_value(state, PL) of
        started ->
            etorrent_peer_pool:start_child(
              LocalPeerId2, %% will be used to compete the handshake.
              RemotePeerId,
              InfoHash,
              TorrentId,
              {IP, Port},
              Caps,
              Socket);
        _ -> throw({error, not_ready_for_connections})
    end.

check_peer_count() ->
    case etorrent_counters:slots_left() of
        {value, 0} -> throw({error, already_enough_connections});
        {value, K} when is_integer(K) -> ok
    end.
