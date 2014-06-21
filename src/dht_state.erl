%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc A Server for maintaining the the routing table in DHT
%%
%% @todo Document all exported functions.
%%
%% This module implements a server maintaining the
%% DHT routing table. The nodes in the routing table
%% is distributed across a set of buckets. The bucket
%% set is created incrementally based on the local node id.
%%
%% The set of buckets, id ranges, is used to limit
%% the number of nodes in the routing table. The routing
%% table must only contain ?K nodes that fall within the
%% range of each bucket.
%%
%% A node is considered disconnected if it does not respond to
%% a ping query after 10 minutes of inactivity. Inactive nodes
%% are kept in the routing table but are not propagated to
%% neighbouring nodes through responses through find_node
%% and get_peers responses.
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


-export([srv_name/0,
	 start_link/2,
	 node_id/0,
	 safe_insert_node/2,
	 safe_insert_node/3,
	 safe_insert_nodes/1,
	 unsafe_insert_node/3,
	 unsafe_insert_nodes/1,
	 is_interesting/3,
	 closest_to/1,
	 closest_to/2,
	 log_request_timeout/3,
	 log_request_success/3,
	 log_request_from/3,
	 keepalive/3,
	 refresh/3,
	 dump_state/0,
	 dump_state/1,
	 dump_state/3,
	 load_state/1]).

-type ipaddr() :: etorrent_types:ipaddr().
-type nodeid() :: etorrent_types:nodeid().
-type portnum() :: etorrent_types:portnum().
-type nodeinfo() :: etorrent_types:nodeinfo().

-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(state, {
    node_id :: nodeid(),
    buckets=dht_bucket:new(), % The actual routing table
    node_timers=timer_tree(), % Node activity times and timeout references
    buck_timers=timer_tree(),% Bucker activity times and timeout references
    node_timeout=10*60*1000,  % Default node keepalive timeout
    buck_timeout=5*60*1000,   % Default bucket refresh timeout
    state_file="/tmp/dht_state"}). % Path to persistent state
%
% The bucket refresh timeout is the amount of time that the
% server will tolerate a node to be disconnected before it
% attempts to refresh the bucket.
%

-include_lib("kernel/include/inet.hrl").

%
% The server has started to use integer IDs internally, before the
% rest of the program does that, run these functions whenever an ID
% enters or leaves this process.
%
ensure_bin_id(ID) when is_binary(ID)  -> ID.
ensure_int_id(ID) when is_integer(ID) -> ID.

srv_name() -> ?MODULE.

start_link(StateFile, BootstapNodes) ->
    gen_server:start_link({local, srv_name()},
			  ?MODULE,
			  [StateFile, BootstapNodes], []).


%% @doc Return a this node id as an integer.
%% Node ids are generated in a random manner.
-spec node_id() -> nodeid().
node_id() ->
    gen_server:call(srv_name(), {node_id}).

%
% Check if a node is available and lookup its node id by issuing
% a ping query to it first. This function must be used when we
% don't know the node id of a node.
%
-spec safe_insert_node(ipaddr(), portnum()) ->
    {'error', 'timeout'} | boolean().
safe_insert_node(IP, Port) ->
    case unsafe_ping(IP, Port) of
	pang -> {error, timeout};
	ID   -> unsafe_insert_node(ID, IP, Port)
    end.

%
% Check if a node is available and verify its node id by issuing
% a ping query to it first. This function must be used when we
% want to verify the identify and status of a node.
%
% This function will return {error, timeout} if the node is unreachable
% or has changed identity, false if the node is not interesting or wasnt
% inserted into the routing table, true if the node was interesting and was
% inserted into the routing table.
%
-spec safe_insert_node(nodeid(), ipaddr(), portnum()) ->
    {'error', 'timeout'} | boolean().
safe_insert_node(ID, IP, Port) ->
    case is_interesting(ID, IP, Port) of
	false -> false;
	true ->
	    % Since this clause will be reached every time this node
	    % receives a query from a node that is interesting, use the
	    % unsafe_ping function to avoid repeatedly issuing ping queries
	    % to nodes that won't reply to them.
	    case unsafe_ping(IP, Port) of
		ID   -> unsafe_insert_node(ID, IP, Port);
		pang -> {error, timeout};
		_    -> {error, timeout}
	end
    end.

