-module(routing_table).
-behaviour(gen_server).

-export([start_link/1, reset/1, insert/1, ranges/0, range/1, delete/1, members/1, is_member/1, invariant/0, node_list/0, is_range/1, closest_to/3]).

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

range(ID) ->
	gen_server:call(?MODULE, {range, ID}).

delete(Node) ->
	gen_server:call(?MODULE, {delete, Node}).

members(ID) ->
	gen_server:call(?MODULE, {members, ID}).

is_member(Node) ->
	gen_server:call(?MODULE, {is_member, Node}).

node_list() ->
	gen_server:call(?MODULE, node_list).

is_range(B) ->
	gen_server:call(?MODULE, {is_range, B}).

closest_to(ID, Filter, Num) ->
	gen_server:call(?MODULE, {closest_to, ID, Filter, Num}).

invariant() ->
	gen_server:call(?MODULE, invariant).

%% Callbacks

init([Self]) ->
	{ok, #state{ table = dht_routing_table:new(Self) }}.

handle_cast(_Msg, State) ->
	{noreply, State}.
	
handle_call({reset, Self}, _From, State) ->
	{reply, ok, State#state { table = dht_routing_table:new(Self) }};
handle_call(ranges, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:ranges(RT), State};
handle_call({range, ID}, _From, #state{ table = RT } = State) ->
	{reply, dht_routing_table:range(ID, RT), State};
handle_call({insert, Node}, _From, #state { table = RT } = State) ->
	{reply, ok, State#state { table = dht_routing_table:insert(Node, RT) }};
handle_call({delete, Node}, _From, #state { table = RT } = State) ->
	{reply, ok, State#state { table = dht_routing_table:delete(Node, RT) }};
handle_call({members, ID}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:members(ID, RT), State};
handle_call({is_member, Node}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:is_member(Node, RT), State};
handle_call(node_list, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:node_list(RT), State};
handle_call({is_range, B}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:is_range(B, RT), State};
handle_call({closest_to, ID, Filter, Num}, _From, #state { table = RT } = State) ->
	{reply, dht_routing_table:closest_to(ID, Filter, Num, RT), State};
handle_call(invariant, _From, #state { table = RT } = State) ->
	{reply, check_invariants(RT), State};
handle_call(_Msg, _From, State) ->
	{reply, {error, unsupported}, State}.

handle_info(_Msg, State) ->
	{noreply, State}.

code_change(_Vsn, State, _Aux) ->
	{ok, State}.
	
terminate(_What, _State) ->
	ok.
	
check_invariants(RT) ->
	check_member_count(RT) andalso check_contiguous(RT).

check_member_count({routing_table, _, Table}) ->
    check_member_count_(Table).

check_member_count_([]) -> true;
check_member_count_([{_Min, _Max, Members } | Buckets ]) ->
    case length(Members) =< 8 of
        true -> check_member_count_(Buckets);
        false -> {error, member_count}
    end.

check_contiguous({routing_table, _, Table}) ->
    check_contiguous_(Table).
                        
check_contiguous_([]) -> true;
check_contiguous_([{_Min, _Max, _Members}]) -> true;
check_contiguous_([{_Low, M1, _Members1}, {M2, High, Members2} | T]) when M1 == M2 ->
  check_contiguous_([{M2, High, Members2} | T]);
check_contiguous_([_X, _Y | _T]) ->
  {error, not_contiguous}.
