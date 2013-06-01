%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle various state about torrents in ETS tables.
%% <p>This module implements a server which governs 3 internal ETS
%% tables. As long as the process is living, the tables are there for
%% other processes to query. Also, the server acts as a serializer on
%% table access.</p>
%% @end
-module(etorrent_table).
-behaviour(gen_server).


%% API
%% Startup/init
-export([start_link/0]).

%% File Path map
-export([get_path/2, insert_path/2, delete_paths/1]).

%% Peer information
-export([get_peer/1,
         all_peers/0,
         all_tid_and_pids/0,
         connected_peer/3,
         foreach_peer/2,
         foreach_peer_of_tracker/2,
         get_peer_info/1,
         new_peer/8,
         statechange_peer/2
        ]).

%% Torrent information
-export([all_torrents/0,
         new_torrent/4,
         statechange_torrent/2,
         get_torrent/1,
         acquire_check_token/1]).

%% Histogram handling code
-export([
         histogram_enter/2,
         histogram/1,
         histogram_delete/1]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
     terminate/2, code_change/3]).


-type ipaddr() :: etorrent_types:ipaddr().
-type portnum() :: etorrent_types:portnum().
-type peerid() :: etorrent_types:peerid().
%% The path map tracks file system paths and maps them to integers.
-record(path_map, {
        id :: {'_' | '$1' | non_neg_integer(), '_' | non_neg_integer()},
        % File system path -- work dir
        path :: string() | '_'
}).

-record(peer, {
        % We identify each peer with it's pid.
        pid :: pid() | '_' | '$1',
        % Which tracker this peer comes from.
        % A tracker is identified by the hash of its url.
        tracker_url_hash :: integer() | '_',
        % Ip of peer in question
        ip :: ipaddr() | '_',
        % Port of peer in question
        port :: non_neg_integer() | '_',
        % Torrent Id for peer
        torrent_id :: non_neg_integer() | '_',
        state :: 'seeding' | 'leeching' | '_',
        is_fast :: boolean(),
        peer_id :: peerid(),
        version = <<"">> :: binary()
}).

-type tracking_map_state()
    :: 'started' | 'stopped' | 'checking' | 'awaiting' | 'duplicate'.

%% The tracking map tracks torrent id's to filenames, etc. It is the
%% high-level view
-record(tracking_map, {id :: '_' | integer(), %% Unique identifier of torrent
                       filename :: '_' | string(),    %% The filename
                       supervisor_pid :: '_' | pid(), %% Who is supervising
                       info_hash :: '_' | binary() | 'unknown',
                       state :: '_' | tracking_map_state()}).

-record(state, { monitoring :: dict() }).

-define(SERVER, ?MODULE).

%%====================================================================

%% @doc Start the server
%% @end
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Return everything we are currently tracking by their ids
%% @end
-spec all_torrents() -> [term()]. % @todo: Fix as proplists
all_torrents() ->
    Objs = ets:match_object(tracking_map, '_'),
    [proplistify_tmap(O) || O <- Objs].

%% @doc Return a status on all peers in the main table
%% @end
-spec all_peers() -> [proplists:proplist()].
all_peers() ->
    Objs = ets:match_object(peers, '_'),
    [proplistify_peer(O) || O <- Objs].

