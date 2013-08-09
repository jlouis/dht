-module(etorrent_scarcity).
-behaviour(gen_server).
%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc A server to track how many peers provide each piece
%%
%% The scarcity server associates a counter with each piece. When
%% a peer comes online it registers it's prescence to the scarcity
%% server. After the peer has registered it's precence it is responsible
%% for keeping the scarcity server updated with additions to the
%% set of pieces that it's providing, the peer is also expected to
%% provide a copy of the updated piece set to the server.
%%
%% The server is expected to increment the counter and reprioritize
%% the set of pieces of a torrent when the scarcity changes. When a
%% peer exits the server is responsible for decrementing the counter
%% for each piece that was provided by the peerl.
%%
%% The purpose of the server is not to provide a mapping between
%% peers and pieces to other processes.
%%
%% # Change notifications
%% A client can subscribe to changes in the ordering of a set of pieces.
%% This is an asynchronous version of get_order/2 with additions to provide
%% continious updates, versioning and context.
%%
%% The client must provide the server with the set of pieces to monitor,
%% a client defined tag for the subscription. The server will provide the
%% client with a unique reference to the subscription.
%%
%% The server should provide the client with the ordering of the pieces
%% at the time of the call. This ensures that the client does not have
%% to retrieve it after the subscription has been established.
%%
%% The server will send an updated order to the client each time the order
%% changes, the client defined tag and the subscription reference is
%% included in each update.
%%
%% The client is expected to cancel and resubscribe if the set of pieces
%% changes. The client is also expected to handle updates that are tagged
%% with an expired subcription reference. The server is expected to cancel
%% subscriptions when a client crashes.
%%
%% Change notifications are rate limitied to an interval specified by the
%% client when the client subscription is initialialized. If an update
%% is triggered too son after a prevous update the update is supressed
%% and an update is scheduled to be sent once the interval has passed. 
%%
%% ## notes on implementation
%% A complete piece set is provided on each update in order to reduce
%% the amount of effort spent on keeping the two sets synced. This also
%% reduces memory usage for torrents with more than 512 pieces due to
%% the way piece sets are implemented (2011-03-09).
%% @end


%% gproc entries
-export([register_server/1,
         lookup_server/1,
         await_server/1]).

