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
%%  * The set of timer meta-data for node/range refreshes - In dht_routing_meta
%%  * The policy rules for what to do - In dht_state (this file)
%% 
%% This modules main responsibility is to call out to helper modules
%% and make sure to maintain consistency of the above three states
%% we maintain.
%%
%% Many of the calls in this module will block for a while if called. The reason is
%% that the calling process handles network blocking calls for the gen_server
%% that runs the dht_state routing table. That is, a response from the routing
%% table may be to execute a network call, and then the caller awaits the
%% completion of that network call.
%%
%% @end
-module(dht_state).
-behaviour(gen_server).

-include("dht_constants.hrl").
-include_lib("kernel/include/inet.hrl").

%% Lifetime
-export([
	start_link/2, start_link/3,
	dump_state/0, dump_state/1,
	sync/2
]).

%% Query
-export([
	closest_to/1, closest_to/2,
	node_id/0
]).

%% Manipulation
-export([
	insert_node/1,
	request_success/2,
	request_timeout/1

]).

%% Internal API
-export([
	refresh_node/1,
	refresh_range/1
]).

-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(state, {
    node_id :: dht:node_id(), % ID of this node
    routing = dht_routing_timing:empty(), % Routing table and timing structure
    monitors = [] :: [reference()],
    syncers = [] :: [{pid(), reference()}],
    state_file="/tmp/dht_state" :: string() % Path to persistent state
}).

%% LIFETIME MAINTENANCE
%% ----------------------------------------------------------
start_link(StateFile, BootstrapNodes) ->
	start_link(dht_metric:mk(), StateFile, BootstrapNodes).
	
start_link(RequestedID, StateFile, BootstrapNodes) ->
    gen_server:start_link({local, ?MODULE},
			  ?MODULE,
			  [RequestedID, StateFile, BootstrapNodes], []).

%% @doc dump_state/0 dumps the routing table state to disk
%% @end
dump_state() ->
    call(dump_state).

%% @doc dump_state/1 dumps the routing table state to disk into a given file
%% @end
dump_state(Filename) ->
    call({dump_state, Filename}).

%% PUBLIC API
%% ----------------------------------------------------------
%% Helper for calling
call(X) -> gen_server:call(?MODULE, X).

%% QUERIES 
%% -----------

%% @equiv closest_to(NodeID, ?MAX_RANGE_SZ)
-spec closest_to(dht:node_id()) -> list(dht:node_t()).
closest_to(NodeID) -> closest_to(NodeID, ?MAX_RANGE_SZ).

%% @doc closest_to/2 returns the neighborhood around an ID known to the routing table
%% @end
-spec closest_to(dht:node_id(), pos_integer()) -> list(dht:node_t()).
closest_to(NodeID, NumNodes) ->
    call({closest_to, NodeID, NumNodes}).

%% @doc Return this node id as an integer.
%% Node ids are generated in a random manner.
-spec node_id() -> dht:node_id().
node_id() ->
    gen_server:call(?MODULE, node_id).

%% OPERATIONS WHICH CHANGE STATE
%% ------------------------------

%%
%% @doc insert_node/1 inserts a new node according to the options given
%%
%% There are two variants of this function:
%% * If inserting {IP, Port} a ping will first be made to make sure the node is
%%   alive and find its ID
%% * If inserting {ID, IP, Port}, it is assumed it is a valid node.
%%
%% The call may block for a while when inserting since the call may need to refresh
%% a bucket when the insert happens. This in turns means the caller is blocked while
%% this operation completes.
%%
%% @end
-spec insert_node(Node) -> ok | already_member | range_full | {error, Reason}
  when
      Node :: dht:peer() | {inet:ip_address(), inet:port_number()},
      Reason :: atom().
insert_node({IP, Port}) ->
    case dht_net:ping({IP, Port}) of
        pang -> {error, noreply};
        {ok, ID} -> insert_node({ID, IP, Port})
    end;
insert_node({_ID, _IP, _Port} = Node) ->
    case call({insert_node, Node}) of
        ok -> ok;
        already_member -> already_member;
        range_full -> range_full;
        {error, Reason} -> {error, Reason};
        {verify, QNode} ->
            %% There is an old questionable node, which needs refreshing. Execute a ping test on
            %% the node to make sure it is still alive. Then attempt reinsertion.
            refresh_node(QNode),
            insert_node(Node)
    end.

request_success(Node, Opts) -> call({request_success, Node, Opts}).
request_timeout(Node) -> call({request_timeout, Node}).

%% INTERNAL API
%% -------------------------------------------------------------------

