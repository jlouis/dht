%% @author Uvarov Michael <arcusfelis@gmail.com>
%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc TODO
%% @end
-module(etorrent_azdht_tracker).
-behaviour(gen_server).
-define(dht_net, etorrent_dht_net).
-define(dht_state, etorrent_dht_state).

%% API.
-export([start_link/2,
         announce/1,
         update_tracker/1,
         trigger_announce/0]).

%% gproc registry entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).


-type infohash() :: etorrent_types:infohash().
-type portnum() :: etorrent_types:portnum().
-type torrent_id() :: etorrent_types:torrent_id().

-record(state, {
    infohash  :: binary(),
    encoded_key :: binary(),
    torrent_id :: torrent_id(),
    btport=0  :: portnum(),
    interval=10*60*1000 :: integer(),
    timer_ref :: reference()}).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


%% ------------------------------------------------------------------------
%% Gproc helpers

-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    etorrent_utils:register(server_name(TorrentID)).

-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    etorrent_utils:lookup(server_name(TorrentID)).

-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    etorrent_utils:await(server_name(TorrentID)).

server_name(TorrentID) ->
    {etorrent, TorrentID, azdht_tracker}.

poller_key() ->
    {p, l, {etorrent, azdht, poller}}.


%% Gproc helpers
%% ------------------------------------------------------------------------

-spec start_link(infohash(), binary()) -> {'ok', pid()}.
start_link(InfoHash, TorrentID) when is_binary(InfoHash) ->
    Args = [{infohash, InfoHash}, {torrent_id, TorrentID}],
    gen_server:start_link(?MODULE, Args, []).

-spec announce(pid()) -> 'ok'.
announce(TrackerPid) ->
    gen_server:cast(TrackerPid, announce).

%
% Notify all DHT-pollers that an announce should be performed
% now regardless of when the last poll was performed.
%
trigger_announce() ->
    gproc:send(poller_key(), {timeout, now, announce}),
    ok.

%% @doc Announce the torrent, controlled by the server, immediately.
update_tracker(Pid) when is_pid(Pid) ->
    Pid ! {timeout, now, announce},
    ok.

init(Args) ->
    InfoHash  = proplists:get_value(infohash, Args),
    TorrentID = proplists:get_value(torrent_id, Args),
    BTPortNum = etorrent_config:listen_port(),
    EncodedKey = azdht:encode_key(InfoHash),
    lager:debug("Starting azDHT tracker for ~p (~p).", [TorrentID, InfoHash]),
    true = gproc:reg(poller_key(), TorrentID),
    register_server(TorrentID),
    self() ! {timeout, undefined, announce},
    InitState = #state{
        encoded_key=EncodedKey,
        infohash=InfoHash,
        torrent_id=TorrentID,
        btport=BTPortNum},
    {ok, InitState}.

handle_call(_, _, State) ->
    {reply, not_implemented, State}.

handle_cast(init_timer, State) ->
    #state{interval=Interval} = State,
    TRef = erlang:start_timer(Interval, self(), announce),
    NewState = State#state{timer_ref=TRef},
    {noreply, NewState}.

%
% Send announce messages to the nodes that are the closest to the info-hash
% of this torrent. Always perform an iterative search to find nodes acting
% as trackers for this torrent (this might not be such a good idea though)
% and add the peers that were found to the local list of peers for this torrent.
%
handle_info({timeout, _, announce}, State) ->
    #state{
        infohash=Key,
        encoded_key=EncodedKey,
        torrent_id=TorrentID,
        btport=MyPortBT} = State,
    lager:debug("Handle DHT timeout for ~p.", [TorrentID]),

    Nodes = azdht_net:find_node(EncodedKey),
    [azdht_net:announce(Contact, SpoofId, EncodedKey, MyPortBT)
     || Contact <- Nodes,
        {ok, SpoofId} <- [azdht:request_spoof_id(Contact)]],
    Peers = azdht_net:get_peers(Key, Nodes), 

    % Schedule a timer reset later
    _ = gen_server:cast(self(), init_timer),

    lager:debug("Adding peers ~p.", [Peers]),
    ok = etorrent_peer_mgr:add_peers(TorrentID, Peers),
    lager:info("Added ~B peers from azDHT for ~p.", [length(Peers), TorrentID]),
    NewState = State#state{},
    {noreply, NewState}.


terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.