-spec safe_insert_nodes(list(nodeinfo())) -> 'ok'.
safe_insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, safe_insert_node, [ID, IP, Port])
     || {ID, IP, Port} <- NodeInfos],
    ok.

%
% Blindly insert a node into the routing table. Use this function when
% inserting a node that was found and successfully queried in a find_node
% or get_peers search.
% This function returns a boolean value to indicate to the caller if the
% node was actually inserted into the routing table or not.
%
-spec unsafe_insert_node(nodeid(), ipaddr(), portnum()) ->
    boolean().
unsafe_insert_node(ID, IP, Port) when is_integer(ID) ->
    _WasInserted = gen_server:call(srv_name(), {insert_node, ID, IP, Port}).

-spec unsafe_insert_nodes(list(nodeinfo())) -> 'ok'.
unsafe_insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, unsafe_insert_node, [ID, IP, Port])
    || {ID, IP, Port} <- NodeInfos],
    ok.

%
% Check if node would fit into the routing table. This
% function is used by the safe_insert_node(s) function
% to avoid issuing ping-queries to every node sending
% this node a query.
%

-spec is_interesting(nodeid(), ipaddr(), portnum()) -> boolean().
is_interesting(ID, IP, Port) when is_integer(ID) ->
    gen_server:call(srv_name(), {is_interesting, ID, IP, Port}).

-spec closest_to(nodeid()) -> list(nodeinfo()).
closest_to(NodeID) ->
    closest_to(NodeID, 8).

-spec closest_to(nodeid(), pos_integer()) -> list(nodeinfo()).
closest_to(NodeID, NumNodes) ->
    gen_server:call(srv_name(), {closest_to, NodeID, NumNodes}).

-spec log_request_timeout(nodeid(), ipaddr(), portnum()) -> 'ok'.
log_request_timeout(ID, IP, Port) ->
    Call = {request_timeout, ID, IP, Port},
    gen_server:call(srv_name(), Call).

-spec log_request_success(nodeid(), ipaddr(), portnum()) -> 'ok'.
log_request_success(ID, IP, Port) ->
    Call = {request_success, ID, IP, Port},
    gen_server:call(srv_name(), Call).

-spec log_request_from(nodeid(), ipaddr(), portnum()) -> 'ok'.
log_request_from(ID, IP, Port) ->
    Call = {request_from, ID, IP, Port},
    gen_server:call(srv_name(), Call).

dump_state() ->
    gen_server:call(srv_name(), {dump_state}).

dump_state(Filename) ->
    gen_server:call(srv_name(), {dump_state, Filename}).

-spec keepalive(nodeid(), ipaddr(), portnum()) -> 'ok'.
keepalive(ID, IP, Port) ->
    case safe_ping(IP, Port) of
	ID    -> log_request_success(ID, IP, Port);
	pang  -> log_request_timeout(ID, IP, Port);
	_     -> log_request_timeout(ID, IP, Port)
    end.

spawn_keepalive(ID, IP, Port) ->
    spawn(?MODULE, keepalive, [ID, IP, Port]).

%
% Issue a ping query to a node, this function should always be used
% when checking if a node that is already a member of the routing table
% is online.
%
-spec safe_ping(IP::ipaddr(), Port::portnum()) -> pang | nodeid().
safe_ping(IP, Port) ->
    dht_net:ping(IP, Port).

%
% unsafe_ping overrides the behaviour of dht_net:ping/2 by
% avoiding to issue ping queries to nodes that are unlikely to
% be reachable. If a node has not been queried before, a safe_ping
% will always be performed.
%
% Returns pand, if the node is unreachable.
-spec unsafe_ping(IP::ipaddr(), Port::portnum()) -> pang | nodeid().
unsafe_ping(IP, Port) ->
    case ets:member(unreachable_tab(), {IP, Port}) of
	true ->
	    pang;
	false ->
	    case safe_ping(IP, Port) of
		pang ->
		    RandNode = random_node_tag(),
		    DelSpec = [{{'_', RandNode}, [], [true]}],
		    _ = ets:select_delete(unreachable_tab(), DelSpec),
		    ok = lager:debug("~p:~p is unreachable.", [IP, Port]),
		    ets:insert(unreachable_tab(), {{IP, Port}, RandNode}),
		    pang;
		NodeID ->
		    NodeID
	    end
    end.

