%%%-------------------------------------------------------------------
%%% File    : etorrent_bad_peer_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Peer management server
%%%
%%% Created : 19 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------

%%% @todo: Monitor peers and retry them.
%%%        In general, we need peer management here.
-module(etorrent_peer_mgr).
-behaviour(gen_server).

%% API
-export([start_link/1, enter_bad_peer/3, add_peers/2, add_peers/3, is_bad_peer/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-type peerinfo() :: etorrent_types:peerinfo().
-type torrent_id() :: etorrent_types:torrent_id().
-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().

-record(bad_peer, { ipport       :: {ipaddr(), portnum()} | '_',
                    offenses     :: integer()      | '_',
                    peerid       :: binary()       | '_',
                    last_offense :: {integer(), integer(), integer()} | '$1' }).

-record(state, { local_peer_id         :: binary(),
                 available_peers = []  :: [{torrent_id(), peerinfo()}] }).

-define(SERVER, ?MODULE).
-define(DEFAULT_BAD_COUNT, 2).
-define(GRACE_TIME, 900).
-define(CHECK_TIME, timer:seconds(120)).
-define(DEFAULT_CONNECT_TIMEOUT, 30 * 1000).

%% ====================================================================
% @doc Start the peer manager
% @end
-spec start_link(binary()) -> {ok, pid()} | ignore | {error, term()}.
start_link(LocalPeerId)
  when is_binary(LocalPeerId) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [LocalPeerId], []).

% @doc Tell the peer mananger that a given peer behaved badly.
% @end
-spec enter_bad_peer(ipaddr(), portnum(), binary()) -> ok.
enter_bad_peer(IP, Port, PeerId) ->
    gen_server:cast(?SERVER, {enter_bad_peer, IP, Port, PeerId}).

% @doc Add a list of {IP, Port} peers to the manager.
% <p>The manager will use the list of peers for connections to other peers. It
% may not use all of those given if it deems it has enough connections right
% now.</p>
% @end
-spec add_peers(integer(), [{ipaddr(), portnum()}]) -> ok.
add_peers(TorrentId, IPList) ->
    add_peers("no_tracker_url", TorrentId, IPList).
-spec add_peers(string(), integer(), [{ipaddr(), portnum()}]) -> ok.
add_peers(TrackerUrl, TorrentId, IPList) ->
    gen_server:cast(?SERVER, {add_peers, TrackerUrl,
                              [{TorrentId, {IP, Port}} || {IP, Port} <- IPList]}).

% @doc Returns true if this peer is in the list of baddies
% @end
-spec is_bad_peer(ipaddr(), portnum()) -> boolean().
is_bad_peer(IP, Port) ->
    case ets:lookup(etorrent_bad_peer, {IP, Port}) of
        [] -> false;
        [P] -> P#bad_peer.offenses > ?DEFAULT_BAD_COUNT
    end.

%% ====================================================================

init([LocalPeerId]) ->
    random:seed(os:timestamp()), %% Seed RNG
    erlang:send_after(?CHECK_TIME, self(), cleanup_table),
    _Tid = ets:new(etorrent_bad_peer, [protected, named_table,
                                       {keypos, #bad_peer.ipport}]),
    {ok, #state{ local_peer_id = LocalPeerId }}.

handle_call(_Request, _From, State) ->
    error(badarg),
    {reply, ok, State}.

handle_cast({add_peers, TrackerUrl, IPList}, S) ->
    lager:debug("Add peers ~p.", [IPList]),
    NS = start_new_peers(TrackerUrl, IPList, S),
    {noreply, NS};
handle_cast({enter_bad_peer, IP, Port, PeerId}, S) ->
    case ets:lookup(etorrent_bad_peer, {IP, Port}) of
        [] ->
            ets:insert(etorrent_bad_peer,
                       #bad_peer { ipport = {IP, Port},
                                   peerid = PeerId,
                                   offenses = 1,
                                   last_offense = os:timestamp() });
        [P] ->
            ets:insert(etorrent_bad_peer,
                       P#bad_peer { offenses = P#bad_peer.offenses + 1,
                                    peerid = PeerId,
                                    last_offense = os:timestamp() })
    end,
    {noreply, S};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup_table, S) ->
    Bound = etorrent_utils:now_subtract_seconds(os:timestamp(), ?GRACE_TIME),
    _N = ets:select_delete(etorrent_bad_peer,
                           [{#bad_peer { last_offense = '$1', _='_'},
                             [{'<','$1',{Bound}}],
                             [true]}]),
    gen_server:cast(?SERVER, {add_peers, []}),
    erlang:send_after(?CHECK_TIME, self(), cleanup_table),
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------

start_new_peers(TrackerUrl, IPList, State) ->
    %% Update the PeerList with the new incoming peers
    PeerList = etorrent_utils:list_shuffle(
		 clean_list(IPList ++ State#state.available_peers)),
    PeerId   = State#state.local_peer_id,
    {value, SlotsLeft} = etorrent_counters:slots_left(),
    Remaining = fill_peers(TrackerUrl, SlotsLeft, PeerId, PeerList),
    State#state{available_peers = Remaining}.

clean_list([]) -> [];
clean_list([H | T]) ->
    [H | clean_list(T -- [H])].

fill_peers(_TrackerUrl, 0, _PeerId, Rem) -> Rem;
fill_peers(_TrackerUrl, _K, _PeerId, []) -> [];
fill_peers(TrackerUrl, K, PeerId, [{TorrentId, {IP, Port}} | R]) ->
    case is_bad_peer(IP, Port) of
       true -> fill_peers(TrackerUrl, K, PeerId, R);
       false -> guard_spawn_peer(TrackerUrl, K, PeerId, TorrentId, IP, Port, R)
    end.

guard_spawn_peer(TrackerUrl, K, PeerId, TorrentId, IP, Port, R) ->
    case etorrent_table:connected_peer(IP, Port, TorrentId) of
        true ->
            % Already connected to the peer. This happens
            % when the peer connects back to us and the
            % tracker, which knows nothing about this,
            % still hands us the ip address.
            fill_peers(TrackerUrl, K, PeerId, R);
        false ->
            case etorrent_table:get_torrent(TorrentId) of
                not_found -> %% No such Torrent currently started, skip
                    fill_peers(TrackerUrl, K, PeerId, R);
                {value, PL} ->
                    try_spawn_peer(TrackerUrl, K, PeerId, PL, TorrentId, IP, Port, R)
            end
    end.

try_spawn_peer(TrackerUrl, K, PeerId, PL, TorrentId, IP, Port, R) ->
    spawn_peer(TrackerUrl, PeerId, PL, TorrentId, IP, Port),
    fill_peers(TrackerUrl, K-1, PeerId, R).

spawn_peer(TrackerUrl, LocalPeerId, PL, TorrentId, IP, Port) ->
    proc_lib:spawn(fun () ->
      {value, PL2} = etorrent_torrent:lookup(TorrentId),
      %% Get the rewritten peer id (if defined).
      LocalPeerId2 = proplists:get_value(peer_id, PL2, LocalPeerId),

      LocalIP = etorrent_config:listen_ip(),
      Options = case LocalIP of all -> []; _ -> [{ip, LocalIP}] end
                ++ [binary, {active, false}],
      case gen_tcp:connect(IP, Port, Options, ?DEFAULT_CONNECT_TIMEOUT) of
	  {ok, Socket} ->
	      case etorrent_proto_wire:initiate_handshake(
		     Socket,
		     LocalPeerId2, %% local peer id as a binary, comes from init/1.
		     proplists:get_value(info_hash, PL)) of
          %% Connected to the local node.
		  {ok, _Capabilities, LocalPeerId} -> ok;
		  {ok, _Capabilities, LocalPeerId2} -> ok;
		  {ok, Capabilities, RemotePeerId} ->
		      {ok, RecvPid, ControlPid} =
			  etorrent_peer_pool:start_child(
			    TrackerUrl,
			    LocalPeerId2,
                RemotePeerId,
                proplists:get_value(info_hash, PL),
			    TorrentId,
			    {IP, Port},
			    Capabilities,
			    Socket),
		      etorrent_peer_control:initialize(ControlPid, outgoing),
		      ok = etorrent_peer_recv:forward_control(Socket, RecvPid),
		      ok;
          {error, Reason} ->
              lager:debug("Outgoing handshake failed with reason ~p.", [Reason]),
              ok
	      end;
	  {error, _Reason} -> ok
      end
   end).
