%%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%%% @doc A Server for maintaining the the routing table in DHT
%%
%% @todo Document all exported functions.
%%
%% This module implements the higher-level logic of the DHT
%% routing table. The routing table itself is split over 3 modules:
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
%%% @end
%%% @private
-module(dht_state).
-behaviour(gen_server).

-include("dht_constants.hrl").
-include_lib("kernel/include/inet.hrl").

%% Lifetime
-export([
	dump_state/0, dump_state/1,
	start_link/2,
	start_link/3,
	sync/0
]).

%% Query
-export([
	closest_to/1,
	closest_to/2,
	node_id/0
]).

%% Manipulation
-export([
         request_success/2,
         request_timeout/1
]).

%% Information
-export([
	info/0
]).

-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

-record(state, {
    node_id :: dht:id(), % ID of this node
    routing = dht_routing_meta:empty() % Routing table and timing structure
}).

%% LIFETIME MAINTENANCE
%% ----------------------------------------------------------
start_link(StateFile, BootstrapNodes) ->
	start_link(dht_metric:mk(), StateFile, BootstrapNodes).
	
start_link(RequestedID, StateFile, BootstrapNodes) ->
    gen_server:start_link({local, ?MODULE},
			  ?MODULE,
			  [RequestedID, StateFile, BootstrapNodes], []).

%% @doc Retrieve routing table information
info() ->
    MetaData = call(info),
    dht_routing_meta:info(MetaData).
    
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
cast(X) -> gen_server:cast(?MODULE, X).

%% QUERIES 
%% -----------

%% @equiv closest_to(NodeID, 8)
-spec closest_to(dht:id()) -> list(dht:peer()).
closest_to(NodeID) -> closest_to(NodeID, ?MAX_RANGE_SZ).

%% @doc closest_to/2 returns the neighborhood around an ID known to the routing table
%% @end
-spec closest_to(dht:id(), pos_integer()) -> list(dht:peer()).
closest_to(NodeID, NumNodes) ->
    call({closest_to, NodeID, NumNodes}).

%% @doc Return this node id as an integer.
%% Node ids are generated in a random manner.
-spec node_id() -> dht:id().
node_id() ->
    gen_server:call(?MODULE, node_id).

%% OPERATIONS WHICH CHANGE STATE
%% ------------------------------
request_success(Node, Opts) ->
    case call({insert_node, Node, Opts}) of
        ok -> ok;
        not_inserted -> not_inserted;
        already_member ->
            cast({request_success, Node, Opts}),
            already_member;
        {error, Reason} -> {error, Reason};
        {verify, QNode} ->
            dht_refresh:verify(QNode, Node, Opts),
            ok
    end.

request_timeout(Node) ->
    cast({request_timeout, Node}).

%% INTERNAL API
%% -------------------------------------------------------------------

%% @private
%% sync/0 is used to make sure all async processing in the state process has been done.
%% Its only intended use is when we are testing the code in the process.
sync() ->
    gen_server:call(?MODULE, sync).

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
    ok = dht_refresh:insert_nodes(BootstrapNodes),
    
    {ok, ID, Routing} = dht_routing_meta:new(RoutingTbl),
    {ok, #state { node_id = ID, routing = Routing}}.

%% @private
handle_call({insert_node, Node, _Opts}, _From, #state { routing = R } = State) ->
    {Reply, NR} = insert_node_internal(Node, R),
    {reply, Reply, State#state { routing = NR }};
handle_call({closest_to, ID, NumNodes}, _From, #state{routing = Routing } = State) ->
    Neighbors = dht_routing_meta:neighbors(ID, NumNodes, Routing),
    {reply, Neighbors, State};
handle_call(dump_state, From, State) ->
    handle_call({dump_state, get_current_statefile()}, From, State);
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
handle_call(info, _From, #state { routing = Routing } = State) ->
    {reply, Routing, State};
handle_call(sync, _From, State) ->
    {reply, ok, State}.

%% @private
handle_cast({request_timeout, Node}, #state{ routing = Routing } = State) ->
    case dht_routing_meta:member_state(Node, Routing) of
        unknown -> {noreply, State};
        roaming_member -> {noreply, State};
        member ->
            R = dht_routing_meta:node_timeout(Node, Routing),
            {noreply, State#state { routing = R }}
    end;
handle_cast({request_success, Node, Opts}, #state{ routing = R } = State) ->
    case dht_routing_meta:member_state(Node, R) of
        unknown ->
            {_, NR} = insert_node_internal(Node, R),
            {noreply, State#state { routing = NR }};
        roaming_member -> {noreply, State};
        member ->
            NR = dht_routing_meta:node_touch(Node, Opts, R),
            {noreply, State#state { routing = NR }}
    end;
handle_cast(_, State) ->
    {noreply, State}.

%% @private
%% The timer {inactive_range, Range} is set by the dht_routing module
handle_info({inactive_range, Range}, #state{ routing = Routing } = State) ->
    case dht_routing_meta:range_state(Range, Routing) of
        {error, not_member} ->
            {noreply, State};
        ok ->
            R = dht_routing_meta:reset_range_timer(Range, #{ force => false}, Routing),
            {noreply, State#state { routing = R }};
        empty ->
            R = dht_routing_meta:reset_range_timer(Range, #{ force => true}, Routing),
            {noreply, State#state { routing = R }};
        {needs_refresh, Member} ->
            R = dht_routing_meta:reset_range_timer(Range, #{ force => true }, Routing),
            %% Create a monitor on the process, so we can handle the state of our
            %% background worker.
            ok = dht_refresh:range(Member),
            {noreply, State#state { routing = R  }}
    end;
handle_info({stop, Caller}, #state{} = State) ->
	Caller ! stopped,
	{stop, normal, State}.

%% @private
terminate(_Reason, #state{ routing = _Routing }) ->
	%%error_logger:error_report({exiting, Reason}),
	%%dump_state(StateFile, dht_routing_meta:export(Routing))
	ok.

%% @private
code_change(_, State, _) ->
    {ok, State}.

%%
%% INTERNAL FUNCTIONS
%%

get_current_statefile() ->
    {ok, SF} = application:get_env(dht, state_file),
    SF.

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
          case dht_routing_meta:insert(Node, Routing) of
              {ok, NewRouting} -> {ok, NewRouting};
              not_inserted -> {not_inserted, Routing}
          end;
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

insert_node_internal(Node, R) ->
    case dht_routing_meta:member_state(Node, R) of
        member -> {already_member, R};
        roaming_member -> {already_member, R};
        unknown -> adjoin(Node, R)
    end.