%% api functions
-export([start_link/2,
         start_link/3,
         add_peer/2,
         add_piece/3,
         get_order/2,
         watch/3,
         unwatch/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).


-type torrent_id() :: etorrent_types:torrent_id().
-type pieceindex() :: etorrent_types:piece_index().
-type pieceset() :: etorrent_pieceset:t().
-type monitorset() :: etorrent_monitorset:monitorset().
-type timeserver() :: etorrent_timer:timeserver().
-type table() :: atom() | ets:tid().

-record(watcher, {
    pid = exit(required) :: pid(),
    ref = exit(required) :: reference(),
    tag = exit(required) :: term(),
    pieceset  = exit(required) :: pieceset(),
    piecelist = exit(required) :: [pos_integer()],
    interval  = exit(required) :: pos_integer(),
    changed   = exit(required) :: boolean(),
    timer_ref = exit(required) :: none | reference()}).

%% Watcher states:
%% waiting: changed=false, timer_ref=none
%% limited: changed=false, timer_ref=reference()
%% updated: changed=true,  timer_ref=reference()

-record(state, {
    torrent_id    = exit(required) :: torrent_id(),
    timeserver    = exit(required) :: timeserver(),
    num_peers     = exit(required) :: table(),
    peer_monitors = exit(required) :: monitorset(),
    watchers      = exit(required) :: [#watcher{}]}).

%% @doc Register as the scarcity server for a torrent
%% @end
-spec register_server(torrent_id()) -> true.
register_server(TorrentID) ->
    gproc:add_local_name({etorrent, TorrentID, scarcity}).


%% @doc Lookup the scarcity server for a torrent
%% @end
-spec lookup_server(torrent_id()) -> pid().
lookup_server(TorrentID) ->
    gproc:lookup_local_name({etorrent, TorrentID, scarcity}).


%% @doc Wait for the scarcity server of a torrent to register
%% @end
-spec await_server(torrent_id()) -> pid().
await_server(TorrentID) ->
    Name = {etorrent, TorrentID, scarcity},
    {Pid, undefined} = gproc:await({n, l, Name}, 5000),
    Pid.


%% @doc Start a scarcity server
%% The server will always register itself as the scarcity
%% server for the given torrent as soon as it has started.
%% @end
-spec start_link(torrent_id(), pos_integer()) -> {ok, pid()}.
start_link(TorrentID, Numpieces) ->
    start_link(TorrentID, etorrent_timer:native(), Numpieces).


-spec start_link(torrent_id(), timeserver(), pos_integer()) -> {ok, pid()}.
start_link(TorrentID, Timeserver, Numpieces) ->
    gen_server:start_link(?MODULE, {TorrentID, Timeserver, Numpieces}, []).


%% @doc Register as a peer
%% Calling this function will register the current process
%% as a peer under the given torrent. The peer must provide
%% an initial set of pieces to the server in order to relieve
%% the server from handling peers crashing before providing one.
%% @end
-spec add_peer(torrent_id(), pieceset()) -> ok.
add_peer(TorrentID, Pieceset) ->
    SrvPid = lookup_server(TorrentID),
    gen_server:call(SrvPid, {add_peer, self(), Pieceset}).


%% @doc Add this peer as the provider of a piece
%% Add this peer as the provider of a piece and send an updated
%% version of the piece set to the server.
%% @end
-spec add_piece(torrent_id(), pos_integer(), pieceset()) -> ok.
add_piece(TorrentID, Index, Pieceset) ->
    SrvPid = lookup_server(TorrentID),
    gen_server:call(SrvPid, {add_piece, self(), Index, Pieceset}).


%% @doc Get a list of pieces ordered by scarcity
%% The returned list will only contain pieces that are also members
%% of the piece set. If two pieces are equally scarce the piece index
%% is used to rank the pieces.
%% @end
-spec get_order(torrent_id(), pieceset()) -> {ok, [pos_integer()]}.
get_order(TorrentID, Pieceset) ->
    SrvPid = lookup_server(TorrentID),
    gen_server:call(SrvPid, {get_order, Pieceset}).

%% @doc Receive updates to changes in scarcity
%% 
%% @end
-spec watch(torrent_id(), term(), pieceset()) ->
    {ok, reference(), [pos_integer()]}.
watch(TorrentID, Tag, Pieceset) ->
    watch(TorrentID, Tag, Pieceset, 5000).


%% @doc Receive updates to changes in scarcity
%%
%% @end
-spec watch(torrent_id(), term(), pieceset(), pos_integer()) ->
    {ok, reference(), [pos_integer()]}.
watch(TorrentID, Tag, Pieceset, Interval) ->
    SrvPid = lookup_server(TorrentID),
    gen_server:call(SrvPid, {watch, self(), Interval, Tag, Pieceset}).

%% @doc Cancel updates to changes in scarcity
%%
%% @end
-spec unwatch(torrent_id(), reference()) -> ok.
unwatch(TorrentID, Ref) ->
    SrvPid = lookup_server(TorrentID),
    gen_server:call(SrvPid, {unwatch, Ref}).


%% @private
-spec init({torrent_id(), timeserver(), pieceindex()}) -> {ok, #state{}}.
init({TorrentID, Timeserver, Numpieces}) ->
    Tab = ets:new(etorrent_scarcity, [set,private]),
    %% Set all counters to 0 so we don't need to handle default
    %% values for new pieces anywhere else in the module.
    [ets:insert(Tab, {I, 0}) || I <- lists:seq(0, Numpieces - 1)],

    register_server(TorrentID),
    InitState = #state{
        torrent_id=TorrentID,
        timeserver=Timeserver,
        num_peers=Tab,
        peer_monitors=etorrent_monitorset:new(),
        watchers=[]},
    {ok, InitState}.


%% @private
handle_call({add_peer, PeerPid, Pieceset}, _, State) ->
    #state{
        timeserver=Time,
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    NewNumpeers = increment(Pieceset, Numpeers),
    NewMonitors = etorrent_monitorset:insert(PeerPid, Pieceset, Monitors),
    NewWatchers = send_updates(Pieceset, Watchers, NewNumpeers, Time),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers,
        watchers=NewWatchers},
    {reply, ok, NewState};

handle_call({add_piece, Pid, PieceIndex, Pieceset}, _, State) ->
    #state{
        timeserver=Time,
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    ets:update_counter(Numpeers, PieceIndex, 1),
    NewNumpeers = Numpeers,
    NewMonitors = etorrent_monitorset:update(Pid, Pieceset, Monitors),
    NewWatchers = send_updates(PieceIndex, Watchers, NewNumpeers, Time),
    NewState = State#state{
        peer_monitors=NewMonitors,
        num_peers=NewNumpeers,
        watchers=NewWatchers},
    {reply, ok, NewState};

handle_call({get_order, Pieceset}, _, State) ->
    #state{num_peers=Numpeers} = State,
    Piecelist = etorrent_pieceset:to_list(Pieceset),
    Pieceorder = sorted_piecelist(Piecelist, Numpeers),
    {reply, {ok, Pieceorder}, State};

handle_call({watch, Pid, Interval, Tag, Pieceset}, _, State) ->
    #state{timeserver=Time, num_peers=Numpeers, watchers=Watchers} = State,
    %% Use a monitor reference as the subscription reference,
    %% this let's us tear down subscriptions when client processes
    %% crash. Currently the interface of the monitorset module does
    %% not let us associate values with monitor references so there
    %% is no benefit to using it in this case.
    MRef = erlang:monitor(process, Pid),
    TRef = etorrent_timer:start_timer(Time, Interval, self(), MRef),
    Piecelist = etorrent_pieceset:to_list(Pieceset),
    Watcher = #watcher{
        pid=Pid,
        ref=MRef,
        tag=Tag,
        pieceset=Pieceset,
        piecelist=Piecelist,
        interval=Interval,
        %% The initial state of a watcher is limited.
        changed=false,
        timer_ref=TRef},
    NewWatchers = [Watcher|Watchers],
    NewState = State#state{watchers=NewWatchers},
    Pieceorder = sorted_piecelist(Piecelist, Numpeers),
    {reply, {ok, MRef, Pieceorder}, NewState};

handle_call({unwatch, MRef}, _, State) ->
    erlang:demonitor(MRef),
    {reply, ok, delete_watcher(MRef, State)}.


%% @private
handle_cast(_, State) ->
    {noreply, State}.


%% @private
handle_info({'DOWN', MRef, process, Pid, _}, State) ->
    #state{
        timeserver=Time,
        peer_monitors=Monitors,
        num_peers=Numpeers,
        watchers=Watchers} = State,
    %% We are monitoring two types of clients, peers and
    %% subscribers. If a peer exits we want to update the counters
    %% and notify the subscribers. If a subscriber exits we want
    %% to tear down the subscription. Assume that all monitors
    %% that are not peer monitors are active subscription references.
    NewState = case etorrent_monitorset:is_member(Pid, Monitors) of
        true ->
            Pieceset = etorrent_monitorset:fetch(Pid, Monitors),
            NewNumpeers = decrement(Pieceset, Numpeers),
            NewMonitors = etorrent_monitorset:delete(Pid, Monitors),
            NewWatchers = send_updates(Pieceset, Watchers, NewNumpeers, Time),
            INewState = State#state{
                peer_monitors=NewMonitors,
                num_peers=NewNumpeers,
                watchers=NewWatchers},
            INewState;
        false ->
            delete_watcher(MRef, State)
    end,
    {noreply, NewState};