%
% Refresh the contents of a bucket by issuing find_node queries to each node
% in the bucket until enough nodes that falls within the range of the bucket
% has been returned to replace the inactive nodes in the bucket.
%
-spec refresh(any(), list(nodeinfo()), list(nodeinfo())) -> 'ok'.
refresh(Range, Inactive, Active) ->
    % Try to refresh the routing table using the inactive nodes first,
    % If they turn out to be reachable the problem's solved.
    do_refresh(Range, Inactive ++ Active, []).

do_refresh(_, [], _) ->
    ok; % @todo - perform a find_node_search here?
do_refresh(Range, [{ID, IP, Port}|T], IDs) ->
    Continue = case dht_net:find_node(IP, Port, ID) of
	{error, timeout} ->
	    true;
	{_, CloseNodes} ->
	    do_refresh_inserts(Range, CloseNodes)
    end,
    case Continue of
	false -> ok;
	true  -> do_refresh(Range, T, [ID|IDs])
    end.

do_refresh_inserts({_, _}, []) ->
    true;
do_refresh_inserts({Min, Max}=Range, [{ID, IP, Port}|T])
when ?in_range(ID, Min, Max) ->
    case safe_insert_node(ID, IP, Port) of
	{error, timeout} ->
	    do_refresh_inserts(Range, T);
	true ->
	    do_refresh_inserts(Range, T);
	false ->
	    safe_insert_nodes(T),
	    false
    end;

do_refresh_inserts(Range, [{ID, IP, Port}|T]) ->
    _ = safe_insert_node(ID, IP, Port),
    do_refresh_inserts(Range, T).

spawn_refresh(Range, InputInactive, InputActive) ->
    Inactive = [{ensure_bin_id(ID), IP, Port}
	       || {ID, IP, Port} <- InputInactive],
    Active   = [{ensure_bin_id(ID), IP, Port}
	       || {ID, IP, Port} <- InputActive],
    spawn(?MODULE, refresh, [Range, Inactive, Active]).


max_unreachable() ->
    128.

unreachable_tab() ->
    dht_unreachable_cache_tab.

random_node_tag() ->
    _ = random:seed(erlang:now()),
    random:uniform(max_unreachable()).

%% @private
init([StateFile, BootstapNodes]) ->
    % Initialize the table of unreachable nodes when the server is started.
    % The safe_ping and unsafe_ping functions aren't exported outside of
    % of this module so they should fail unless the server is not running.
    _ = case ets:info(unreachable_tab()) of
	undefined ->
	    ets:new(unreachable_tab(), [named_table, public, bag]);
	_ -> ok
    end,


    {NodeID, NodeList} = load_state(StateFile),

    [spawn_link(fun() -> safe_insert_node(BN) end) || BN <- BootstapNodes],

    % Insert any nodes loaded from the persistent state later
    % when we are up and running. Use unsafe insertions or the
    % whole state will be lost if etorrent starts without
    % internet connectivity.
    [spawn(?MODULE, unsafe_insert_node, [ensure_bin_id(ID), IP, Port])
    || {ID, IP, Port} <- NodeList],

    #state{
	buckets=Buckets,
	buck_timers=InitBTimers,
	node_timeout=NTimeout,
	buck_timeout=BTimeout} = #state{},

    Now = os:timestamp(),
    BTimers = lists:foldl(fun(Range, Acc) ->
	BTimer = bucket_timer_from(Now, NTimeout, Now, BTimeout, Range),
	add_timer(Range, Now, BTimer, Acc)
    end, InitBTimers, dht_bucket:ranges(Buckets)),

    State = #state{
	node_id=ensure_int_id(NodeID),
	buck_timers=BTimers,
	state_file=StateFile},
    {ok, State}.

%% @private
handle_call({is_interesting, InputID, IP, Port}, _From, State) ->
    ID = ensure_int_id(InputID),
    #state{
	node_id=Self,
	buckets=Buckets,
	node_timeout=NTimeout,
	node_timers=NTimers} = State,
    IsInteresting = case dht_bucket:is_member(ID, IP, Port, Self, Buckets) of
	true -> false;
	false ->
	    BMembers = dht_bucket:members(ID, Self, Buckets),
	    Inactive = inactive_nodes(BMembers, NTimeout, NTimers),
	    case (Inactive =/= []) or (length(BMembers) < ?K) of
		true -> true;
		false ->
		    TryBuckets = dht_bucket:insert(Self, ID, IP, Port, Buckets),
		    dht_bucket:is_member(ID, IP, Port, Self, TryBuckets)
	    end
    end,
    {reply, IsInteresting, State};

