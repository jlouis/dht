%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc A Server for maintaining the the routing table in DHT
%%
%% @todo Document all exported functions.
%%
%% This module implements the higher-level logic of the DHT
%% routing table. Three things are maintained in the routing table:
%%
%%  * The routing table itself
%%  * The set of timers for node refreshes
%%  * The set of timers for routing table bucket refreshes
%% 
%% This modules main responsibility is to call out to helper modules
%% and make sure to maintain consistency of the above three states
%% we maintain.
%%
%% A node is considered disconnected if it does not respond to
%% a ping query after 10 minutes of inactivity. Inactive nodes
%% are kept in the routing table but are not propagated to
%% neighbouring nodes through responses through find_node
%% and get_peers responses.
%%
%% This allows the node to keep the routing table intact
%% while operating in offline mode. It also allows the node
%% to operate with a partial routing table without exposing
%% inconsitencies to neighboring nodes.
%%
%% A bucket is refreshed once the least recently active node
%% has been inactive for 5 minutes. If a replacement for the
%% least recently active node can't be replaced, the server
%% should wait at least 5 minutes before attempting to find
%% a replacement again.
%%
%% The timeouts (expiry times) in this server is managed
%% using a pair containg the time that a node/bucket was
%% last active and a reference to the currently active timer.
%%
%% The activity time is used to validate the timeout messages
%% sent to the server in those cases where the timer was cancelled
%% inbetween that the timer fired and the server received the timeout
%% message. The activity time is also used to calculate when
%% future timeout should occur.
%%
%% @end
-module(dht_state).
-behaviour(gen_server).
-define(K, 8).
-define(in_range(Dist, Min, Max), ((Dist >= Min) andalso (Dist < Max))).
-define(MAX_UNREACHABLE, 128).
-define(UNREACHABLE_TAB, dht_state_unreachable).

%% Lifetime
-export([
	start_link/2, start_link/3,
	load_state/2,
	dump_state/0, dump_state/1, dump_state/2
]).

%% Manipulation
-export([
	insert_node/1, insert_node/2,
	insert_nodes/1, insert_nodes/2,
	notify/2,
	ping/2, ping/3
]).

%% Query
-export([
	 closest_to/1, closest_to/2,
	 keepalive/1,
	 node_id/0,
	 refresh/3
]).

-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(state, {
    node_id :: dht:node_id(),
    routing_table :: dht_routing_table:t(), % The actual routing table
    node_timers = timer_empty() :: gb_trees:tree(dht:node_t(), {any(), any()}), % Node activity times and timeout references
    bucket_timers = timer_empty() :: gb_trees:tree(dht_routing_table:range(), {any(), any()}), % Bucker activity times and timeout references
    node_timeout :: pos_integer(),  % Default node keepalive timeout
    bucket_timeout :: pos_integer(),   % Default bucket refresh timeout
    state_file="/tmp/dht_state" :: string() }). % Path to persistent state

-include_lib("kernel/include/inet.hrl").

%
% The bucket refresh timeout is the amount of time that the
% server will tolerate a node to be disconnected before it
% attempts to refresh the bucket.
%
bucket_timeout() -> 5 * 60 * 1000.
node_timeout() -> 10 * 60 * 1000.


start_link(StateFile, BootstrapNodes) ->
	start_link(dht_metric:mk(), StateFile, BootstrapNodes).
	
start_link(RequestedID, StateFile, BootstrapNodes) ->
    gen_server:start_link({local, ?MODULE},
			  ?MODULE,
			  [RequestedID, StateFile, BootstrapNodes], []).


%% @doc Return this node id as an integer.
%% Node ids are generated in a random manner.
-spec node_id() -> dht:node_id().
node_id() ->
    gen_server:call(?MODULE, node_id).