all_tid_and_pids() ->
    R = ets:match(peers, #peer { torrent_id = '$1', pid = '$2', _ = '_' }),
    {value, [{Tid, Pid} || [Tid, Pid] <- R]}.

%% @doc Alter the state of the Tracking map identified by Id
%%   <p>by What (see alter_map/2).</p>
%% @end
-type alteration() :: {infohash, binary()} | started | stopped | checking.
-spec statechange_torrent(integer(), alteration()) -> ok.
statechange_torrent(Id, What) ->
    [O] = ets:lookup(tracking_map, Id),
    ets:insert(tracking_map, alter_map(O, What)),
    ok.

%% @doc Lookup a torrent by a Key
%% <p>Several keys are accepted: Infohash, filename, TorrentId. Return
%% is a proplist with information about the torrent.</p>
%% @end
-spec get_torrent({infohash, binary()} | {filename, string()} | integer()) ->
              not_found | {value, term()}. % @todo: Change term() to proplist()
get_torrent(Id) when is_integer(Id) ->
    case ets:lookup(tracking_map, Id) of
    [O] ->
        {value, proplistify_tmap(O)};
    [] ->
        not_found
    end;
get_torrent({infohash, IH}) ->
    case ets:match_object(tracking_map, #tracking_map { _ = '_', info_hash = IH }) of
    [O] ->
        {value, proplistify_tmap(O)};
    [] ->
        not_found
    end;
get_torrent({filename, FN}) ->
    case ets:match_object(tracking_map, #tracking_map { _ = '_', filename = FN }) of
    [O] ->
        {value, proplistify_tmap(O)};
    [] ->
        not_found
    end.

%% @doc Enter a Piece Number in the histogram
%% @end
-spec histogram_enter(pid(), pos_integer()) -> true.
histogram_enter(Pid, PN) ->
    ets:insert_new(histogram, {Pid, PN}).

%% @doc Return the histogram part of the peer represented by Pid
%% @end
-spec histogram(pid()) -> [pos_integer()].
histogram(Pid) ->
    ets:lookup_element(histogram, Pid, 2).

%% @doc Delete the histogram for a Pid
%% @end
-spec histogram_delete(pid()) -> true.
histogram_delete(Pid) ->
    ets:delete(histogram, Pid).

% @doc Map a {PathId, TorrentId} pair to a Path (string()).
% @end
-spec get_path(integer(), integer()) -> {ok, string()}.
get_path(Id, TorrentId) when is_integer(Id) ->
    Pth = ets:lookup_element(path_map, {Id, TorrentId}, #path_map.path),
    {ok, Pth}.

%% @doc Attempt to mark the torrent for checking.
%%  <p>If this succeeds, returns true, else false</p>
%% @end
-spec acquire_check_token(integer()) -> boolean().
acquire_check_token(Id) ->
    %% @todo when using a monitor-approach, this can probably be
    %% infinity.
    gen_server:call(?MODULE, {acquire_check_token, Id}).

%% @doc Populate the #path_map table with entries. Return the Id
%% <p>If the path-map entry is already there, its Id is returned straight
%% away.</p>
%% @end
-spec insert_path(string(), integer()) -> {value, integer()}.
insert_path(Path, TorrentId) ->
    case ets:match(path_map, #path_map { id = {'$1', '_'}, path = Path}) of
        [] ->
            Id = etorrent_counters:next(path_map),
            PM = #path_map { id = {Id, TorrentId}, path = Path},
        true = ets:insert(path_map, PM),
            {value, Id};
    [[Id]] ->
            {value, Id}
    end.

%% @doc Delete entries from the pathmap based on the TorrentId
%% @end
-spec delete_paths(integer()) -> ok.
delete_paths(TorrentId) when is_integer(TorrentId) ->
    MS = [{{path_map,{'_','$1'},'_','_'},[],[{'==','$1',TorrentId}]}],
    ets:select_delete(path_map, MS),
    ok.

%% @doc Find the peer matching Pid
%% @todo Consider coalescing calls to this function into the select-function
%% @end
-spec get_peer_info(pid()) -> not_found | {peer_info, seeding | leeching, integer()}.
get_peer_info(Pid) when is_pid(Pid) ->
    case ets:lookup(peers, Pid) of
    [] -> not_found;
    [PR] -> {peer_info, PR#peer.state, PR#peer.torrent_id}
    end.


%% @doc Return all peer pids with a given torrentId
%% @end
%% @todo We can probably fetch this from the supervisor tree. There is
%% less reason to have this then.
-spec all_peer_pids(integer()) -> {value, [pid()]}.
all_peer_pids(Id) ->
    R = ets:match(peers, #peer { torrent_id = Id, pid = '$1', _ = '_' }),
    {value, [Pid || [Pid] <- R]}.

%% @doc Return all peer pids come from the tracker designated by its url.
%% @end
-spec all_peers_of_tracker(string()) -> {value, [pid()]}.
all_peers_of_tracker(Url) ->
    R = ets:match(peers, #peer{tracker_url_hash = erlang:phash2(Url),
                               pid = '$1', _ = '_'}),
    {value, [Pid || [Pid] <- R]}.

%% @doc Change the peer to a seeder
%% @end
-spec statechange_peer(pid(), seeder) -> ok.
statechange_peer(Pid, seeder) ->
    TorrentId = ets:lookup_element(peers, Pid, #peer.torrent_id),
    etorrent_torrent:statechange(TorrentId, [dec_connected_leecher,
                                             inc_connected_seeder]),
    true = ets:update_element(peers, Pid, {#peer.state, seeding}),
    ok;
statechange_peer(Pid, {version, NewVersion}) ->
    true = ets:update_element(peers, Pid, {#peer.version, NewVersion}),
    ok.

%% @doc Insert a row for the peer
%% @end
-spec new_peer(string(), ipaddr(), portnum(), integer(), pid(),
               seeding | leeching, boolean(), peerid()) -> ok.
new_peer(TrackerUrl, IP, Port, TorrentId, Pid, State, IsFast, PeerId)
        when is_boolean(IsFast) ->
    Peer = #peer{ pid = Pid, tracker_url_hash = erlang:phash2(TrackerUrl),
                  ip = IP, port = Port, torrent_id = TorrentId, state = State,
                  is_fast = IsFast, peer_id = PeerId},
    etorrent_torrent:statechange(TorrentId, [case State of
                seeding  -> inc_connected_seeder;
                leeching -> inc_connected_leecher
            end]),
    true = ets:insert(peers, Peer),
    lager:debug("Register new peer ~p.", [Peer]),
    add_monitor(peer, Pid).

%% @doc Add a new torrent
%% <p>The torrent is given by File and its infohash with the
%% Supervisor pid as given to the database structure.</p>
%% @end
-spec new_torrent(string(), binary(), pid(), integer()) -> ok.
new_torrent(File, IH, Supervisor, Id) when is_integer(Id),
                                        is_pid(Supervisor),
                                        is_binary(IH),
                                        is_list(File) ->
    add_monitor({torrent, Id}, Supervisor),
    TM = #tracking_map { id = Id,
             filename = File,
             supervisor_pid = Supervisor,
             info_hash = IH,
             state = awaiting},
    true = ets:insert(tracking_map, TM),
    ok.

%% @doc Returns true if we are already connected to this peer.
%% @end
-spec connected_peer(ipaddr(), portnum(), integer()) -> boolean().
connected_peer(IP, Port, Id) when is_integer(Id) ->
    [] =/= ets:match(peers, #peer { ip = IP, port = Port, torrent_id = Id, _ = '_'}).


%% IP and Port are remote ones.
-spec get_peer({address, TorrentId, IP, Port}) -> {value, PL} | not_found when
        PL :: [{atom(), term()}],
        TorrentId :: non_neg_integer(),
        IP :: ipaddr(),
        Port :: portnum();
    ({peed_id, TorrentId, PeerId}) -> {value, PL} | not_found when
        PL :: [{atom(), term()}],
        TorrentId :: non_neg_integer(),
        PeerId :: peerid();
    ({pid, pid()}) -> {value, PL} | not_found when
        PL :: [{atom(), term()}].
get_peer({address, TorrentId, IP, Port}) ->
    Pattern = #peer { ip = IP, port = Port, torrent_id = TorrentId, _ = '_'},
    case ets:match_object(peers, Pattern) of
    [O] ->
        {value, proplistify_peer(O)};
    [] ->
        not_found
    end;
get_peer({peer_id, TorrentId, PeerId}) ->
    Pattern = #peer { peer_id = PeerId, torrent_id = TorrentId, _ = '_'},
    case ets:match_object(peers, Pattern) of
    [O] ->
        {value, proplistify_peer(O)};
    [] ->
        not_found
    end;
get_peer({pid, Pid}) ->
    case ets:lookup(peers, Pid) of
    [O] ->
        {value, proplistify_peer(O)};
    [] ->
        not_found
    end.


%% @doc Invoke a function on all peers matching a torrent Id
%% @end
-spec foreach_peer(integer(), fun((pid()) -> term())) -> ok.
foreach_peer(Id, F) ->
    {value, Pids} = all_peer_pids(Id),
    lists:foreach(F, Pids),
    ok.

%% @doc Invoke a function on all peers come from one tracker.
%% @end
-spec foreach_peer_of_tracker(string(), fun((pid()) -> term())) -> ok.
foreach_peer_of_tracker(TrackerUrl, F) ->
    {value, Pids} = all_peers_of_tracker(TrackerUrl),
    lists:foreach(F, Pids),
    ok.


%%====================================================================

%% @private
init([]) ->
    ets:new(path_map, [public, {keypos, #path_map.id}, named_table]),
    ets:new(peers, [named_table, {keypos, #peer.pid}, public]),
    ets:new(tracking_map, [named_table, {keypos, #tracking_map.id}, public]),
    ets:new(histogram, [named_table, {keypos, 1}, public, bag]),
    {ok, #state{ monitoring = dict:new() }}.

%% @private
handle_call({monitor_pid, Type, Pid}, _From, S) ->
    Ref = erlang:monitor(process, Pid),
    {reply, ok,
     S#state {
       monitoring = dict:store(Ref, {Pid, Type}, S#state.monitoring)}};
handle_call({acquire_check_token, Id}, _From, S) ->
    %% @todo This should definitely be a monitor on the _From process
    R = case ets:match(tracking_map,
                       #tracking_map { _ = '_', state = checking }) of
            [] ->
                [O] = ets:lookup(tracking_map, Id),
                ets:insert(tracking_map, O#tracking_map { state = checking }),
                true;
            _ ->
                false
        end,
    {reply, R, S}.

%% @private
handle_cast(Msg, S) ->
    {stop, Msg, S}.

%% @private
handle_info({'DOWN', Ref, _, _, _}, S) ->
    {ok, {X, Type}} = dict:find(Ref, S#state.monitoring),
    case Type of
        peer ->
            [#peer{torrent_id=TorrentId, state=State}] = ets:lookup(peers, X),
            etorrent_torrent:statechange(TorrentId, [case State of
                seeding  -> dec_connected_seeder;
                leeching -> dec_connected_leecher
            end]),
            true = ets:delete(peers, X);
        {torrent, Id} ->
            true = ets:delete(tracking_map, Id)
    end,
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring) }}.

%% @private
code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%% @private
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------

proplistify_tmap(#tracking_map { id = Id, filename = FN, supervisor_pid = SPid,
                 info_hash = IH, state = S }) ->
    Pairs = [{id, Id}, {filename, FN}, {supervisor, SPid}, {info_hash, IH},
             {state, S}],
    [proplists:property(K,V) || {K, V} <- Pairs].

proplistify_peer(#peer {
                     pid = Pid, ip = IP, port = Port,
                     torrent_id = TorrentId, state = State, is_fast = IsFast,
                     version = ClientVersion
                    }) ->
    Pairs = [{pid, Pid}, {ip, IP}, {port, Port}, {torrent_id, TorrentId},
             {state, State}, {is_fast, IsFast}, {version, ClientVersion}],
    [proplists:property(K, V) || {K, V} <- Pairs].

add_monitor(Type, Pid) ->
    gen_server:call(?SERVER, {monitor_pid, Type, Pid}).

alter_map(TM, What) ->
    case What of
        {infohash, IH} ->
            TM#tracking_map { info_hash = IH };
        checking ->
            TM#tracking_map { state = checking };
        started ->
            TM#tracking_map { state = started };
        stopped ->
            TM#tracking_map { state = stopped }
    end.