handle_call({insert_node, InputID, IP, Port}, _From, State) ->
    ID   = ensure_int_id(InputID),
    Now  = os:timestamp(),
    Node = {ID, IP, Port},
    #state{
	node_id=Self,
	buckets=PrevBuckets,
	node_timers=PrevNTimers,
	buck_timers=PrevBTimers,
	node_timeout=NTimeout,
	buck_timeout=BTimeout} = State,

    IsPrevMember = dht_bucket:is_member(ID, IP, Port, Self, PrevBuckets),
    Inactive = case IsPrevMember of
	true  -> [];
	false ->
	    PrevBMembers = dht_bucket:members(ID, Self, PrevBuckets),
	    inactive_nodes(PrevBMembers, NTimeout, PrevNTimers)
    end,

    {NewBuckets, Replace} = case {IsPrevMember, Inactive} of
	{true, _} ->
	    % If the node is already a member of the node set,
	    % don't change a thing
	    {PrevBuckets, none};

	{false, []} ->
	    % If there are no disconnected nodes in the bucket
	    % insert it anyways and check later if it was actually added
	    {dht_bucket:insert(Self, ID, IP, Port, PrevBuckets), none};

	{false, [{OID, OIP, OPort}=Old|_]} ->
	    % If there is one or more disconnected nodes in the bucket
	    % Remove the old one and insert the new node.
	    TmpBuckets = dht_bucket:delete(OID, OIP, OPort, Self, PrevBuckets),
	    {dht_bucket:insert(Self, ID, IP, Port, TmpBuckets), Old}
    end,

    % If the new node replaced a new, remove all timer and access time
    % information from the state
    TmpNTimers = case Replace of
	none ->
	    PrevNTimers;
	{_, _, _}=DNode ->
	    del_timer(DNode, PrevNTimers)
    end,



    IsNewMember = dht_bucket:is_member(ID, IP, Port, Self, NewBuckets),
    NewNTimers  = case {IsPrevMember, IsNewMember} of
	{false, false} ->
	    TmpNTimers;
	{true, true} ->
	    TmpNTimers;
	{false, true}  ->
	    NTimer = node_timer_from(Now, NTimeout, Node),
	    add_timer(Node, Now, NTimer, TmpNTimers)
    end,

    NewBTimers = case {IsPrevMember, IsNewMember} of
	{false, false} ->
	    PrevBTimers;
	{true, true} ->
	    PrevBTimers;

	{false, _} ->
	    AllPrevRanges = dht_bucket:ranges(PrevBuckets),
	    AllNewRanges  = dht_bucket:ranges(NewBuckets),
	    %% route table can be splitted but node's bucket can remain full,
	    %% so we can get new bucket but node was not inserted
	    if length(AllPrevRanges) /= length(AllNewRanges) ->
		DelRanges  = ordsets:subtract(AllPrevRanges, AllNewRanges),
		NewRanges  = ordsets:subtract(AllNewRanges, AllPrevRanges),

		DelBTimers = lists:foldl(fun(Range, Acc) ->
		    del_timer(Range, Acc)
		end, PrevBTimers, DelRanges),

		lists:foldl(fun(Range, Acc) ->
		    BMembers = dht_bucket:members(Range, Self, NewBuckets),
		    LRecent = least_recent(BMembers, NewNTimers),
		    BTimer = bucket_timer_from(
				 Now, BTimeout, LRecent, NTimeout, Range),
		    add_timer(Range, Now, BTimer, Acc)
			    end, DelBTimers, NewRanges);
		   true ->
			PrevBTimers
	    end
    end,
    NewState = State#state{
	buckets=NewBuckets,
	node_timers=NewNTimers,
	buck_timers=NewBTimers},
    {reply, ((not IsPrevMember) and IsNewMember), NewState};




