%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc A Server for maintaining the the routing table in DHT
%%
%% @todo Document all exported functions.
%%
%% This module implements the higher-level logic of the DHT
%% routing table. The idea is to split the routing table code over
%% 3 modules:
%%
%%  * The routing table itself - In dht_routing_table
%%  * The set of timers for node/range refreshes - In dht_routing
%%  * The policy rules for what to do - In dht_state (this file)
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
%% A range is refreshed once the least recently active node
%% has been inactive for 5 minutes. If a replacement for the
%% least recently active node can't be replaced, the server
%% should wait at least 5 minutes before attempting to find
%% a replacement again.
%%
%% The timeouts (expiry times) in this server is managed
%% using a pair containg the time that a node/range was
%% last active and a reference to the currently active timer.
%% (see dht_routing)
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

-include_lib("kernel/include/inet.hrl").

%% Lifetime
-export([
	start_link/2, start_link/3,
	load_state/2,
	dump_state/0, dump_state/1, dump_state/2
]).

%% Manipulation
-export([
	insert_node/1,
	insert_nodes/1,
	notify/2,
	ping/2, ping/3
]).

%% Query
-export([
	 closest_to/1, closest_to/2,
	 keepalive/1,
	 node_id/0,
	 node_list/0,
	 refresh/3
]).

-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-define(K, 8).
-define(in_range(Dist, Min, Max), ((Dist >= Min) andalso (Dist < Max))).
-define(MAX_UNREACHABLE, 128).
-define(UNREACHABLE_TAB, dht_state_unreachable).

-record(state, {
    node_id :: dht:node_id(), % ID of this node
    routing = dht_routing_timing:empty(), % Routing table and timing structure
    state_file="/tmp/dht_state" :: string() % Path to persistent state
}).

%% Helper for calling
call(X) -> gen_server:call(?MODULE, X).

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

%% @doc node_list/0 returns the list of nodes in the current routing table
%% @end
-spec node_list() -> [dht:node_t()].
node_list() -> call(node_list).

%%
%% @doc insert_node/1 inserts a new node according to the options given
%%
%% There are two variants of this function:
%% * If inserting {IP, Port} a ping will first be made to make sure the node is alive and find its ID
%% * If inserting {ID, IP, Port}, then a ping is first made to make sure the node exists
%% @end
-spec insert_node(Node) -> true | false | {error, Reason}
  when
      Node :: dht:node_t() | {inet:ip_address(), inet:port_number()},
      Reason :: atom().
insert_node({IP, Port}) ->
	case ping(IP, Port, #{ unreachable_check => true}) of
	    pang -> {error, timeout};
	    ID -> call({insert_node, {ID, IP, Port}})
	end;
insert_node(Node) ->
	insert_node_interesting(Node, is_interesting(Node)).

insert_node_interesting({_, _, _}, false) -> false;
insert_node_interesting({ID, IP, Port}, true) ->
	case ping(IP, Port, #{ unreachable_check => true}) of
		pang -> {error, timeout};
		{ok, ID} ->
			call({insert_node, {ID, IP, Port}});
		_WrongID ->
			{error, inconsistent_id}
	end.

%% @doc insert_nodes/1 inserts a list of nodes into the routing table asynchronously
%% @end
-spec insert_nodes([dht:node_t()]) -> ok.
insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, insert_node, [Node]) || Node <- NodeInfos],
    ok.

%% @doc is_interesting/1 returns true if a node can enter the routing table, false otherwise
%% Check if node would fit into the routing table. This function is used by the insert_node
%% function to avoid issuing ping-queries to every node sending this node a query
%% @end
-spec is_interesting(dht:node_t()) -> boolean().
is_interesting({_, _, _} = Node) -> call({is_interesting, Node}).

%% @equiv closest_to(NodeID, 8)
-spec closest_to(dht:node_id()) -> list(dht:node_t()).
closest_to(NodeID) -> closest_to(NodeID, 8).

%% @doc closest_to/2 returns the neighborhood around an ID known to the routing table
%% @end
-spec closest_to(dht:node_id(), pos_integer()) -> list(dht:node_t()).
closest_to(NodeID, NumNodes) ->
    call({closest_to, NodeID, NumNodes}).

%% @doc notify/2 notifies the routing table of an event on a given node
%% Possible events are one of `request_timeout', `request_timeout', or `request_success'.
%% @end
-spec notify(Node, Event) -> ok
    when
      Node :: dht:node_t(),
      Event :: request_success | request_from | request_timeout.
notify(Node, request_success) -> request_success(Node);
notify(Node, request_timeout) -> request_timeout(Node);
notify(Node, request_from) -> request_from(Node).

request_success(Node) -> call({notify, request_success, Node}).
request_timeout(Node) -> call({notify, request_timeout, Node}).
request_from(Node) -> call({notify, request_from, Node}).

%% @doc dump_state/0 dumps the routing table state to disk
%% @end
dump_state() ->
    call(dump_state).