%% @private
%% @doc insert_nodes/1 inserts a list of nodes into the routing table asynchronously
%% TODO: Hook the insert_node calls into a supervisor worker structure?
%% @end
-spec insert_nodes([dht:node_t()]) -> ok.
insert_nodes(NodeInfos) ->
    [spawn_link(?MODULE, insert_node, [Node]) || Node <- NodeInfos],
    ok.

%% @private
%% @doc refresh_node/1 makes sure a node is still available
-spec refresh_node(dht:node_t()) -> ok | roaming_member.
refresh_node({ID, IP, Port} = Node) ->
    case dht_net:ping({IP, Port}) of
	{ok, ID} ->
	    request_success({ID, IP, Port}, #{ reachable => true });
	{ok, _WrongID} ->
	    request_timeout(Node);
	pang ->
	    request_timeout(Node)
    end.

%% @private
%% Sync is used internally to send an event into the dht_state engine and block the caller.
%% The caller will be unblocked if the event sets and eventually removes monitors.
sync(Msg, Timeout) ->
    gen_server:call(?MODULE, {sync, Msg}, Timeout).

%% @doc refresh_range/1 refreshes a range for the system based on its ID
%% @end
-spec refresh_range(dht:id()) -> ok.
refresh_range(ID) ->
    case dht_net:find_node(ID) of
        {error, timeout} -> ok;
        {_, Nearnodes} ->
            [insert_node(N) || N <- Nearnodes]
    end.

%% CALLBACKS
%% -------------------------------------------------------------------

%% @private
init([RequestedNodeID, StateFile, BootstrapNodes]) ->
    %% For now, we trap exits which ensures the state table is dumped upon termination
    %% of the process.
    %% @todo lift this restriction. Periodically dump state, but don't do it if an
    %% invariant is broken for some reason
    %% erlang:process_flag(trap_exit, true),

    RoutingTbl = load_state(RequestedNodeID, StateFile),
    
    %% @todo, consider just folding over these as well rather than a background insert.
    insert_nodes(BootstrapNodes),
    
    {ok, ID, Routing} = dht_routing_meta:new(RoutingTbl),
    {ok, #state { node_id = ID, routing = Routing}}.

%% @private
handle_call({insert_node, Node}, _From, #state { routing = R } = State) ->
    case dht_routing_meta:member_state(Node, R) of
        member -> {reply, already_member, State};
        roaming_member -> {reply, already_member, State};
        unknown ->
            {Reply, NR} = adjoin(Node, R),
            {reply, Reply, State#state { routing = NR }}
    end;
handle_call({closest_to, ID, NumNodes}, _From, #state{routing = Routing } = State) ->
    Neighbors = dht_routing_meta:neighbors(ID, NumNodes, Routing),
    {reply, Neighbors, State};
handle_call({request_timeout, Node}, _From, #state{ routing = Routing } = State) ->
    case dht_routing_meta:member_state(Node, Routing) of
        unknown -> {reply, ok, State};
        roaming_member -> {reply, roaming_member, State};
        member ->
            R = dht_routing_meta:node_timeout(Node, Routing),
            {reply, ok, State#state { routing = R }}
    end;
handle_call({request_success, Node, Opts}, _From, #state{ routing = Routing } = State) ->
    case dht_routing_meta:member_state(Node, Routing) of
        unknown -> {reply, ok, State};
        roaming_member -> {reply, roaming_member, State};
        member ->
            R = dht_routing_meta:node_touch(Node, Opts, Routing),
            {reply, ok, State#state { routing = R }}
    end;
handle_call(dump_state, From, #state{ state_file = StateFile } = State) ->
    handle_call({dump_state, StateFile}, From, State);
handle_call({dump_state, StateFile}, _From, #state{ routing = Routing } = State) ->
    try
        Tbl = dht_routing_meta:export(Routing),
        dump_state(StateFile, Tbl),
        {reply, ok, State}
    catch
      Class:Err ->
        {reply, {error, {dump_state_failed, Class, Err}}, State}
    end;
handle_call(node_list, _From, #state { routing = Routing } = State) ->
    {reply, dht_routing_meta:node_list(Routing), State};
handle_call(node_id, _From, #state{ node_id = Self } = State) ->
    {reply, Self, State};
handle_call({sync, Msg}, From, #state { syncers = Ss } = State) ->
    self() ! Msg,
    {noreply, State#state { syncers = [From | Ss]}}.

%% @private
handle_cast(_, State) ->
    {noreply, State}.

%% @private
%% The timer {inactive_range, Range} is set by the dht_routing module
handle_info({'DOWN', Ref, process, _, normal}, #state { monitors = Ms, syncers = Ss} = State) ->
    case Ms -- [Ref] of
        [] ->
            [gen_server:reply(From, ok) || From <- Ss],
            {noreply, State#state { monitors = [], syncers = [] }};
        NewMons ->
            {noreply, State#state { monitors = NewMons }}
    end;
handle_info({inactive_range, Range}, #state{ routing = Routing, monitors = Ms } = State) ->
    case dht_routing_meta:range_state(Range, Routing) of
        {error, not_member} ->
            {noreply, wakeup(State)};
        ok ->
            R = dht_routing_meta:reset_range_timer(Range, #{ force => false}, Routing),
            {noreply, wakeup(State#state { routing = R })};
        empty ->
            R = dht_routing_meta:reset_range_timer(Range, #{ force => true}, Routing),
            {noreply, wakeup(State#state { routing = R })};
        {needs_refresh, ID} ->
            R = dht_routing_meta:reset_range_timer(Range, #{ force => true }, Routing),
            %% Create a monitor on the process, so we can handle the state of our
            %% background worker.
            {_, MRef} = spawn_monitor(?MODULE, refresh_range, [ID]),
            {noreply, State#state { routing = R, monitors = [MRef | Ms] }}
    end;
handle_info({stop, Caller}, #state{} = State) ->
	Caller ! stopped,
	{stop, normal, State}.

%% @private
terminate(_Reason, #state{ routing = _Routing, state_file=_StateFile}) ->
	%%error_logger:error_report({exiting, Reason}),
	%%dump_state(StateFile, dht_routing_meta:export(Routing))
	ok.

%% @private
code_change(_, State, _) ->
    {ok, State}.

%%
%% INTERNAL FUNCTIONS
%%

%% adjoin/2 attempts to add a new `Node' to the `Routing'-table.
%% It either succeeds in doing so, or fails due to one of the many reasons
%% as to why it can't happen:
%% • The range is already full of nodes
%% • There is room for a new node
%% • We can replace a bad node with the new node
%% • We fail to adjoin the new node, but can point to a node neighboring node which
%%    needs verification.
adjoin(Node, Routing) ->
    Near = dht_routing_meta:range_members(Node, Routing),
    case analyze_range(dht_routing_meta:node_state(Near, Routing)) of
      {[], [], Gs} when length(Gs) == ?MAX_RANGE_SZ ->
          %% Already enough nodes in that range/bucket
          {range_full, Routing};
      {Bs, Qs, Gs} when length(Gs) + length(Bs) + length(Qs) < ?MAX_RANGE_SZ ->
          %% There is room for the new node, insert it
          {ok, _NewRouting} = dht_routing_meta:insert(Node, Routing);
      {[Bad | _], _, _} ->
          %% There is a bad node present, swap the new node for the bad
          {ok, _NewRouting} = dht_routing_meta:replace(Bad, Node, Routing);
      {[], [Questionable | _], _} ->
          %% Ask the caller to verify the questionable node (they are sorted in order of interestingness)
          {{verify, Questionable}, Routing}
    end.

%% Given a list of node states, sort them into good, bad, and questionable buckets.
%% In the case of the questionable nodes, they are sorted oldest first, so the list head
%% is the one you want to analyze.
%%
%% In addition we sort the bad nodes, so there is a specific deterministic order in which
%% we consume them.
analyze_range(Nodes) when length(Nodes) =< ?MAX_RANGE_SZ ->
    analyze_range(lists:sort(Nodes), [], [], []).

analyze_range([], Bs, Qs, Gs) ->
    SortedQs = [N || {N, _} <- lists:keysort(2, lists:reverse(Qs))],
    {lists:reverse(Bs), SortedQs, lists:reverse(Gs)};
analyze_range([{B, bad} | Next], Bs, Qs, Gs) -> analyze_range(Next, [B | Bs], Qs, Gs);
analyze_range([{G, good} | Next], Bs, Qs, Gs) -> analyze_range(Next, Bs, Qs, [G | Gs]);
analyze_range([{_, {questionable, _}} = Q | Next], Bs, Qs, Gs) -> analyze_range(Next, Bs, [Q | Qs], Gs).

%%
%% DISK STATE
%% ----------------------------------

dump_state(no_state_file, _) -> ok;
dump_state(Filename, RoutingTable) ->
    ok = file:write_file(Filename, term_to_binary(RoutingTable, [compressed])).

load_state(RequestedNodeID, {no_state_file, L, H}) ->
	dht_routing_table:new(RequestedNodeID, L, H);
load_state(RequestedNodeID, no_state_file) ->
	dht_routing_table:new(RequestedNodeID);
load_state(RequestedNodeID, Filename) ->
    case file:read_file(Filename) of
        {ok, BinState} ->
            binary_to_term(BinState);
        {error, enoent} ->
            dht_routing_table:new(RequestedNodeID)
    end.

wakeup(#state { monitors = [], syncers = Ss } = State) ->
    [gen_server:reply(From, ok) || From <- Ss],
    State#state { syncers = [] };
wakeup(State) -> State.
