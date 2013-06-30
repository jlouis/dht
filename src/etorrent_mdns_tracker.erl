%% @author Uvarov Michael <arcusfelis@gmail.com>
%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc TODO
%% @end
-module(etorrent_mdns_tracker).
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
-define(ST, "_bittorrent._tcp").

-record(state, {
    infohash  :: binary(),
    torrent_id :: torrent_id(),
    btport=0  :: portnum(),
    announce_interval=10*60*1000 :: integer(),
    add_peers_interval=10*1000 :: integer(),
    timer_ref :: reference(),
    timer_ref2 :: reference(),
    instance_name :: string(),
    sub_type :: string()
    }).

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
    {etorrent, TorrentID, mdns_tracker}.

poller_key() ->
    {p, l, {etorrent, mdns, poller}}.


%% Gproc helpers
%% ------------------------------------------------------------------------

-spec start_link(infohash(), binary()) -> {'ok', pid()}.
start_link(InfoHash, TorrentID) when is_binary(InfoHash) ->
    PeerIdBin = etorrent_ctl:local_peer_id(),
    Args = [{infohash, InfoHash}, {torrent_id, TorrentID}, {peer_id, PeerIdBin}],
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
    PeerIdBin = proplists:get_value(peer_id, Args),
    InfoHash  = proplists:get_value(infohash, Args),
    TorrentID = proplists:get_value(torrent_id, Args),
    BTPortNum = etorrent_config:listen_port(),
    lager:debug("Starting mDNS tracker for ~p (~p).", [TorrentID, InfoHash]),
    true = gproc:reg(poller_key(), TorrentID),
    register_server(TorrentID),
    self() ! {timeout, undefined, announce},
    InitState = #state{
        infohash=InfoHash,
        torrent_id=TorrentID,
        btport=BTPortNum,
        instance_name=instance_name(PeerIdBin),
        sub_type=sub_type(InfoHash)},
    {ok, InitState}.

handle_call(_, _, State) ->
    {reply, not_implemented, State}.

handle_cast(init_announce_timer, State) ->
    #state{announce_interval=Interval} = State,
    TRef = erlang:start_timer(Interval, self(), announce),
    NewState = State#state{timer_ref=TRef},
    {noreply, NewState};

handle_cast(init_add_peers_timer, State) ->
    #state{add_peers_interval=Interval} = State,
    TRef = erlang:start_timer(Interval, self(), add_peers),
    NewState = State#state{timer_ref=TRef},
    {noreply, NewState}.


handle_info({timeout, _, announce}, State) ->
    #state{
        instance_name=Name,
        sub_type=SubType,
        torrent_id=TorrentID,
        btport=MyPortBT} = State,
    lager:debug("Handle mDNS timeout for ~p.", [TorrentID]),
    mdns_net:publish_service(Name, ?ST, MyPortBT, [SubType]),
    _ = gen_server:cast(self(), init_add_peers_timer),
    % Schedule a timer reset later
    _ = gen_server:cast(self(), init_announce_timer),
    {noreply, State};
handle_info({timeout, _, add_peers}, State) ->
    #state{
        infohash=InfoHash,
        torrent_id=TorrentID} = State,
    Peers = etorrent_mdns_state:get_peers(InfoHash),

    lager:debug("Adding peers ~p.", [Peers]),
    ok = etorrent_peer_mgr:add_peers(TorrentID, Peers),
    lager:info("Added ~B peers from mDNS for ~p.", [length(Peers), TorrentID]),
    {noreply, State}.


terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.


sub_type(InfoHashBin) ->
    "_" ++ literal_id(InfoHashBin).

instance_name(PeerIdBin) ->
    literal_id(PeerIdBin).

literal_id(<<IdInt:160>>) ->
    binary_to_list(list_to_binary(integer_id_to_literal(IdInt))).

integer_id_to_literal(IdInt) when is_integer(IdInt) ->
    io_lib:format("~40.16.0B", [IdInt]).