handle_call({closest_to, InputID, NumNodes}, _, State) ->
    ID = ensure_int_id(InputID),
    #state{
	node_id=Self,
	buckets=Buckets,
	node_timers=NTimers,
	node_timeout=NTimeout} = State,
    NF = fun (N) -> not has_timed_out(N, NTimeout, NTimers) end,
    CloseNodes = dht_bucket:closest_to(ID, Self, Buckets, NF, NumNodes),
    {reply, CloseNodes, State};


handle_call({request_timeout, InputID, IP, Port}, _, State) ->
    ID   = ensure_int_id(InputID),
    Node = {ID, IP, Port},
    Now  = os:timestamp(),
    #state{
	node_id=Self,
	buckets=Buckets,
	node_timeout=NTimeout,
	node_timers=PrevNTimers} = State,

    NewNTimers = case dht_bucket:is_member(ID, IP, Port, Self, Buckets) of
	false ->
	    PrevNTimers;
	true ->
	    {LActive, _} = get_timer(Node, PrevNTimers),
	    TmpNTimers   = del_timer(Node, PrevNTimers),
	    NTimer       = node_timer_from(Now, NTimeout, Node),
	    add_timer(Node, LActive, NTimer, TmpNTimers)
    end,
    NewState = State#state{node_timers=NewNTimers},
    {reply, ok, NewState};

handle_call({request_success, InputID, IP, Port}, _, State) ->
    ID   = ensure_int_id(InputID),
    Now  = os:timestamp(),
    Node = {ID, IP, Port},
    #state{
	node_id=Self,
	buckets=Buckets,
	node_timers=PrevNTimers,
	buck_timers=PrevBTimers,
	node_timeout=NTimeout,
	buck_timeout=BTimeout} = State,
    NewState = case dht_bucket:is_member(ID, IP, Port, Self, Buckets) of
	false ->
	    State;
	true ->
	    Range = dht_bucket:range(ID, Self, Buckets),

	    {NLActive, _} = get_timer(Node, PrevNTimers),
	    TmpNTimers    = del_timer(Node, PrevNTimers),
	    NTimer	= node_timer_from(Now, NTimeout, Node),
	    NewNTimers    = add_timer(Node, NLActive, NTimer, TmpNTimers),

	    {BActive, _} = get_timer(Range, PrevBTimers),
	    TmpBTimers   = del_timer(Range, PrevBTimers),
	    BMembers     = dht_bucket:members(Range, Self, Buckets),
	    LNRecent     = least_recent(BMembers, NewNTimers),
	    BTimer       = bucket_timer_from(
			       BActive, BTimeout, LNRecent, NTimeout, Range),
	    NewBTimers    = add_timer(Range, BActive, BTimer, TmpBTimers),

	    State#state{
		node_timers=NewNTimers,
		buck_timers=NewBTimers}
    end,
    {reply, ok, NewState};


handle_call({request_from, ID, IP, Port}, From, State) ->
    handle_call({request_success, ID, IP, Port}, From, State);

handle_call({dump_state}, _From, State) ->
    #state{
	node_id=Self,
	buckets=Buckets,
	state_file=StateFile} = State,
    catch dump_state(StateFile, Self, dht_bucket:node_list(Buckets)),
    {reply, State, State};

handle_call({dump_state, StateFile}, _From, State) ->
    #state{
	node_id=Self,
	buckets=Buckets} = State,
    catch dump_state(StateFile, Self, dht_bucket:node_list(Buckets)),
    {reply, ok, State};

handle_call({node_id}, _From, State) ->
    #state{node_id=Self} = State,
    {reply, ensure_int_id(Self), State}.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
handle_info({inactive_node, InputID, IP, Port}, State) ->
    ID = ensure_int_id(InputID),
    Now = os:timestamp(),
    Node = {ID, IP, Port},
    #state{
	node_id=Self,
	buckets=Buckets,
	node_timers=PrevNTimers,
	node_timeout=NTimeout} = State,

    IsMember = dht_bucket:is_member(ID, IP, Port, Self, Buckets),
    HasTimed = case IsMember of
	false -> false;
	true  -> has_timed_out(Node, NTimeout, PrevNTimers)
    end,
    NewState = case IsMember of
		   false ->
		       State;
		   true ->
		       if HasTimed ->
			       ok = lager:debug("Node at ~w:~w timed out", [IP, Port]),
			       spawn_keepalive(ID, IP, Port);
			  true ->
			       ok
		       end,
		       {LActive, TRef} = get_timer(Node, PrevNTimers),
		       TimerCanceled = erlang:read_timer(TRef) == false,
		       if (TimerCanceled orelse HasTimed) ->
			       TmpNTimers  = del_timer(Node, PrevNTimers),
			       NewTimer    = node_timer_from(Now, NTimeout, Node),
			       NewNTimers  = add_timer(Node, LActive, NewTimer, TmpNTimers),
			       State#state{node_timers=NewNTimers};
			  true ->
			       State
		       end
	       end,
    {noreply, NewState};