handle_info({timeout, _, MRef}, State) ->
    #state{timeserver=Time, num_peers=Numpeers, watchers=Watchers} = State,
    Watcher = lists:keyfind(MRef, #watcher.ref, Watchers),
    #watcher{changed=Changed} = Watcher,
    NewWatcher = case Changed of
        %% If the watcher is still in the 'limited' state no update
        %% should be sent and the watcher should enter 'waiting'.
        false ->
            Watcher#watcher{timer_ref=none};
        %% If the watcher is in the 'updated' state an update should
        %% be sent and the watcher should enter 'limited'.
        true ->
            NewTRef = send_update(Watcher, Numpeers, Time),
            Watcher#watcher{changed=false, timer_ref=NewTRef}
    end,
    NewWatchers = lists:keyreplace(MRef, #watcher.ref, Watchers, NewWatcher),
    NewState = State#state{watchers=NewWatchers},
    {noreply, NewState}.


%% @private
terminate(_, State) ->
    {ok, State}.


%% @private
code_change(_, State, _) ->
    {ok, State}.


-spec sorted_piecelist([pieceindex()], table()) -> [pieceindex()].
sorted_piecelist(Piecelist, Numpeers) when is_list(Piecelist) ->
    Tagged = [{ets:lookup_element(Numpeers, I, 2), I} || I <- Piecelist],
    Sorted = lists:sort(Tagged),
    [I || {_, I} <- Sorted].


-spec decrement(pieceset(), table()) -> table().
decrement(Pieceset, Numpeers) ->
    etorrent_pieceset:foldl(fun(Piece, Acc) ->
        ets:update_counter(Numpeers, Piece, -1),
        Acc
    end, ok, Pieceset),
    Numpeers.


-spec increment(pieceset(), table()) -> table().
increment(Pieceset, Numpeers) ->
    etorrent_pieceset:foldl(fun(Piece, Acc) ->
        ets:update_counter(Numpeers, Piece, 1),
        Acc
    end, ok, Pieceset),
    Numpeers.


-spec send_updates(pieceset() | pos_integer(), [#watcher{}],
                   table(), timeserver()) -> [#watcher{}].
send_updates(Index, Watchers, Numpeers, Time) when is_integer(Index) ->
    HasChanged = fun(Watchedset) ->
        etorrent_pieceset:is_member(Index, Watchedset)
    end,
    [send_update(HasChanged, Watcher, Numpeers, Time) || Watcher <- Watchers];

send_updates(Pieceset, Watchers, Numpeers, Time) ->
    HasChanged = fun(Watchedset) ->
        Inter = etorrent_pieceset:intersection(Pieceset, Watchedset),
        not etorrent_pieceset:is_empty(Inter)
    end,
    [send_update(HasChanged, Watcher, Numpeers, Time) || Watcher <- Watchers].


-spec send_update(fun((pieceset()) -> boolean()), #watcher{},
                  table(), timeserver()) -> #watcher{}.
send_update(HasChanged, Watcher, Numpeers, Time) ->
    #watcher{
        pieceset=Pieceset,
        changed=Changed,
        timer_ref=TRef} = Watcher,
    case {Changed, TRef} of
        %% waiting
        {false, none} ->
            case HasChanged(Pieceset) of
                %% waiting -> limited
                true ->
                    NewTRef = send_update(Watcher, Numpeers, Time),
                    Watcher#watcher{timer_ref=NewTRef};
                %% waiting -> waiting
                false ->
                    Watcher
            end;
        %% limited -> updated
        {false, TRef} ->
            Watcher#watcher{changed=HasChanged(Pieceset)};
        %% updated -> updated
        {true, TRef} ->
            Watcher
    end.

-spec send_update(#watcher{}, table(), timeserver()) -> reference().
send_update(Watcher, Numpeers, Time) ->
    #watcher{
        pid=Pid,
        ref=MRef,
        tag=Tag,
        piecelist=Piecelist,
        interval=Interval} = Watcher,
    Pieceorder = sorted_piecelist(Piecelist, Numpeers),
    Pid ! {scarcity, MRef, Tag, Pieceorder},
    etorrent_timer:start_timer(Time, Interval, self(), MRef).




delete_watcher(MRef, State) ->
    #state{timeserver=Time, watchers=Watchers} = State,
    Watcher = lists:keyfind(MRef, #watcher.ref, Watchers),
    #watcher{timer_ref=TRef} = Watcher,
    case TRef of none -> ok; _ -> etorrent_timer:cancel(Time, TRef, [flush]) end,
    NewWatchers = lists:keydelete(MRef, #watcher.ref, Watchers),
    State#state{watchers=NewWatchers}.