%%
%% @equiv insert_node(Node, #{})
%%
insert_node(Node) ->
	insert_node(Node, #{}).
	
%%
%% @doc insert_node/2 inserts a new node according to the options given
%%
%% There are three variants of this function:
%% * If inserting {IP, Port} a ping will first be made to make sure the node is alive and find its ID
%% * If inserting {ID, IP, Port} no options, then a ping is first made to make sure the node exists
%% * If inserting {ID, IP, Port} with options force := true, then the node is forced into the routing table.
%%   This option is meant to be used when we already know the node is up and running, so we can
%%   skip the additional ping.
%% @end
-spec insert_node(Node, Opts) -> true | false | {error, Reason}
  when
      Node :: dht:node_t() | {inet:ip_address(), inet:port_number()},
      Opts :: #{ atom() => boolean() },
      Reason :: atom().
insert_node({IP, Port}, #{}) ->
	case ping(IP, Port, #{ unreachable_check => true}) of
	    pang -> {error, timeout};
	    ID ->
	    	gen_server:call(?MODULE, {insert_node, {ID, IP, Port}})
	end;
insert_node({ID, IP, Port}, #{ force := true }) ->
	gen_server:call(?MODULE, {insert_node, {ID, IP, Port}});
insert_node(Node, #{}) ->
	insert_node_(Node, is_interesting(Node)).

insert_node_({_, _, _}, false) -> false;
insert_node_({ID, IP, Port}, true) ->
	case ping(IP, Port, #{ unreachable_check => true}) of
		pang -> {error, timeout};
		{ok, ID} ->
			gen_server:call(?MODULE, {insert_node, {ID, IP, Port}});
		_WrongID ->
			{error, inconsistent_id}
	end.

%% @doc insert_nodes/1 inserts a list of nodes into the routing table asynchronously
%% @end
-spec insert_nodes([dht:node_t()]) -> ok.
insert_nodes(NodeInfos) ->
	insert_nodes(NodeInfos, #{}).

%% @doc insert_nodes/2 inserts nodes according to the given options.
%% Can be used to force insertion of nodes.
%% @end
-spec insert_nodes([dht:node_t()], #{ atom() => boolean()}) -> ok.
insert_nodes(NodeInfos, Opts) ->
    [spawn_link(?MODULE, insert_node, [Node, Opts]) || Node <- NodeInfos],
    ok.

%% @doc is_interesting/1 returns true if a node can enter the routing table, false otherwise
%% Check if node would fit into the routing table. This function is used by the insert_node
%% function to avoid issuing ping-queries to every node sending this node a query
%% @end
-spec is_interesting(dht:node_t()) -> boolean().
is_interesting({_, _, _} = Node) ->
    gen_server:call(?MODULE, {is_interesting, Node}).

%% @equiv closest_to(NodeID, 8)
-spec closest_to(dht:node_id()) -> list(dht:node_t()).
closest_to(NodeID) ->
    closest_to(NodeID, 8).

%% @doc closest_to/2 returns the neighborhood around an ID known to the routing table
%% @end
-spec closest_to(dht:node_id(), pos_integer()) -> list(dht:node_t()).
closest_to(NodeID, NumNodes) ->
    gen_server:call(?MODULE, {closest_to, NodeID, NumNodes}).

%% @doc notify/2 notifies the routing table of an event on a given node
%% Possible events are one of `request_timeout', `request_timeout', or `request_success'.
%% @end
-spec notify(Node, Event) -> ok
    when
      Node :: dht:node_t(),
      Event :: request_success | request_from | request_timeout.
notify(Node, Event)
  when
    Event == request_timeout;
    Event == request_success;
    Event == request_from ->
	gen_server:call(?MODULE, {Event, Node}).

%% @doc dump_state/0 dumps the routing table state to disk
%% @end
dump_state() ->
    gen_server:call(?MODULE, dump_state).

%% @doc dump_state/1 dumps the routing table state to disk into a given file
%% @end
dump_state(Filename) ->
    gen_server:call(?MODULE, {dump_state, Filename}).

-spec keepalive(dht:node_t()) -> 'ok'.
keepalive({ID, IP, Port} = Node) ->
    case ping(IP, Port) of
	ID -> notify(Node, request_success);
	pang -> notify(Node, request_timeout)
    end.

%% @doc ping/2 pings an IP/Port pair in order to determine its NodeID
%% @end
-spec ping(inet:ip_address(), inet:port_number()) -> pang | dht:node_id() | {error, Reason}
  when Reason :: atom().
ping(IP, Port) -> ping(IP, Port, #{}).

%% @doc ping/3 pings an IP/Port pair with options for filtering excess pings
%% If you set unreachable_check := true, then the table of unreachable pings is first consulted as a local
%% cache. This speeds up pings and avoids pinging nodes which are often down.
%% @end
-spec ping(inet:ip_address(), inet:port_number(), #{ atom() => boolean() }) -> pang | dht:node_id() | {error, Reason}
  when Reason :: atom().
ping(IP, Port, #{ unreachable_check := true }) ->
    ping_(IP, Port, ets:member(?UNREACHABLE_TAB, {IP, Port}));
ping(IP, Port, #{}) ->
    dht_net:ping({IP, Port}).
    
%% internal helper for ping/3
ping_(_IP, _Port, true) -> pang;
ping_(IP, Port, false) ->
    case dht_net:ping({IP, Port}) of
        pang ->
            RandNode = random_node_tag(),
            DelSpec = [{{'_', RandNode}, [], [true]}],
            ets:select_delete(?UNREACHABLE_TAB, DelSpec),
            ets:insert(?UNREACHABLE_TAB, {{IP, Port}, RandNode}),
            pang;
        NodeID ->
          NodeID
    end.

%% @doc refresh/3 refreshes a routing table bucket range
%% Refresh the contents of a bucket by issuing find_node queries to each node
%% in the bucket until enough nodes that falls within the range of the bucket
%% has been returned to replace the inactive nodes in the bucket.
%% @end
-spec refresh(any(), list(dht:node_t()), list(dht:node_t())) -> 'ok'.
refresh(Range, Inactive, Active) ->
    %% Try to refresh the routing table using the inactive nodes first,
    %% If they turn out to be reachable the problem's solved.
    do_refresh(Range, Inactive ++ Active, []).

do_refresh(_Range, [], _) -> ok;
do_refresh(Range, [{ID, _IP, _Port} = Node | T], IDs) ->
  case do_refresh_find_node(Range, Node) of
    continue -> do_refresh(Range, T, [ID | IDs]);
    stop -> ok
  end.

do_refresh_find_node(Range, Node) ->
    case dht_net:find_node(Node) of
        {error, timeout} ->
            continue;
        {_, NearNodes} ->
            do_refresh_inserts(Range, NearNodes)
    end.

do_refresh_inserts({_, _}, []) -> continue;
do_refresh_inserts({Min, Max} = Range, [{ID, _, _} = N|T]) when ?in_range(ID, Min, Max) ->
    case insert_node(N) of
      {error, timeout} -> do_refresh_inserts(Range, T);
      true -> do_refresh_inserts(Range, T);
      false ->
          insert_nodes(T),
          stop
    end;
do_refresh_inserts(Range, [N | T]) ->
    insert_node(N),
    do_refresh_inserts(Range, T).


%% @private
init([RequestedNodeID, StateFile, BootstrapNodes]) ->
    %% For now, we trap exits which ensures the state table is dumped upon termination
    %% of the process.
    %% @todo lift this restriction. Periodically dump state, but don't do it if an
    %% invariant is broken for some reason
    erlang:process_flag(trap_exit, true),

    % Initialize the table of unreachable nodes when the server is started.
    % The safe_ping and unsafe_ping functions aren't exported outside of
    % of this module so they should fail unless the server is not running.
    _ = ets:new(?UNREACHABLE_TAB, [named_table, public, bag]),

    RoutingTbl = load_state(RequestedNodeID, StateFile),
    insert_nodes(BootstrapNodes),

    %% Insert any nodes loaded from the persistent state later
    %% when we are up and running. Use unsafe insertions or the
    %% whole state will be lost if dht starts without
    %% internet connectivity.
    NodeList = dht_routing_table:node_list(RoutingTbl),
    NodeID = dht_routing_table:node_id(RoutingTbl),
    [spawn(?MODULE, insert_node, [N, #{ force => true}]) || N <- NodeList],

    %% Initialize the timers based on the state

    Now = os:timestamp(),
    {ok, #state {
	node_id = NodeID,
	bucket_timers = initialize_timers(Now, RoutingTbl),
	state_file = StateFile,
	routing_table = RoutingTbl,
	bucket_timeout = bucket_timeout(),
	node_timeout = node_timeout()
    }}.


%% @private
handle_call({is_interesting, {ID, IP, Port}}, _From,
	#state{
	  routing_table = RoutingTbl,
	  node_timeout = NTimeout,
	  node_timers = NTimers } = State) ->
    case dht_routing_table:is_member({ID, IP, Port}, RoutingTbl) of
        true ->
            %% Already a member, the ID is not interesting
            {reply, false, State};
        false ->
            %% Analyze the bucket in which the ID resides
            Members = dht_routing_table:members(ID, RoutingTbl),
            Inactive = inactive_nodes(Members, NTimeout, NTimers),
            case (Inactive /= []) orelse (length(Members) < ?K) of
                true ->
                    %% There are Inactive members or there are too few members: this is an interesting ID
                    {reply, true, State};
                false ->
                    Try = dht_routing_table:insert({ID, IP, Port}, RoutingTbl),
                    {reply, dht_routing_table:is_member({ID, IP, Port}, Try), State}
            end
	end;
handle_call({insert_node, Node}, _From, #state { routing_table = Tbl } = State) ->
    case dht_routing_table:is_member(Node, Tbl) of
        true ->
            {reply, false, State};
        false ->
            case handle_insert_node_new(Node, State) of
                {ok, S} -> {reply, true, S};
                {not_inserted, S} -> {reply, false, S}
            end
    end;
handle_call({closest_to, ID, NumNodes}, _From,
            #state{
		routing_table=Tbl,
		node_timers=NTimers,
		node_timeout=NTimeout} = State) ->
    Filter =
        fun (N) ->
		not has_timed_out(N, NTimeout, NTimers)
        end,
    NearNodes = dht_routing_table:closest_to(ID, Filter, NumNodes, Tbl),
    {reply, NearNodes, State};
handle_call({request_timeout, Node}, _From,
	        #state{
	          routing_table = Tbl,
	          node_timeout = NTimeout,
	          node_timers = PrevNTimers} = State) ->
    case dht_routing_table:is_member(Node, Tbl) of
      false ->
          {reply, ok, State};
      true ->
          {LActive, _} = timer_get(Node, PrevNTimers),
          TmpNTimers = timer_del(Node, PrevNTimers),
          NTimer = node_timer_from(os:timestamp(), NTimeout, Node),
          {reply, ok, State#state {
                          node_timers = timer_add(Node, LActive, NTimer, TmpNTimers) }}
    end;
handle_call({request_success, {ID, _IP, _Port} = Node}, _From,
	        #state{ routing_table = Tbl } = State) ->
    case dht_routing_table:is_member(Node, Tbl) of
	    false -> {reply, ok, State};
	    true ->
	        {reply, ok,
	          cycle_bucket_timers(ID,
	            cycle_node_timer(Node, os:timestamp(), State))}
    end;
handle_call({request_from, Node}, From, State) ->
    handle_call({request_success, Node}, From, State);
handle_call(dump_state, From, #state{ state_file = StateFile } = State) ->
    handle_call({dump_state, StateFile}, From, State);
handle_call({dump_state, StateFile}, _From, #state{ routing_table = Tbl } = State) ->
    try
        dump_state(StateFile, Tbl),
        {reply, ok, State}
    catch
      Class:Err ->
        {reply, {error, {dump_state_failed, Class, Err}}, State}
    end;
handle_call(node_id, _From, #state{ node_id = Self } = State) ->
    {reply, Self, State}.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

handle_time_out({ID, IP, Port} = Node, NTimeout, Timers) ->
    case has_timed_out(Node, NTimeout, Timers) of
        true ->
            spawn(?MODULE, keepalive, [ID, IP, Port]),
            true;
       false ->
           false
   end.

%% @private
handle_info({inactive_node, Node},
		    #state {
			    routing_table = Tbl,
			    node_timers=PrevNTimers,
			    node_timeout=NTimeout} = State) ->
    case dht_routing_table:is_member(Node, Tbl) of
        false ->
            {noreply, State};
        true ->
            {LActive, TRef} = timer_get(Node, PrevNTimers),
            TimerCanceled = erlang:read_timer(TRef) == false,
            HasTimedout = handle_time_out(Node, NTimeout, PrevNTimers),
            case TimerCanceled orelse HasTimedout of
                true ->
                    {noreply, cycle_node_timer(Node, os:timestamp(), LActive, State)};
	      false ->
	          {noreply, State}
	  end
    end;
handle_info({inactive_bucket, Range},
            #state{
	           routing_table=Tbl,
	           node_timers=NTimers,
	           bucket_timers=PrevBTimers,
	           node_timeout=NTimeout,
	           bucket_timeout=BTimeout} = State) ->

    case dht_routing_table:has_bucket(Range, Tbl) of
        false ->
            {noreply, State};
        true ->
            Members = dht_routing_table:members(Range, Tbl),
            {_, TRef} = timer_get(Range, PrevBTimers),
            TimerCanceled = erlang:read_timer(TRef) == false,
            HasTimedOut = refresh_bucket(Range, Members, State),
	  case TimerCanceled orelse HasTimedOut of
	      false ->
	         {noreply, State};
	     true ->
	         Now = os:timestamp(),
	         TmpBTimers = timer_del(Range, PrevBTimers),
	         LRecent = timer_oldest(Members, NTimers),
	         NewTimer = bucket_timer_from(Now, BTimeout, LRecent, NTimeout, Range),
	         NewBTimers = timer_add(Range, Now, NewTimer, TmpBTimers),
	         {noreply, State#state { bucket_timers = NewBTimers }}
	 end
    end;
handle_info({stop, Caller}, #state{} = State) ->
	Caller ! stopped,
	{stop, normal, State}.

%% @private
terminate(_, #state{ routing_table = Tbl, state_file=StateFile}) ->
	dump_state(StateFile, Tbl).

%% @private
code_change(_, State, _) ->
    {ok, State}.

%%
%% HANDLE Section
%%
handle_insert_node_new({ID, _, _} = Node, #state{ node_timeout = NTimeout, node_timers = NTimers, routing_table = Tbl } = State) ->
    Neighbours = dht_routing_table:members(ID, Tbl),
    case inactive_nodes(Neighbours, NTimeout, NTimers) of
        [] -> rt_add(Node, State);
        [Old | _ ] ->
            routing_table_replace(Old, Node, State)
    end.

%%
%% INTERNAL FUNCTIONS
%%

random_node_tag() ->
    _ = random:seed(erlang:now()),
    random:uniform(?MAX_UNREACHABLE).

refresh_bucket(Range, Members,
		#state {
		    node_timeout = NTimeout,
		    node_timers = NTimers,
		    bucket_timeout = BTimeout,
		    bucket_timers = BTimers }) ->
	case has_timed_out(Range, BTimeout , BTimers) of
	    false ->
	        false;
	    true ->
	        spawn(?MODULE, refresh,
	          [Range,
	           inactive_nodes(Members, NTimeout, NTimers),
	           active_nodes(Members, NTimeout, NTimers)]),
	        true
	end.

inactive_nodes(Nodes, Timeout, Timers) ->
    [N || N <- Nodes, has_timed_out(N, Timeout, Timers)].

active_nodes(Nodes, Timeout, Timers) ->
    [N || N <- Nodes, not has_timed_out(N, Timeout, Timers)].

node_timer_from(Time, Timeout, Node) ->
    Msg = {inactive_node, Node},
    timer_from(Time, Timeout, Msg).

%% Go through the state and update the timer infrastructure
cycle_node_timer(Node, Now,
                 #state { node_timers = NTimers,
                          node_timeout = NTimeout } = State) ->
    {NLActive, _} = timer_get(Node, NTimers),
    Removed = timer_del(Node, NTimers),
    TimerRef = node_timer_from(Now, NTimeout, Node),
    State#state { node_timers = timer_add(Node, NLActive, TimerRef, Removed) }.

cycle_node_timer(Node, Now, LActive, #state { node_timers = Timers, node_timeout = NTimeout } = State) ->
    WithoutNode = timer_del(Node, Timers),
    NT = node_timer_from(Now, NTimeout, Node),
    ReInserted = timer_add(Node, LActive, NT, WithoutNode),
    State#state { node_timers = ReInserted }.


cycle_bucket_timers(ID,
	#state {
	  routing_table = RoutingTbl,
	  bucket_timers = PrevBTimers,
	  node_timers = NTimers,
	  node_timeout = NTimeout,
	  bucket_timeout = BTimeout  } = State) ->
    Range = dht_routing_table:range(ID, RoutingTbl),
    {BActive, _} = timer_get(Range, PrevBTimers),
    TmpBTimers = timer_del(Range, PrevBTimers),
    BMembers = dht_routing_table:members(Range, RoutingTbl),
    LNRecent = timer_oldest(BMembers, NTimers),
    BTimer = bucket_timer_from( BActive, BTimeout, LNRecent, NTimeout, Range),
    NewBTimers = timer_add(Range, BActive, BTimer, TmpBTimers),
    State#state { bucket_timers = NewBTimers }.

%% In the best case, the bucket should time out N seconds
%% after the first node in the bucket timed out. If that node
%% can't be replaced, a bucket refresh should be performed
%% at most every N seconds, based on when the bucket was last
%% marked as active, instead of _constantly_.
bucket_timer_from(Time, BTimeout, LeastRecent, _NTimeout, Range)
  when LeastRecent < Time ->
    timer_from(Time, BTimeout, {inactive_bucket, Range});
bucket_timer_from(Time, _BTimeout, LeastRecent, NTimeout, Range)
  when LeastRecent >= Time ->
    timer_from(LeastRecent, 2*NTimeout, {inactive_bucket, Range}).

timer_from(Time, Timeout, Msg) ->
    Interval = ms_between(Time, Timeout),
    erlang:send_after(Interval, self(), Msg).

ms_between(Time, Timeout) ->
    case Timeout - ms_since(Time) of
      MS when MS =< 0 -> Timeout;
      MS -> MS
    end.

ms_since(Time) ->
    timer:now_diff(Time, os:timestamp()) div 1000.

has_timed_out(Item, Timeout, TimerTree) ->
    {LastActive, _} = timer_get(Item, TimerTree),
    ms_since(LastActive) > Timeout.

%% initialize_timers/2 sets the initial timers for the state process
initialize_timers(Now, RoutingTbl) ->
    lists:foldl(
      fun (R, Acc) ->
        BTimer = bucket_timer_from(Now, node_timeout(), Now, bucket_timeout(), R),
        timer_add(R, Now, BTimer, Acc)
      end,
      timer_empty(),
      dht_routing_table:ranges(RoutingTbl)).

%%
%% TIMER TREE CODE
%%
%% This implements a timer tree as a gb_trees construction.
%% We just wrap the underlying representation a bit here.
%% --------------------------------------
timer_empty() ->
	gb_trees:empty().

timer_get(X, Timers) ->
	gb_trees:get(X, Timers).

timer_add(Item, ATime, TRef, Timers) ->
    TState = {ATime, TRef},
    gb_trees:insert(Item, TState, Timers).

timer_del(Item, Timers) ->
    {_, TRef} = timer_get(Item, Timers),
    _ = erlang:cancel_timer(TRef),
    gb_trees:delete(Item, Timers).

timer_oldest([], _) -> os:timestamp(); %% None available
timer_oldest(Items, TimerTree) ->
    ATimes = [element(1, timer_get(I, TimerTree)) || I <- Items],
    lists:min(ATimes).


%%
%% DISK STATE
%% ----------------------------------

dump_state(no_state_file, _) -> ok;
dump_state(Filename, RoutingTable) ->
    ok = file:write_file(Filename, dht_routing_table:to_binary(RoutingTable)).

load_state(RequestedNodeID, no_state_file) ->
	dht_routing_table:new(RequestedNodeID);
load_state(RequestedNodeID, Filename) ->
    case file:read_file(Filename) of
        {ok, BinState} ->
            dht_routing_table:from_binary(BinState);
        {error, enoent} ->
            dht_routing_table:new(RequestedNodeID)
    end.

%%
%% ROUTING TABLE
%%
%% When updating the routing table, one must also update the timer structures. These functions make sure both
%% happens in order.

rt_add_node(Node, Now, #state { node_timeout = NTimeout, node_timers = NTimers } = State) ->
    NTimer = node_timer_from(Now, NTimeout, Node),
    State#state {
    	node_timers = timer_add(Node, Now, NTimer, NTimers)
    }.

%% rt_add/2 attempts to add a node to the routing table
%% This function in particular makes sure it also gets node and bucket timers right and updated as well
rt_add(Node, #state { routing_table = Tbl } = State) ->
    Now = os:timestamp(),
    T = dht_routing_table:insert(Node, Tbl),
    case dht_routing_table:is_member(Node, T) of
       false ->
           %% No change. This is the easy case
           {not_inserted, State#state { routing_table = T }};
        true ->
            %% The next section here determines if there are changes to the bucket tree structure. And if there is,
            %% it reworks what timers should die, and what timers should be added by folding over the
            %% bucket structure.
            StateN = rt_add_node(Node, Now, State#state { routing_table = T }),
            {ok, rt_add_bucket(Tbl, Now, StateN)}
   end.

rt_add_bucket_update(Ops, Now,
	#state {
		node_timers = NTimers,
		bucket_timeout = BTimeout,
		bucket_timers = BTimers,
		routing_table = Tbl
	} = State) ->
    UpdatedBucketTimers = lists:foldl(
        fun
            ({del, R}, TM) -> timer_del(R, TM);
            ({add, R}, TM) ->
                Members = dht_routing_table:members(R, Tbl),
                Recent = timer_oldest(Members, NTimers),
                BT = bucket_timer_from(Now, BTimeout, Recent, NTimers, R),
                timer_add(R, Now, BT, TM)
        end,
        BTimers,
        Ops),
    State#state { bucket_timers = UpdatedBucketTimers }.

rt_add_bucket(OldTbl, Now, #state { routing_table = NewTbl } = State) ->
    PrevRanges = dht_routing_table:ranges(OldTbl),
    NewRanges = dht_routing_table:ranges(NewTbl),
    case PrevRanges /= NewRanges of
        false ->
            State#state { routing_table = NewTbl };
       true ->
           rt_add_bucket_update(
               [{del, R} || R <- ordsets:subtract(PrevRanges, NewRanges)] ++
               [{add, R} || R <- ordsets:subtract(NewRanges, PrevRanges)],
               Now,
               State)
    end.

%% routing_table_replace/3, Replaces an old node with a new one in the routing table
routing_table_replace(Old, New, State) ->
    Removed = rt_delete(Old, State),
    rt_add(New, Removed).

%% routing_table_delete/2 removes a node from the routing table, while maintaing timers
rt_delete(Node, #state { routing_table = Tbl, node_timers = Timers } = State) ->
    State#state {
    	routing_table = dht_routing_table:delete(Node, Tbl),
    	node_timers = timer_del(Node, Timers)
    }.