handle_info({inactive_bucket, Range}, State) ->
    Now = os:timestamp(),
    #state{
	node_id=Self,
	buckets=Buckets,
	node_timers=NTimers,
	buck_timers=PrevBTimers,
	node_timeout=NTimeout,
	buck_timeout=BTimeout} = State,

    BucketExists = dht_bucket:has_bucket(Range, Buckets),
    HasTimed = case BucketExists of
	false -> false;
	true  -> has_timed_out(Range, BTimeout, PrevBTimers)
    end,
    NewState = case BucketExists of
		   false ->
		       State;
		   true ->
		       BMembers   = dht_bucket:members(Range, Self, Buckets),
		       if HasTimed ->
			       ok = lager:debug("Bucket timed out"),
			       _ = spawn_refresh(Range,
						 inactive_nodes(BMembers, NTimeout, NTimers),
						 active_nodes(BMembers, NTimeout, NTimers));
			  true ->
			       ok
		       end,
		       {_, TRef} = get_timer(Range, PrevBTimers),
		       TimerCanceled = erlang:read_timer(TRef) == false,
		       if (TimerCanceled orelse HasTimed) ->
			       TmpBTimers = del_timer(Range, PrevBTimers),
			       LRecent    = least_recent(BMembers, NTimers),
			       NewTimer   = bucket_timer_from(
					      Now, BTimeout, LRecent, NTimeout, Range),
			       NewBTimers = add_timer(Range, Now, NewTimer, TmpBTimers),
			       State#state{buck_timers=NewBTimers};
			  true ->
			       State
		       end
	       end,
    {noreply, NewState}.

%% @private
terminate(_, State) ->
    #state{
	node_id=Self,
	buckets=Buckets,
	state_file=StateFile} = State,
    dump_state(StateFile, Self, dht_bucket:node_list(Buckets)).

dump_state(Filename, Self, NodeList) ->
    PersistentState = [{node_id, Self}, {node_set, NodeList}],
    file:write_file(Filename, term_to_binary(PersistentState)).

load_state(Filename) ->
    ErrorFmt = "Failed to load state from ~s (~w)",
    case file:read_file(Filename) of
	{ok, BinState} ->
	    case (catch load_state_(BinState)) of
		{'EXIT', Reason}  ->
		    ErrorArgs = [Filename, Reason],
		    ok = lager:error(ErrorFmt, ErrorArgs),
		    {dht:random_id(), []};
		{_, _}=State ->
		    ok = lager:info("Loaded state from ~s", [Filename]),
		    State
	    end;
	{error, Reason} ->
	    ErrorArgs = [Filename, Reason],
	    ok = lager:error(ErrorFmt, ErrorArgs),
	    {dht:random_id(), []}
    end.

load_state_(BinState) ->
    PersistentState = binary_to_term(BinState),
    {value, {_, Self}}  = lists:keysearch(node_id, 1, PersistentState),
    {value, {_, Nodes}} = lists:keysearch(node_set, 1, PersistentState),
    {Self, Nodes}.


%% @private
code_change(_, State, _) ->
    {ok, State}.


inactive_nodes(Nodes, Timeout, Timers) ->
    [N || N <- Nodes, has_timed_out(N, Timeout, Timers)].

active_nodes(Nodes, Timeout, Timers) ->
    [N || N <- Nodes, not has_timed_out(N, Timeout, Timers)].

timer_tree() ->
	gb_trees:empty().

get_timer(Item, Timers) ->
	gb_trees:get(Item, Timers).

add_timer(Item, ATime, TRef, Timers) ->
    TState = {ATime, TRef},
    gb_trees:insert(Item, TState, Timers).