%% @doc dump_state/1 dumps the routing table state to disk into a given file
%% @end
dump_state(Filename) ->
    call({dump_state, Filename}).

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

    %% Initialize the table of unreachable nodes when the server is started.
    %% The safe_ping and unsafe_ping functions aren't exported outside of
    %% of this module so they should fail unless the server is not running.
    _ = ets:new(?UNREACHABLE_TAB, [named_table, public, bag]),

    RoutingTbl = load_state(RequestedNodeID, StateFile),
    
    %% @todo, consider just folding over these as well rather than a background insert.
    insert_nodes(BootstrapNodes),
    
    {ok, ID, Routing} = dht_routing:new(RoutingTbl),
    {ok, #state { node_id = ID, routing = Routing}}.

%% @private
handle_call({insert_node, Node}, _From, #state { routing = Routing } = State) ->
    case dht_routing:insert(Node, Routing) of
      {ok, R} -> {reply, true, State#state { routing = R }};
      {already_member, R} -> {reply, false, State#state { routing = R }};
      {not_inserted, R} -> {reply, false, State#state { routing = R }}
    end;
handle_call({is_interesting, Node}, _From, #state{ routing = Routing } = State) ->
    case dht_routing:is_member(Node, Routing) of
        true -> {reply, false, State}; % Already a member, the ID is not interesting
        false ->
            RangeMembers = dht_routing:range_members(Node, Routing),
            Inactive = dht_routing:inactive(RangeMembers, nodes, Routing) /= [],
            case Inactive orelse (length(RangeMembers) < ?K) of
                true -> {reply, true, State}; % either inactivity or there is too few members
                false ->
                    {reply, dht_routing:can_insert(Node, Routing), State}
            end
    end;
handle_call({closest_to, ID, NumNodes}, _From, #state{routing = Routing } = State) ->
    Neighbors = dht_routing:neighbors(ID, NumNodes, Routing),
    {reply, Neighbors, State};
handle_call({notify, request_timeout, Node}, _From,
	        #state{ routing = Routing } = State) ->
    case dht_routing:is_member(Node, Routing) of
        false -> {reply, ok, State};
        true ->
            R = dht_routing:refresh_node(Node, Routing),
            {reply, ok, State#state { routing = R }}
    end;
handle_call({notify, request_success, Node}, _From, #state{ routing = Routing } = State) ->
    case dht_routing:is_member(Node, Routing) of
	    false -> {reply, ok, State};
	    true ->
	        R = dht_routing:refresh_range_by_node(Node,
	                  dht_routing:refresh_node(Node, Routing)),
	        {reply, ok, State#state { routing = R }}
    end;
handle_call({notify, request_from, Node}, From, State) ->
    handle_call({notify, request_success, Node}, From, State);
handle_call(dump_state, From, #state{ state_file = StateFile } = State) ->
    handle_call({dump_state, StateFile}, From, State);
handle_call({dump_state, StateFile}, _From, #state{ routing = Routing } = State) ->
    try
        Tbl = dht_routing:export(Routing),
        dump_state(StateFile, Tbl),
        {reply, ok, State}
    catch
      Class:Err ->
        {reply, {error, {dump_state_failed, Class, Err}}, State}
    end;
handle_call(node_list, _From, #state { routing = Routing } = State) ->
    {reply, dht_routing:node_list(Routing), State};
handle_call(node_id, _From, #state{ node_id = Self } = State) ->
    {reply, Self, State}.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
%% The timers {inactive_node, Node} and {inactive_range, Range} is set by the
%% dht_routing module
handle_info({inactive_node, Node}, #state { routing = Routing } = State) ->
    case dht_routing:node_timer_state(Node, Routing) of
        ok -> {noreply, State};
        not_member -> {noreply, State};
        canceled ->
            R = dht_routing:refresh_node(Node, Routing),
            {noreply, State#state { routing = R }};
        timeout ->
            spawn(?MODULE, keepalive, [Node]),
            {noreply, State}
    end;
handle_info({inactive_bucket, Range}, #state{ routing = Routing } = State) ->
    R = case dht_routing:range_timer_state(Range, Routing) of
        ok -> Routing;
        not_member -> Routing;
        canceled ->
            dht_routing:refresh_range(Range, dht_time:monotonic_time(), Routing);
        timeout ->
            #{ inactive := Inactive, active := Active } =
              dht_routing:range_state(Range, Routing),
            spawn(?MODULE, refresh, [Range, Inactive, Active]),
            dht_routing:refresh_range(Range, dht_time:monotonic_time(), Routing)
    end,
    {noreply, State#state { routing = R }};
handle_info({stop, Caller}, #state{} = State) ->
	Caller ! stopped,
	{stop, normal, State}.

%% @private
terminate(_, #state{ routing = Routing, state_file=StateFile}) ->
	dump_state(StateFile, dht_routing:export(Routing)).

%% @private
code_change(_, State, _) ->
    {ok, State}.

%%
%% INTERNAL FUNCTIONS
%%
random_node_tag() ->
    _ = random:seed(erlang:timestamp()),
    random:uniform(?MAX_UNREACHABLE).

%%
%% DISK STATE
%% ----------------------------------

dump_state(no_state_file, _) -> ok;
dump_state(Filename, RoutingTable) ->
    ok = file:write_file(Filename, term_to_binary(RoutingTable, [compressed])).

load_state(RequestedNodeID, no_state_file) ->
	dht_routing_table:new(RequestedNodeID);
load_state(RequestedNodeID, Filename) ->
    case file:read_file(Filename) of
        {ok, BinState} ->
            binary_to_term(BinState);
        {error, enoent} ->
            dht_routing_table:new(RequestedNodeID)
    end.
