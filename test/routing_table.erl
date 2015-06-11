-module(routing_table).
-behaviour(gen_server).

-include("dht_eqc.hrl").

-export([start_link/1, reset/1, insert/1, ranges/0, delete/1, members/1, member_state/1, invariant/0, node_list/0, is_range/1, closest_to/3, node_id/0]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

-record(state, {
	table
}).

start_link(Self) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [Self], []).

reset(Self) ->
	case whereis(?MODULE) of
	    undefined ->
	        {ok, _} = start_link(Self),
	        ok;
	    P when is_pid(P) ->
	        gen_server:call(?MODULE, {reset, Self})
	end.

insert(Node) ->
	gen_server:call(?MODULE, {insert, Node}).

ranges() ->
	gen_server:call(?MODULE, ranges).

delete(Node) ->
	gen_server:call(?MODULE, {delete, Node}).

members(ID) ->
	gen_server:call(?MODULE, {members, ID}).

member_state(Node) ->
	gen_server:call(?MODULE, {member_state, Node}).

node_list() ->
	gen_server:call(?MODULE, node_list).

node_id() ->
	gen_server:call(?MODULE, node_id).

is_range(B) ->
	gen_server:call(?MODULE, {is_range, B}).

closest_to(ID, Filter, Num) ->
	gen_server:call(?MODULE, {closest_to, ID, Filter, Num}).

invariant() ->
	gen_server:call(?MODULE, invariant).

%% Callbacks

init([Self]) ->
	{ok, #state{ table = dht_routing_table:new(Self, ?ID_MIN, ?ID_MAX) }}.

handle_cast(_Msg, State) ->
	{noreply, State}.
	
handle_call({reset, Self}, _From, State) ->
	{reply, ok, State#state { table = dht_routing_table:new(Self, ?ID_MIN, ?ID_MAX) }};
handle_call(ranges, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:ranges(RT), State};
handle_call({insert, Node}, _From, #state { table = RT } = State) ->
	{reply, 'ROUTING_TABLE', State#state { table = dht_routing_table:insert(Node, RT) }};
handle_call({delete, Node}, _From, #state { table = RT } = State) ->
	{reply, 'ROUTING_TABLE', State#state { table = dht_routing_table:delete(Node, RT) }};
handle_call({members, ID}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:members(ID, RT), State};
handle_call({member_state, Node}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:member_state(Node, RT), State};
handle_call(node_list, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:node_list(RT), State};
handle_call(node_id, _From, #state { table = RT} = State) ->
	{reply, dht_routing_table:node_id(RT), State};
handle_call({is_range, B}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:is_range(B, RT), State};
handle_call({closest_to, ID, Filter, Num}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:closest_to(ID, Filter, Num, RT), State};
handle_call(invariant, _From, #state { table = RT } = State) ->
	{reply, check_invariants(dht_routing_table:node_id(RT), RT), State};
handle_call(_Msg, _From, State) ->
	{reply, {error, unsupported}, State}.

handle_info(_Msg, State) ->
	{noreply, State}.

code_change(_Vsn, State, _Aux) ->
	{ok, State}.
	
terminate(_What, _State) ->
	ok.
	
check_invariants(ID, RT) ->
    check([
      check_member_count(ID, RT),
      check_contiguous(RT)
    ]).
    
check([ok | Chks]) -> check(Chks);
check([Err | _]) -> Err;
check([]) -> true.

check_member_count(ID, {routing_table, _, Table}) ->
    check_member_count_(ID, Table).

check_member_count_(_ID, []) -> true;
check_member_count_(ID, [{bucket, Min, Max, Members } | Buckets ]) ->
    %% If our own ID falls into a bucket, then there can't be 8 elements in that bucket
    Sz = case Min =< ID andalso ID =< Max of
        true -> 8;
        false -> 8
    end,
    case length(Members) =< Sz of
        true -> check_member_count_(ID, Buckets);
        false -> {error, bucket_length}
    end.

check_contiguous({routing_table, _, Table}) ->
    check_contiguous_(Table).
                        
check_contiguous_([]) -> true;
check_contiguous_([{bucket, _Min, _Max, _Members}]) -> true;
check_contiguous_([{bucket, _Low, M1, _Members1}, {bucket, M2, High, Members2} | T]) when M1 == M2 ->
  check_contiguous_([{bucket, M2, High, Members2} | T]);
check_contiguous_([_X, _Y | _T]) ->
  {error, contiguous}.