del_timer(Item, Timers) ->
    {_, TRef} = get_timer(Item, Timers),
    _ = erlang:cancel_timer(TRef),
    gb_trees:delete(Item, Timers).

node_timer_from(Time, Timeout, {ID, IP, Port}) ->
    Msg = {inactive_node, ID, IP, Port},
    timer_from(Time, Timeout, Msg).

bucket_timer_from(Time, BTimeout, LeastRecent, NTimeout, Range) ->
    % In the best case, the bucket should time out N seconds
    % after the first node in the bucket timed out. If that node
    % can't be replaced, a bucket refresh should be performed
    % at most every N seconds, based on when the bucket was last
    % marked as active, instead of _constantly_.
    Msg = {inactive_bucket, Range},
    if
	LeastRecent <  Time ->
	    timer_from(Time, BTimeout, Msg);
	LeastRecent >= Time ->
	    SumTimeout = NTimeout + NTimeout,
	    timer_from(LeastRecent, SumTimeout, Msg)
    end.


timer_from(Time, Timeout, Msg) ->
    Interval = ms_between(Time, Timeout),
    erlang:send_after(Interval, self(), Msg).

ms_since(Time) ->
    timer:now_diff(Time, os:timestamp()) div 1000.

ms_between(Time, Timeout) ->
    MS = Timeout - ms_since(Time),
    if MS =< 0 -> Timeout;
       MS >= 0 -> MS
    end.

has_timed_out(Item, Timeout, Times) ->
    {LastActive, _} = get_timer(Item, Times),
    ms_since(LastActive) > Timeout.

least_recent([], _) ->
    os:timestamp();
least_recent(Items, Times) ->
    ATimes = [element(1, get_timer(I, Times)) || I <- Items],
    lists:min(ATimes).

safe_insert_node(NodeAddr) ->
    Addrs = decode_node_address(NodeAddr),
    safe_insert_node_oneof(Addrs).


%% Try to connect to the node, using different addresses.
safe_insert_node_oneof([{IP, Port}|Addrs]) ->
    case safe_insert_node(IP, Port) of
	true -> true;
	false -> safe_insert_node_oneof(Addrs);
	{error, timeout} -> safe_insert_node_oneof(Addrs)
    end;
safe_insert_node_oneof([]) ->
    false.


%-spec decode_node_address(NodeAddr::term()) -> [{IP, Port}].
decode_node_address({{_,_,_,_}, _}=NodeAddr) ->
    [NodeAddr];
decode_node_address([_|_]=NodeAddr) ->
    {Addr, Port} = parse_address(NodeAddr),
    IPs = dns_lookup(Addr),
    [{IP, Port} || IP <- IPs].


%% Parses IP address or DNS-name and an optional port.
%% [1080:0:0:0:8:800:200C:417A]:180
%% [1080:0:0:0:8:800:200C:417A]
%% router.example.com
%% 127.0.0.1
-spec parse_address(Addr::string()) -> {string(), non_neg_integer()}.
parse_address(Addr) ->
    %% re:run("[1080:0:0:0:8:800:200C:417A]:180$", "(.*):(\\d+)$", [{capture, all_but_first, list}])
    %% {match,["[1080:0:0:0:8:800:200C:417A]","180"]}
    %% re:run("[1080:0:0:0:8:800:200C:417A]", "(.*):(\\d+)$", [{capture, all_but_first, list}])
    %% nomatch
    case re:run(Addr, "(.*):(\\d+)$", [{capture, all_but_first, list}]) of
	{match, [Host, Port]} -> {Host, list_to_integer(Port)};
	nomatch	       -> {Addr, 6881}
    end.


dns_lookup(Addr) ->
    %% inet:gethostbyname("8.8.8.8").
    %% {ok,{hostent,"8.8.8.8",[],inet,4,[{8,8,8,8}]}}
    %% inet:gethostbyname("8.8.8.8").
    %% {ok,{hostent,"8.8.8.8",[],inet,4,[{8,8,8,8}]}}
    case inet_res:gethostbyname(Addr) of
	{ok, #hostent{h_addr_list=IPs}} -> IPs;
	{error, Reason} ->
	    ok = lager:error("Cannot lookup address ~p because ~p.", [Addr, Reason]),
	    []
    end.
